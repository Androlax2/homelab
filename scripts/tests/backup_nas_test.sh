#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/backup_nas.sh in a sandbox repo with the real compose.sh, `docker` stubbed to
# record the restic commands it receives, `date +%u` stubbed to pick the weekday, and
# backup_databases.sh replaced by a stub that records it ran.
#
# Usage: bash scripts/tests/backup_nas_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

REAL_DATE=$(command -v date)

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    repo_dir="$sandbox/repo"
    backup_root="$sandbox/backups"
    mkdir -p "$repo_dir/scripts" "$repo_dir/stacks/backup" "$sandbox/bin" "$backup_root"
    cp "$SCRIPTS_DIR/backup_nas.sh" "$SCRIPTS_DIR/compose.sh" "$SCRIPTS_DIR/lib.sh" "$repo_dir/scripts/"
    printf 'BACKUPDIR=%s\n' "$backup_root" > "$repo_dir/stacks/common.env"
    printf 'services: {}\n' > "$repo_dir/stacks/backup/compose.yml"
    printf 'RESTIC_PASSWORD=\n' > "$repo_dir/stacks/backup/.env.example"
    printf 'RESTIC_PASSWORD=secret\n' > "$repo_dir/stacks/backup/.env"

    export CALLS_LOG="$sandbox/calls.log"
    touch "$CALLS_LOG"
    # STUB_DUMPS_FAIL=1: the database dumps fail. STUB_RESTIC_EXIT_<subcommand>: restic's exit code.
    # STUB_WEEKDAY: what `date +%u` prints (1 = Monday, 7 = Sunday).
    export STUB_DUMPS_FAIL=0 STUB_WEEKDAY=3 REAL_DATE
    cat > "$repo_dir/scripts/backup_databases.sh" <<'STUB'
#!/usr/bin/env bash
echo "backup_databases.sh" >> "$CALLS_LOG"
[ "$STUB_DUMPS_FAIL" != 1 ]
STUB
    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
arguments="$*"
restic_command="${arguments#*run --rm -T restic }"
echo "restic $restic_command" >> "$CALLS_LOG"
exit_variable="STUB_RESTIC_EXIT_${restic_command%% *}"
exit "${!exit_variable:-0}"
STUB
    cat > "$sandbox/bin/date" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "+%u" ]; then echo "$STUB_WEEKDAY"; else exec "$REAL_DATE" "$@"; fi
STUB
    chmod +x "$sandbox/bin/docker" "$sandbox/bin/date" "$repo_dir/scripts/backup_databases.sh"
    export PATH="$sandbox/bin:$PATH"
}

in_sandbox() {
    create_sandbox
    "$@"
}

run_backup() {
    bash "$repo_dir/scripts/backup_nas.sh" > "$sandbox/output" 2>&1
}

fail_with() {
    echo "      $1"
    sed 's/^/      backup_nas.sh | /' "$sandbox/output" 2>/dev/null || true
    return 1
}

BACKUP_CALL="restic backup /source --exclude-file /excludes.txt --exclude-caches"
MAINTENANCE_CALLS="restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 12
restic check --read-data-subset=5%"

assert_calls() {
    [ "$(cat "$CALLS_LOG")" = "$1" ] || fail_with "expected calls:
$1
      actual calls:
$(cat "$CALLS_LOG")"
}

test_dumps_the_databases_then_backs_up_the_nas() {
    run_backup || fail_with "expected success"
    assert_calls "backup_databases.sh
$BACKUP_CALL"
    [ -f "$backup_root/offsite-last-success" ] || fail_with "a successful backup must touch offsite-last-success"
}

test_still_backs_up_the_files_when_the_dumps_fail() {
    export STUB_DUMPS_FAIL=1
    if run_backup; then
        fail_with "expected the run to fail"
    fi
    assert_calls "backup_databases.sh
$BACKUP_CALL"
    grep -q 'failed: database dumps' "$sandbox/output" || fail_with "expected the dumps to be reported"
    [ -f "$backup_root/offsite-last-success" ] || fail_with "the files were backed up: offsite-last-success must be touched"
}

test_a_failed_restic_backup_fails_the_run() {
    export STUB_RESTIC_EXIT_backup=1
    if run_backup; then
        fail_with "expected the run to fail"
    fi
    grep -q 'failed: off-NAS backup' "$sandbox/output" || fail_with "expected the off-NAS backup to be reported"
    [ ! -f "$backup_root/offsite-last-success" ] || fail_with "offsite-last-success must not be touched"
}

test_a_backup_with_unreadable_files_is_kept_but_fails_the_run() {
    export STUB_RESTIC_EXIT_backup=3
    if run_backup; then
        fail_with "expected the run to fail"
    fi
    grep -q 'some files were unreadable' "$sandbox/output" || fail_with "expected the unreadable files to be reported"
    [ -f "$backup_root/offsite-last-success" ] || fail_with "restic saved a snapshot: offsite-last-success must be touched"
}

test_maintains_the_repository_on_sundays() {
    export STUB_WEEKDAY=7
    run_backup || fail_with "expected success"
    assert_calls "backup_databases.sh
$BACKUP_CALL
$MAINTENANCE_CALLS"
}

test_a_failed_maintenance_fails_the_run_after_a_good_backup() {
    export STUB_WEEKDAY=7 STUB_RESTIC_EXIT_forget=1
    if run_backup; then
        fail_with "expected the run to fail"
    fi
    grep -q 'failed: restic forget and prune' "$sandbox/output" || fail_with "expected the maintenance to be reported"
    grep -q '^restic check' "$CALLS_LOG" || fail_with "the check must still run after a failed prune"
    [ -f "$backup_root/offsite-last-success" ] || fail_with "the backup itself succeeded: offsite-last-success must be touched"
}

test_skips_while_the_previous_run_holds_the_lock() {
    flock "$repo_dir/.backup-nas.lock" sleep 5 &
    local holder=$!
    sleep 0.5
    run_backup || fail_with "a skipped run must not fail"
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    grep -q 'still running' "$sandbox/output" || fail_with "expected the skip to be logged"
    assert_calls ""
}

run_test "it dumps the databases, then backs up the NAS with restic" in_sandbox test_dumps_the_databases_then_backs_up_the_nas
run_test "it still backs up the files when a database dump fails, and fails the run" in_sandbox test_still_backs_up_the_files_when_the_dumps_fail
run_test "a failed restic backup fails the run and leaves offsite-last-success alone" in_sandbox test_a_failed_restic_backup_fails_the_run
run_test "a backup restic saved with unreadable files counts, but fails the run" in_sandbox test_a_backup_with_unreadable_files_is_kept_but_fails_the_run
run_test "it forgets, prunes and checks the repository on Sundays" in_sandbox test_maintains_the_repository_on_sundays
run_test "a failed maintenance fails the run but keeps the backup's success" in_sandbox test_a_failed_maintenance_fails_the_run_after_a_good_backup
run_test "it skips a run while the previous one still holds the lock" in_sandbox test_skips_while_the_previous_run_holds_the_lock

finish_tests
