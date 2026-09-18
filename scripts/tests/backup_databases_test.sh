#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/backup_databases.sh in a sandbox repo with `docker` stubbed: `docker ps` lists
# the labelled containers added by each test, `docker inspect` returns their mounts, and the
# Postgres containers print a dump. SQLite databases are real files made with python3.
#
# Usage: bash scripts/tests/backup_databases_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

TODAY=$(date '+%Y-%m-%d')

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    repo_dir="$sandbox/repo"
    config_root="$sandbox/appdata"
    backup_root="$sandbox/backups"
    mkdir -p "$repo_dir/scripts" "$repo_dir/stacks" "$sandbox/bin" "$sandbox/mounts" "$config_root"
    cp "$SCRIPTS_DIR/backup_databases.sh" "$SCRIPTS_DIR/lib.sh" "$repo_dir/scripts/"
    printf 'DOCKERCONFDIR=%s\nBACKUPDIR=%s\n' "$config_root" "$backup_root" > "$repo_dir/stacks/common.env"

    export DOCKER_CALLS_LOG="$sandbox/docker-calls.log" STUB_CONTAINERS_FILE="$sandbox/containers" STUB_MOUNTS_DIR="$sandbox/mounts"
    touch "$DOCKER_CALLS_LOG" "$STUB_CONTAINERS_FILE"
    # STUB_TRUNCATED / STUB_MISSING: a Postgres container whose dump is cut short / that doesn't exist.
    # STUB_STOPPED: containers that aren't running.
    export STUB_TRUNCATED="" STUB_MISSING="" STUB_STOPPED=""
    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS_LOG"
case "$1" in
    ps) cat "$STUB_CONTAINERS_FILE" ;;
    inspect)
        container="${!#}"
        case "$3" in
            *Mounts*) cat "$STUB_MOUNTS_DIR/$container" 2>/dev/null || true ;;
            *State.Running*) if [[ " $STUB_STOPPED " == *" $container "* ]]; then echo false; else echo true; fi ;;
        esac
        ;;
    exec)
        container="$2"
        [ "$container" != "$STUB_MISSING" ] || { echo "No such container: $container" >&2; exit 1; }
        echo "-- dump of $container"
        [ "$container" = "$STUB_TRUNCATED" ] || echo "-- PostgreSQL database cluster dump complete"
        ;;
esac
STUB
    chmod +x "$sandbox/bin/docker"
    export PATH="$sandbox/bin:$PATH"

    add_container app-db postgres
    add_container vaultwarden sqlite "$config_root/vaultwarden"
    create_sqlite "$config_root/vaultwarden/db.sqlite3" vault-row
    add_container portainer bolt "$config_root/portainer" "$sandbox/outside-config"
    mkdir -p "$config_root/portainer" "$sandbox/outside-config"
    printf 'bolt data' > "$config_root/portainer/portainer.db"
    add_container deluge none "$config_root/deluge"
}

in_sandbox() {
    create_sandbox
    "$@"
}

# $1 = container, $2 = homelab.backup label, $3... = host folders it mounts
add_container() {
    local container="$1" kind="$2"
    shift 2
    printf '%s %s\n' "$container" "$kind" >> "$STUB_CONTAINERS_FILE"
    printf '%s\n' "$@" > "$STUB_MOUNTS_DIR/$container"
}

# $1 = database file, $2 = value stored in it. The file is closed normally, in WAL mode.
create_sqlite() {
    mkdir -p "$(dirname "$1")"
    python3 - "$1" "$2" <<'PYTHON'
import sqlite3, sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("PRAGMA journal_mode=WAL")
connection.execute("CREATE TABLE items (value TEXT)")
connection.execute("INSERT INTO items VALUES (?)", (sys.argv[2],))
connection.commit()
connection.close()
PYTHON
}

