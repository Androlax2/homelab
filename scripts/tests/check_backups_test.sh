#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/check_backups.sh in a sandbox repo whose BACKUPDIR/last-success each test ages.
#
# Usage: bash scripts/tests/check_backups_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    repo_dir="$sandbox/repo"
    backup_root="$sandbox/backups"
    mkdir -p "$repo_dir/scripts" "$repo_dir/stacks" "$backup_root"
    cp "$SCRIPTS_DIR/check_backups.sh" "$SCRIPTS_DIR/lib.sh" "$repo_dir/scripts/"
    printf 'BACKUPDIR=%s\n' "$backup_root" > "$repo_dir/stacks/common.env"
    # Both backups just succeeded; each test breaks the one it is about.
    touch "$backup_root/last-success" "$backup_root/offsite-last-success"
}

in_sandbox() {
    create_sandbox
    "$@"
}

# $1 = when the last backup succeeded, in `date -d` syntax, $2 = its marker file (default: the database backup's)
backup_succeeded() {
    touch -d "$1" "$backup_root/${2:-last-success}"
}

check() {
    bash "$repo_dir/scripts/check_backups.sh" >> "$sandbox/output" 2>&1
}

fail_with() {
    echo "      $1"
    sed 's/^/      check_backups.sh | /' "$sandbox/output" 2>/dev/null || true
    return 1
}

test_passes_after_a_recent_backup() {
    backup_succeeded '2 hours ago'
    check || fail_with "expected success"
    [ ! -s "$sandbox/output" ] || fail_with "a healthy check must print nothing"
}

# $1 = how the backups are broken, $2 = text the report must contain
check_reported_once() {
    local problem="$1" expected_text="$2"
    case "$problem" in
        stale) backup_succeeded '30 hours ago' ;;
        never) rm "$backup_root/last-success" ;;
        offsite-stale) backup_succeeded '30 hours ago' offsite-last-success ;;
        offsite-never) rm "$backup_root/offsite-last-success" ;;
        no-backupdir) : > "$repo_dir/stacks/common.env" ;;
    esac
    if check; then
        fail_with "expected the first check to fail"
    fi
    grep -qF "$expected_text" "$sandbox/output" || fail_with "expected the report to contain: $expected_text"
    check || fail_with "the same problem must not fail the check a second time"
}

test_reports_again_when_backups_break_after_recovering() {
    backup_succeeded '30 hours ago'
    check || true
    backup_succeeded '1 hour ago'
    check || fail_with "expected success once a backup succeeded again"
    [ ! -f "$repo_dir/.backup-alert" ] || fail_with "the alert must be cleared after recovery"
    backup_succeeded '40 hours ago'
    if check; then
        fail_with "a new problem after recovery must be reported"
    fi
}

test_reports_a_new_staleness_after_a_newer_backup_also_ages() {
    backup_succeeded '30 hours ago'
    check || true
    backup_succeeded '27 hours ago'
    if check; then
        fail_with "a newer backup that is also too old is a new problem and must be reported"
    fi
}

run_test "it passes silently when the last backup succeeded recently" in_sandbox test_passes_after_a_recent_backup
run_test "it reports once a backup older than 26 hours" in_sandbox check_reported_once stale "the last successful database backup was 30 hours ago"
run_test "it reports once that no backup has ever succeeded" in_sandbox check_reported_once never "no database backup has succeeded yet"
run_test "it reports once an off-NAS backup older than 26 hours" in_sandbox check_reported_once offsite-stale "the last successful off-NAS backup was 30 hours ago"
run_test "it reports once that no off-NAS backup has ever succeeded" in_sandbox check_reported_once offsite-never "no off-NAS backup has succeeded yet"
run_test "it reports once that BACKUPDIR is not set" in_sandbox check_reported_once no-backupdir "BACKUPDIR is not set in stacks/common.env"
run_test "it reports again when backups break after recovering" in_sandbox test_reports_again_when_backups_break_after_recovering
run_test "it reports a newer backup that is also too old as a new problem" in_sandbox test_reports_a_new_staleness_after_a_newer_backup_also_ages

finish_tests
