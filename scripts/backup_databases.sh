#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Nightly database backups, for the databases a live file copy can't capture safely.
# Every container labelled homelab.backup in its compose file is backed up by kind:
#   postgres  pg_dumpall, kept only if the dump ends with Postgres's own completion line
#   sqlite    every SQLite file in the container's folders under DOCKERCONFDIR, copied with
#             SQLite's online backup and checked; the app's own dated copies are skipped
#   bolt      the container is stopped, its folders under DOCKERCONFDIR archived, and it
#             is started again (BoltDB locks its file, so a live copy can be corrupt)
#   none      nothing to dump: plain files Hyper Backup copies as they are, or data not
#             worth keeping
# scripts/check_stacks.sh requires the label on every service with a writable volume.
#
# Writes into BACKUPDIR/<date>/ (BACKUPDIR and DOCKERCONFDIR come from stacks/common.env),
# keeps the last KEEP_DAYS dated folders, and touches BACKUPDIR/last-success, which
# scripts/check_backups.sh watches. Schedule it before the off-NAS backup (Hyper Backup)
# that copies BACKUPDIR away.
#
# Every database is attempted even when one fails; old backups are only rotated, and
# last-success only touched, after a run where all of them succeeded.
#
# Usage: scripts/backup_databases.sh
# ============================================================

# DSM Task Scheduler's PATH does not include /usr/local/bin, where docker lives.
PATH="$PATH:/usr/local/bin"

KEEP_DAYS=14

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

config_root=$(required_env_value "$REPO_DIR/stacks/common.env" DOCKERCONFDIR common)
config_root="${config_root%/}"
backup_root=$(required_env_value "$REPO_DIR/stacks/common.env" BACKUPDIR common)
target_dir="$backup_root/$(date '+%Y-%m-%d')"
umask 077
mkdir -p "$target_dir"

# A container this script stopped, so it can be started again if the script dies meanwhile.
container_to_restart=""
restart_stopped_container() {
    if [ -n "$container_to_restart" ] && ! docker start "$container_to_restart" > /dev/null; then
        log "ERROR: $container_to_restart: could not start it again, start it by hand"
    fi
}
trap restart_stopped_container EXIT

# Prints "<container> <kind>" for every container labelled homelab.backup, running or not.
labelled_containers() {
    docker ps --all --filter label=homelab.backup --format '{{.Names}} {{.Label "homelab.backup"}}'
}