# $1 = database file, $2 = value that stays in the write-ahead log: the process exits
# without closing the database, like an app still running.
create_sqlite_with_value_only_in_the_wal() {
    mkdir -p "$(dirname "$1")"
    python3 - "$1" "$2" <<'PYTHON'
import os, sqlite3, sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("PRAGMA journal_mode=WAL")
connection.execute("PRAGMA wal_autocheckpoint=0")
connection.execute("CREATE TABLE items (value TEXT)")
connection.execute("INSERT INTO items VALUES (?)", (sys.argv[2],))
connection.commit()
os._exit(0)
PYTHON
}

# $1 = database file, $2 = value stored in it. An index uses a collation only the app has,
# like Plex's icu_root: this python3 can copy the database but not check it. The index is on
# another column than value, so sqlite_values can still read it.
create_sqlite_with_app_collation() {
    mkdir -p "$(dirname "$1")"
    python3 - "$1" "$2" <<'PYTHON'
import sqlite3, sys
connection = sqlite3.connect(sys.argv[1])
connection.create_collation("icu_root", lambda left, right: (left > right) - (left < right))
connection.execute("PRAGMA journal_mode=WAL")
connection.execute("CREATE TABLE items (value TEXT, title TEXT)")
connection.execute("CREATE INDEX items_title ON items (title COLLATE icu_root)")
connection.execute("INSERT INTO items VALUES (?, 'a title')", (sys.argv[2],))
connection.commit()
connection.close()
PYTHON
}

# $1 = database file. Prints the values stored in it.
sqlite_values() {
    python3 -c 'import sqlite3, sys; print("\n".join(row[0] for row in sqlite3.connect(sys.argv[1]).execute("SELECT value FROM items")))' "$1"
}

run_backup() {
    bash "$repo_dir/scripts/backup_databases.sh" > "$sandbox/output" 2>&1
}

fail_with() {
    echo "      $1"
    sed 's/^/      backup_databases.sh | /' "$sandbox/output" 2>/dev/null || true
    return 1
}

# $1 = older dated folders to create before the run
make_old_backups() {
    local days_ago
    for days_ago in $(seq 1 "$1"); do
        mkdir -p "$backup_root/$(date -d "-$days_ago days" '+%Y-%m-%d')"
    done
}

test_backs_up_every_labelled_container_by_kind() {
    run_backup || fail_with "expected success"
    gzip -dc "$backup_root/$TODAY/app-db.sql.gz" | grep -q 'dump of app-db' || fail_with "the Postgres dump is missing or wrong"
    [ "$(sqlite_values "$backup_root/$TODAY/vaultwarden/db.sqlite3")" = vault-row ] || fail_with "the SQLite copy is missing or wrong"
    tar -tzf "$backup_root/$TODAY/portainer.tar.gz" | grep -qx 'portainer/portainer.db' || fail_with "the bolt archive lacks portainer/portainer.db"
    [ ! -e "$backup_root/$TODAY/deluge" ] || fail_with "a container labelled none must not be backed up"
    [ -f "$backup_root/last-success" ] || fail_with "a successful run must touch last-success"
}

test_backups_are_readable_by_root_only() {
    run_backup || fail_with "expected success"
    [ "$(stat -c %a "$backup_root/$TODAY")" = "700" ] || fail_with "the dated folder must be 700"
    local file
    for file in app-db.sql.gz vaultwarden/db.sqlite3 portainer.tar.gz; do
        [ "$(stat -c %a "$backup_root/$TODAY/$file")" = "600" ] || fail_with "$file must be 600"
    done
}

test_sqlite_copy_includes_the_write_ahead_log() {
    add_container kimai sqlite "$config_root/kimai"
    create_sqlite_with_value_only_in_the_wal "$config_root/kimai/kimai.sqlite" unflushed-row
    [ -s "$config_root/kimai/kimai.sqlite-wal" ] || fail_with "test setup: the value should be in the -wal file"
    run_backup || fail_with "expected success"
    [ "$(sqlite_values "$backup_root/$TODAY/kimai/kimai.sqlite")" = unflushed-row ] || fail_with "the copy lacks the value from the write-ahead log"
}

