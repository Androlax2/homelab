#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/backup_databases.sh with `docker` stubbed: the Postgres containers
# print a dump, and Vaultwarden hands out an SQLite file.
#
# Usage: bash scripts/tests/backup_databases_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

TODAY=$(date '+%Y-%m-%d')

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    backup_root="$sandbox/backups"
    mkdir -p "$sandbox/bin"
    export DOCKER_CALLS_LOG="$sandbox/docker-calls.log"
    touch "$DOCKER_CALLS_LOG"
    # STUB_TRUNCATED / STUB_MISSING: a container whose dump is cut short / that doesn't exist.
    # STUB_BAD_SQLITE=1: Vaultwarden's copy is not an SQLite file.
    export STUB_TRUNCATED="" STUB_MISSING="" STUB_BAD_SQLITE=0
    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS_LOG"
case "$1 $2" in
    "exec vaultwarden")
        case "$3" in
            /vaultwarden) exit 0 ;;
            sh) echo /data/db_20260911_030000.sqlite3 ;;
            rm) exit 0 ;;
        esac
        ;;
    exec\ *)
        container="$2"
        [ "$container" != "$STUB_MISSING" ] || { echo "No such container: $container" >&2; exit 1; }
        echo "-- dump of $container"
        [ "$container" = "$STUB_TRUNCATED" ] || echo "-- PostgreSQL database cluster dump complete"
        ;;
    cp\ vaultwarden:*)
        if [ "$STUB_BAD_SQLITE" = 1 ]; then printf 'garbage' > "$3"; else printf 'SQLite format 3\0rest' > "$3"; fi
        ;;
esac
STUB
    chmod +x "$sandbox/bin/docker"
    export PATH="$sandbox/bin:$PATH"
}

in_sandbox() {
    create_sandbox
    "$@"
}

run_backup() {
    bash "$SCRIPTS_DIR/backup_databases.sh" "$backup_root" > "$sandbox/output" 2>&1
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

test_writes_every_backup_into_todays_folder() {
    run_backup || fail_with "expected success"
    for file in immich_postgres.sql.gz opusline-db.sql.gz prowlarr-postgres.sql.gz vaultwarden.sqlite3; do
        [ -s "$backup_root/$TODAY/$file" ] || fail_with "missing $TODAY/$file"
    done
    gzip -dc "$backup_root/$TODAY/opusline-db.sql.gz" | grep -q 'dump of opusline-db' || fail_with "the dump content is wrong"
}

test_backups_are_readable_by_root_only() {
    run_backup || fail_with "expected success"
    [ "$(stat -c %a "$backup_root/$TODAY")" = "700" ] || fail_with "the dated folder must be 700"
    [ "$(stat -c %a "$backup_root/$TODAY/immich_postgres.sql.gz")" = "600" ] || fail_with "the dumps must be 600"
}

test_removes_the_copy_from_the_vaultwarden_container() {
    run_backup || fail_with "expected success"
    grep -qx 'exec vaultwarden rm -f /data/db_20260911_030000.sqlite3' "$DOCKER_CALLS_LOG" \
        || fail_with "expected the in-container copy to be removed"
}

test_keeps_only_the_last_14_backups() {
    make_old_backups 20
    run_backup || fail_with "expected success"
    [ "$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 14 ] || fail_with "expected 14 dated folders"
    [ -d "$backup_root/$TODAY" ] || fail_with "today's backup must be kept"
    [ ! -d "$backup_root/$(date -d '-20 days' '+%Y-%m-%d')" ] || fail_with "the oldest backup should be gone"
}

# $1 = what goes wrong (truncated | missing | bad-sqlite), $2 = the name the failure is reported under
check_failure() {
    local problem="$1" failed_name="$2"
    case "$problem" in
        truncated) export STUB_TRUNCATED=opusline-db ;;
        missing) export STUB_MISSING=opusline-db ;;
        bad-sqlite) export STUB_BAD_SQLITE=1 ;;
    esac
    make_old_backups 20
    if run_backup; then
        fail_with "expected a failure"
    fi
    grep -q "failed: .*$failed_name" "$sandbox/output" || fail_with "expected $failed_name to be reported"
    [ -z "$(find "$backup_root" -name '*.partial')" ] || fail_with "no partial file may be left behind"
    [ "$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 21 ] || fail_with "older backups must all be kept after a failure"
    [ -s "$backup_root/$TODAY/immich_postgres.sql.gz" ] || fail_with "the other databases must still be backed up"
}

run_test "it writes every database's backup into today's folder" in_sandbox test_writes_every_backup_into_todays_folder
run_test "its backups are readable by root only" in_sandbox test_backups_are_readable_by_root_only
run_test "it removes Vaultwarden's backup file from the container after copying it" in_sandbox test_removes_the_copy_from_the_vaultwarden_container
run_test "it keeps only the last 14 dated backups" in_sandbox test_keeps_only_the_last_14_backups
run_test "a dump without Postgres's completion line fails the run and keeps older backups" in_sandbox check_failure truncated opusline-db
run_test "a missing database container fails the run and keeps older backups" in_sandbox check_failure missing opusline-db
run_test "a Vaultwarden copy that isn't SQLite fails the run and keeps older backups" in_sandbox check_failure bad-sqlite vaultwarden

finish_tests
