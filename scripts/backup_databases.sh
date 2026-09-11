#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Nightly database backups, for the databases a live file copy can't capture
# safely. Writes into <backup folder>/<date>/ and keeps the last KEEP_DAYS dated
# folders. Schedule it before the off-NAS backup (Hyper Backup) that copies the
# folder away.
#   Postgres (immich, opusline, prowlarr): pg_dumpall, kept only if the dump ends
#   with Postgres's own completion line
#   Vaultwarden (SQLite): its built-in `backup` command
#
# Every database is attempted even when one fails; old backups are only rotated
# after a run where all of them succeeded.
#
# Usage: scripts/backup_databases.sh <backup folder>
# ============================================================

# DSM Task Scheduler's PATH does not include /usr/local/bin, where docker lives.
PATH="$PATH:/usr/local/bin"

KEEP_DAYS=14
POSTGRES_CONTAINERS="immich_postgres opusline-db prowlarr-postgres"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

backup_root="${1:?Usage: scripts/backup_databases.sh <backup folder>}"
target_dir="$backup_root/$(date '+%Y-%m-%d')"
umask 077
mkdir -p "$target_dir"

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

backup_vaultwarden() {
    local backup_file="$target_dir/vaultwarden.sqlite3" container_copy
    log "Backing up vaultwarden"
    if ! docker exec vaultwarden /vaultwarden backup > /dev/null; then
        log "ERROR: vaultwarden: the backup command failed"
        return 1
    fi
    # The command writes /data/db_<timestamp>.sqlite3 inside the container.
    container_copy=$(docker exec vaultwarden sh -c 'ls -1t /data/db_*.sqlite3 2>/dev/null | head -n 1') || true
    if [ -z "$container_copy" ]; then
        log "ERROR: vaultwarden: no backup file found in /data"
        return 1
    fi
    if ! docker cp "vaultwarden:$container_copy" "$backup_file.partial" > /dev/null; then
        rm -f "$backup_file.partial"
        log "ERROR: vaultwarden: could not copy $container_copy"
        return 1
    fi
    docker exec vaultwarden rm -f "$container_copy"
    if [ "$(head -c 15 "$backup_file.partial")" != "SQLite format 3" ]; then
        rm -f "$backup_file.partial"
        log "ERROR: vaultwarden: the copy is not an SQLite database"
        return 1
    fi
    mv "$backup_file.partial" "$backup_file"
}

remove_old_backups() {
    local old_dir
    find "$backup_root" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' \
        | sort -r | tail -n +"$((KEEP_DAYS + 1))" | while read -r old_dir; do
            log "Removing old backup $old_dir"
            rm -rf "$old_dir"
        done
}

failed=()
for container in $POSTGRES_CONTAINERS; do
    dump_postgres "$container" || failed+=("$container")
done
backup_vaultwarden || failed+=(vaultwarden)

if [ ${#failed[@]} -gt 0 ]; then
    log "ERROR: failed: ${failed[*]}. Older backups were kept."
    exit 1
fi

remove_old_backups
log "Backups complete in $target_dir"