test_sqlite_copy_creates_no_file_beside_the_database() {
    run_backup || fail_with "expected success"
    [ "$(ls -A "$config_root/vaultwarden")" = "db.sqlite3" ] || fail_with "only db.sqlite3 may be in the app folder, found: $(ls -A "$config_root/vaultwarden" | tr '\n' ' ')"
}

test_skips_the_apps_own_dated_copies() {
    local databases="$config_root/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases"
    add_container plex-server sqlite "$config_root/plex"
    create_sqlite "$databases/com.plexapp.plugins.library.db" live
    create_sqlite "$databases/com.plexapp.plugins.library.db-2026-09-13" old
    run_backup || fail_with "expected success"
    local copies="$backup_root/$TODAY/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases"
    [ "$(sqlite_values "$copies/com.plexapp.plugins.library.db")" = live ] || fail_with "the live database must be copied"
    [ ! -e "$copies/com.plexapp.plugins.library.db-2026-09-13" ] || fail_with "the app's dated copy must be skipped"
}

test_copies_a_sqlite_unchecked_container_without_checking_it() {
    local databases="$config_root/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases"
    add_container plex-server sqlite-unchecked "$config_root/plex"
    create_sqlite_with_app_collation "$databases/com.plexapp.plugins.library.db" live
    run_backup || fail_with "expected success"
    local copies="$backup_root/$TODAY/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases"
    [ "$(sqlite_values "$copies/com.plexapp.plugins.library.db")" = live ] || fail_with "the database must be copied"
    grep -q 'plex-server: Copied .*com.plexapp.plugins.library.db (not checked)' "$sandbox/output" \
        || fail_with "the copy must be logged as not checked"
    [ -f "$backup_root/last-success" ] || fail_with "a successful run must touch last-success"
}

test_stops_a_bolt_container_only_while_archiving() {
    run_backup || fail_with "expected success"
    [ "$(grep -E '^(stop|start) ' "$DOCKER_CALLS_LOG")" = "$(printf 'stop portainer\nstart portainer')" ] \
        || fail_with "expected portainer to be stopped then started once"
}

test_leaves_a_stopped_bolt_container_stopped() {
    export STUB_STOPPED=portainer
    run_backup || fail_with "expected success"
    ! grep -qE '^(stop|start) ' "$DOCKER_CALLS_LOG" || fail_with "a container that wasn't running must be neither stopped nor started"
    [ -s "$backup_root/$TODAY/portainer.tar.gz" ] || fail_with "its folder must still be archived"
}

