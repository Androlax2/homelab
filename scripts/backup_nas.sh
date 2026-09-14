#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Nightly backup of the NAS's own data to the Hetzner Storage Box, run as root by DSM
# Task Scheduler:
#   1. scripts/backup_databases.sh dumps every database into BACKUPDIR
#   2. restic (stacks/backup) backs up /source: photos, app data, the database dumps, the
#      home folders and this checkout, minus stacks/backup/excludes.txt
#   3. on Sundays, restic forgets old snapshots (KEEP_* below), prunes, and reads back a
#      CHECK_SUBSET sample of the data
# The file backup runs even when a database dump failed, so everything else still leaves
# the NAS; the run fails either way, so DSM emails it. BACKUPDIR/offsite-last-success is
# touched whenever restic saved a snapshot: scripts/check_backups.sh watches it.
#
# Usage: scripts/backup_nas.sh
# ============================================================

# DSM Task Scheduler's PATH does not include /usr/local/bin, where docker lives.
PATH="$PATH:/usr/local/bin"

KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=12
CHECK_SUBSET="5%"
# ISO weekday of the maintenance: 7 is Sunday.
MAINTENANCE_WEEKDAY=7
# restic exits with 3 when the snapshot was saved but some files could not be read.
RESTIC_PARTIAL_BACKUP_EXIT_CODE=3

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

exec 9>"$REPO_DIR/.backup-nas.lock"
if ! flock -n 9; then
    log "The previous backup is still running (the first upload can take more than a day), skipping."
    exit 0
fi

backup_root=$(required_env_value "$REPO_DIR/stacks/common.env" BACKUPDIR common)

run_restic() {
    "$REPO_DIR/scripts/compose.sh" backup run --rm -T restic "$@"
}

failed=()

log "Dumping the databases"
if ! "$REPO_DIR/scripts/backup_databases.sh"; then
    failed+=("database dumps")
fi

log "Backing up the NAS to the Storage Box"
backup_status=0
run_restic backup /source --exclude-file /excludes.txt --exclude-caches || backup_status=$?
if [ "$backup_status" -eq 0 ] || [ "$backup_status" -eq "$RESTIC_PARTIAL_BACKUP_EXIT_CODE" ]; then
    touch "$backup_root/offsite-last-success"
fi
if [ "$backup_status" -eq "$RESTIC_PARTIAL_BACKUP_EXIT_CODE" ]; then
    failed+=("off-NAS backup (saved, but some files were unreadable)")
elif [ "$backup_status" -ne 0 ]; then
    failed+=("off-NAS backup")
fi

if [ "$(date +%u)" = "$MAINTENANCE_WEEKDAY" ]; then
    log "Weekly maintenance: forgetting old snapshots, pruning, checking a $CHECK_SUBSET sample"
    run_restic forget --prune --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" \
        || failed+=("restic forget and prune")
    run_restic check --read-data-subset="$CHECK_SUBSET" || failed+=("restic check")
fi

if [ ${#failed[@]} -gt 0 ]; then
    log "ERROR: failed: $(printf '%s; ' "${failed[@]}")"
    exit 1
fi
log "NAS backup complete"