# Prints the host folders under DOCKERCONFDIR that <container> mounts, one per line.
config_folders() {
    local mounts source
    mounts=$(docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{println .Source}}{{end}}{{end}}' "$1")
    while IFS= read -r source; do
        case "$source" in
            "$config_root"/*) printf '%s\n' "$source" ;;
        esac
    done <<<"$mounts"
}

dump_postgres() {
    local container="$1"
    local dump_file="$target_dir/$container.sql.gz"
    log "Dumping $container"
    # PGPORT and POSTGRES_USER come from the container's own environment.
    if ! docker exec "$container" sh -c 'pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' | gzip > "$dump_file.partial"; then
        rm -f "$dump_file.partial"
        log "ERROR: $container: pg_dumpall failed"
        return 1
    fi
    # pg_dumpall writes this line last: without it, the dump was cut short.
    if ! gzip -dc "$dump_file.partial" | tail -n 5 | grep -q 'PostgreSQL database cluster dump complete'; then
        rm -f "$dump_file.partial"
        log "ERROR: $container: the dump is incomplete"
        return 1
    fi
    mv "$dump_file.partial" "$dump_file"
}

# Copies every SQLite file found in <folders...> to <destination root>, under its path
# relative to <config root>, with SQLite's online backup: consistent while the app writes,
# and including what is still in the write-ahead log. Each copy runs as the user owning the
# database, like one more client of the app: any -wal or -shm file SQLite creates beside the
# database then belongs to that user (a root-owned one would lock the app out), and SQLite
# removes them as usual. Dated copies an app keeps of itself (name-YYYY-MM-DD, like Plex's)
# are skipped. Fails when a copy fails its integrity check, or when the folders hold no SQLite file.
copy_sqlite_databases() {
    python3 - "$@" <<'PYTHON'
import os
import pathlib
import re
import shutil
import sqlite3
import sys
import tempfile

config_root, destination_root, *folders = sys.argv[1:]
dated_copy = re.compile(r"-\d{4}-\d{2}-\d{2}$")


def is_sqlite(path):
    try:
        with open(path, "rb") as database:
            return database.read(16) == b"SQLite format 3\x00"
    except FileNotFoundError:
        # Gone since the folder was listed: apps create and remove files all the time
        # (logs, and the -wal and -shm files SQLite removes when a copy closes).
        return False


def back_up_as_owner(source, work_file):
    """Writes an online backup of <source> to <work_file>, from a child process running as the owner of <source>."""
    owner = os.stat(source)
    child = os.fork()
    if child == 0:
        exit_code = 1
        try:
            if os.geteuid() == 0:
                os.setgroups([])
            os.setgid(owner.st_gid)
            os.setuid(owner.st_uid)
            # mode=rw: never create the database if it vanished since it was found.
            source_connection = sqlite3.connect(pathlib.Path(source).as_uri() + "?mode=rw", uri=True)
            work_connection = sqlite3.connect(work_file)
            source_connection.backup(work_connection)
            work_connection.close()
            source_connection.close()
            exit_code = 0
        except BaseException as error:
            print(f"ERROR: {os.path.relpath(source, config_root)}: {error}", flush=True)
        finally:
            os._exit(exit_code)
    _, wait_status = os.waitpid(child, 0)
    return os.waitstatus_to_exitcode(wait_status) == 0 if hasattr(os, "waitstatus_to_exitcode") else wait_status == 0


def copy(source, destination):
    owner = os.stat(source)
    work_directory = tempfile.mkdtemp(prefix="backup-databases-")
    try:
        os.chown(work_directory, owner.st_uid, owner.st_gid)
        work_file = os.path.join(work_directory, "copy.sqlite3")
        if not back_up_as_owner(source, work_file):
            return False
        with sqlite3.connect(work_file) as work_connection:
            check = work_connection.execute("PRAGMA quick_check").fetchone()[0]
        if check != "ok":
            print(f"ERROR: {os.path.relpath(source, config_root)}: integrity check of the copy: {check}", flush=True)
            return False
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        partial = destination + ".partial"
        shutil.move(work_file, partial)
        if os.geteuid() == 0:
            os.chown(partial, 0, 0)
        os.chmod(partial, 0o600)
        os.replace(partial, destination)
        return True
    finally:
        shutil.rmtree(work_directory, ignore_errors=True)


copied_count = 0
failed = False
for folder in folders:
    for directory, _, file_names in sorted(os.walk(folder)):
        for file_name in sorted(file_names):
            source = os.path.join(directory, file_name)
            if dated_copy.search(file_name) or os.path.islink(source) or not is_sqlite(source):
                continue
            relative_path = os.path.relpath(source, config_root)
            try:
                copied = copy(source, os.path.join(destination_root, relative_path))
            except (sqlite3.Error, OSError) as error:
                print(f"ERROR: {relative_path}: {error}", flush=True)
                copied = False
            if copied:
                print(f"Copied {relative_path}", flush=True)
                copied_count += 1
            else:
                failed = True

if copied_count == 0 and not failed:
    print(f"ERROR: no SQLite database in {', '.join(folders)}")
    failed = True
sys.exit(1 if failed else 0)
PYTHON
}

backup_sqlite() {
    local container="$1" folders
    log "Copying the SQLite databases of $container"
    if ! folders=$(config_folders "$container") || [ -z "$folders" ]; then
        log "ERROR: $container: mounts no folder under $config_root"
        return 1
    fi
    local -a folder_list
    mapfile -t folder_list <<<"$folders"
    copy_sqlite_databases "$config_root" "$target_dir" "${folder_list[@]}" 2>&1 \
        | while IFS= read -r line; do log "$container: $line"; done
}

backup_stopped_container() {
    local container="$1" folders is_running
    local archive="$target_dir/$container.tar.gz"
    if ! folders=$(config_folders "$container") || [ -z "$folders" ]; then
        log "ERROR: $container: mounts no folder under $config_root"
        return 1
    fi
    if ! is_running=$(docker inspect --format '{{.State.Running}}' "$container"); then
        log "ERROR: $container: could not inspect it"
        return 1
    fi

    local -a relative_folders=()
    local folder
    while IFS= read -r folder; do
        relative_folders+=("${folder#"$config_root"/}")
    done <<<"$folders"

    if [ "$is_running" = true ]; then
        log "Stopping $container to archive ${relative_folders[*]}"
        if ! docker stop "$container" > /dev/null; then
            log "ERROR: $container: could not stop it"
            return 1
        fi
        container_to_restart="$container"
    else
        log "Archiving ${relative_folders[*]} ($container is not running)"
    fi

    local archive_status=0
    tar -C "$config_root" -czf "$archive.partial" "${relative_folders[@]}" || archive_status=$?

    if [ -n "$container_to_restart" ]; then
        container_to_restart=""
        if ! docker start "$container" > /dev/null; then
            log "ERROR: $container: could not start it again, start it by hand"
            archive_status=1
        fi
    fi
    if [ "$archive_status" -ne 0 ]; then
        rm -f "$archive.partial"
        log "ERROR: $container: archiving failed"
        return 1
    fi
    mv "$archive.partial" "$archive"
}

remove_old_backups() {
    local old_dir
    find "$backup_root" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' \
        | sort -r | tail -n +"$((KEEP_DAYS + 1))" | while read -r old_dir; do
            log "Removing old backup $old_dir"
            rm -rf "$old_dir"
        done
}

containers=$(labelled_containers)
if [ -z "$containers" ]; then
    log "ERROR: no container has a homelab.backup label: are the stacks up?"
    exit 1
fi

failed=()
# Read on file descriptor 3, so no command in the loop can swallow the remaining list from stdin.
while read -r container kind <&3; do
    case "$kind" in
        postgres) dump_postgres "$container" || failed+=("$container") ;;
        sqlite) backup_sqlite "$container" || failed+=("$container") ;;
        bolt) backup_stopped_container "$container" || failed+=("$container") ;;
        none) ;;
        *)
            log "ERROR: $container: unknown homelab.backup label \"$kind\" (expected one of: $BACKUP_KINDS)"
            failed+=("$container")
            ;;
    esac
done 3<<<"$containers"

if [ ${#failed[@]} -gt 0 ]; then
    log "ERROR: failed: ${failed[*]}. Older backups were kept."
    exit 1
fi

remove_old_backups
touch "$backup_root/last-success"
log "Backups complete in $target_dir"