test_keeps_only_the_last_14_backups() {
    make_old_backups 20
    run_backup || fail_with "expected success"
    [ "$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 14 ] || fail_with "expected 14 dated folders"
    [ -d "$backup_root/$TODAY" ] || fail_with "today's backup must be kept"
    [ ! -d "$backup_root/$(date -d '-20 days' '+%Y-%m-%d')" ] || fail_with "the oldest backup should be gone"
}

test_fails_when_backupdir_is_not_set() {
    printf 'DOCKERCONFDIR=%s\n' "$config_root" > "$repo_dir/stacks/common.env"
    if run_backup; then
        fail_with "expected a failure"
    fi
    grep -q 'BACKUPDIR is not set in .*stacks/common.env' "$sandbox/output" || fail_with "expected the missing BACKUPDIR to be named"
    [ ! -s "$DOCKER_CALLS_LOG" ] || fail_with "no container may be touched"
}

test_fails_when_no_container_is_labelled() {
    : > "$STUB_CONTAINERS_FILE"
    if run_backup; then
        fail_with "expected a failure"
    fi
    grep -q 'no container has a homelab.backup label' "$sandbox/output" || fail_with "expected the empty list to be reported"
}

# $1 = what goes wrong, $2 = the name the failure is reported under
check_failure() {
    local problem="$1" failed_name="$2"
    local witness_check='gzip -dc "$backup_root/$TODAY/app-db.sql.gz" | grep -q "dump of app-db"'
    case "$problem" in
        truncated-dump) export STUB_TRUNCATED=app-db ;;
        missing-container) export STUB_MISSING=app-db ;;
        no-sqlite-file) rm "$config_root/vaultwarden/db.sqlite3" ;;
        app-collation)
            rm "$config_root/vaultwarden/db.sqlite3"
            create_sqlite_with_app_collation "$config_root/vaultwarden/db.sqlite3" vault-row
            ;;
        unknown-label) add_container odd mongo "$config_root/odd" ;;
        archive-fails) printf '%s\n' "$config_root/missing" > "$STUB_MOUNTS_DIR/portainer" ;;
    esac
    case "$problem" in
        truncated-dump | missing-container)
            witness_check='[ "$(sqlite_values "$backup_root/$TODAY/vaultwarden/db.sqlite3")" = vault-row ]' ;;
    esac
    make_old_backups 20
    if run_backup; then
        fail_with "expected a failure"
    fi
    grep -q "failed: .*$failed_name" "$sandbox/output" || fail_with "expected $failed_name to be reported"
    [ -z "$(find "$backup_root" -name '*.partial')" ] || fail_with "no partial file may be left behind"
    [ "$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 21 ] || fail_with "older backups must all be kept after a failure"
    [ ! -e "$backup_root/last-success" ] || fail_with "last-success must not be touched after a failure"
    eval "$witness_check" || fail_with "the other databases must still be backed up"
    if [ "$problem" = archive-fails ]; then
        grep -qx 'start portainer' "$DOCKER_CALLS_LOG" || fail_with "portainer must be started again after a failed archive"
    fi
}

run_test "it backs up every labelled container according to its homelab.backup kind" in_sandbox test_backs_up_every_labelled_container_by_kind
run_test "its backups are readable by root only" in_sandbox test_backups_are_readable_by_root_only
run_test "an SQLite copy includes changes still in the write-ahead log" in_sandbox test_sqlite_copy_includes_the_write_ahead_log
run_test "copying an SQLite database creates no -wal or -shm file beside it" in_sandbox test_sqlite_copy_creates_no_file_beside_the_database
run_test "it skips the dated copies an app keeps of its own database" in_sandbox test_skips_the_apps_own_dated_copies
run_test "it copies a sqlite-unchecked container's databases without checking them" in_sandbox test_copies_a_sqlite_unchecked_container_without_checking_it
run_test "it stops a bolt container only while archiving, then starts it again" in_sandbox test_stops_a_bolt_container_only_while_archiving
run_test "it archives a stopped bolt container without starting it" in_sandbox test_leaves_a_stopped_bolt_container_stopped
run_test "it keeps only the last 14 dated backups" in_sandbox test_keeps_only_the_last_14_backups
run_test "it refuses to run while BACKUPDIR is not set" in_sandbox test_fails_when_backupdir_is_not_set
run_test "it fails when no container is labelled" in_sandbox test_fails_when_no_container_is_labelled
run_test "a dump without Postgres's completion line fails the run and keeps older backups" in_sandbox check_failure truncated-dump app-db
run_test "a missing database container fails the run and keeps older backups" in_sandbox check_failure missing-container app-db
run_test "a container labelled sqlite without any SQLite file fails the run and keeps older backups" in_sandbox check_failure no-sqlite-file vaultwarden
run_test "a sqlite database this python3 can't check fails the run and keeps older backups" in_sandbox check_failure app-collation vaultwarden
run_test "an unknown homelab.backup kind fails the run and keeps older backups" in_sandbox check_failure unknown-label odd
run_test "a failed archive fails the run, keeps older backups and restarts the container" in_sandbox check_failure archive-fails portainer

finish_tests
