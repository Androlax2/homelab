#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/run_operations.sh on fixture operations that write to a log.
#
# Usage: bash scripts/tests/run_operations_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    repo_dir="$sandbox/repo"
    mkdir -p "$repo_dir/scripts" "$repo_dir/operations"
    cp "$SCRIPTS_DIR/run_operations.sh" "$SCRIPTS_DIR/lib.sh" "$repo_dir/scripts/"
    export OPERATIONS_LOG="$sandbox/operations.log"
    touch "$OPERATIONS_LOG"
}

in_sandbox() {
    create_sandbox
    "$@"
}

# $1 = file name, $2 = body
add_operation() {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$2" > "$repo_dir/operations/$1"
}

run_operations() {
    bash "$repo_dir/scripts/run_operations.sh" "$@" > "$sandbox/output" 2>&1
}

fail_with() {
    echo "      $1"
    sed 's/^/      run_operations.sh | /' "$sandbox/output" 2>/dev/null || true
    return 1
}

# $1 = expected content (\n escapes expanded), $2 = file
assert_content() {
    local expected actual=""
    expected=$(printf '%b' "$1")
    if [ -f "$2" ]; then
        actual=$(cat "$2")
    fi
    if [ "$actual" != "$expected" ]; then
        printf '      expected %s:\n%s\n      actual:\n%s\n' "$(basename "$2")" "$expected" "$actual"
        return 1
    fi
}

test_runs_pending_operations_in_name_order() {
    add_operation 2026_01_02_000000_second.sh 'echo second >> "$OPERATIONS_LOG"'
    add_operation 2026_01_01_000000_first.sh 'echo first >> "$OPERATIONS_LOG"'
    run_operations || fail_with "expected success"
    assert_content 'first\nsecond' "$OPERATIONS_LOG"
    assert_content '2026_01_01_000000_first.sh\n2026_01_02_000000_second.sh' "$repo_dir/.operations-done"
}

test_never_runs_an_operation_twice() {
    add_operation 2026_01_01_000000_once.sh 'echo ran >> "$OPERATIONS_LOG"'
    run_operations || fail_with "expected success"
    run_operations || fail_with "expected success"
    assert_content 'ran' "$OPERATIONS_LOG"
}

test_failure_stops_the_run_and_is_retried() {
    export FLAKY_MARKER="$sandbox/flaky-can-pass"
    add_operation 2026_01_01_000000_first.sh 'echo first >> "$OPERATIONS_LOG"'
    add_operation 2026_01_02_000000_flaky.sh '[ -f "$FLAKY_MARKER" ]; echo flaky >> "$OPERATIONS_LOG"'
    add_operation 2026_01_03_000000_last.sh 'echo last >> "$OPERATIONS_LOG"'
    if run_operations; then
        fail_with "expected a failure"
    fi
    grep -q 'operation 2026_01_02_000000_flaky.sh failed' "$sandbox/output" || fail_with "expected the failing operation to be named"
    assert_content 'first' "$OPERATIONS_LOG"
    assert_content '2026_01_01_000000_first.sh' "$repo_dir/.operations-done"
    touch "$FLAKY_MARKER"
    run_operations || fail_with "expected the retry to succeed"
    assert_content 'first\nflaky\nlast' "$OPERATIONS_LOG"
}

test_runs_from_the_repo_root() {
    add_operation 2026_01_01_000000_where.sh 'pwd >> "$OPERATIONS_LOG"'
    run_operations || fail_with "expected success"
    assert_content "$(cd "$repo_dir" && pwd)" "$OPERATIONS_LOG"
}

test_operations_get_no_input() {
    add_operation 2026_01_01_000000_asks.sh 'if read -r answer; then echo "read: $answer"; else echo "no input"; fi >> "$OPERATIONS_LOG"'
    add_operation 2026_01_02_000000_next.sh 'echo next >> "$OPERATIONS_LOG"'
    run_operations <<<"yes" || fail_with "expected success"
    assert_content 'no input\nnext' "$OPERATIONS_LOG"
}

test_ignores_files_that_are_not_scripts() {
    printf 'notes\n' > "$repo_dir/operations/README.md"
    run_operations || fail_with "expected success"
    [ ! -s "$repo_dir/.operations-done" ] || fail_with "nothing should be recorded"
}

test_mark_all_done_records_without_running() {
    add_operation 2026_01_01_000000_old.sh 'echo ran >> "$OPERATIONS_LOG"'
    run_operations --mark-all-done || fail_with "expected success"
    run_operations || fail_with "expected success"
    assert_content '' "$OPERATIONS_LOG"
    assert_content '2026_01_01_000000_old.sh' "$repo_dir/.operations-done"
}

test_list_shows_what_ran() {
    add_operation 2026_01_01_000000_old.sh 'true'
    run_operations || fail_with "expected success"
    add_operation 2026_01_02_000000_new.sh 'true'
    run_operations --list || fail_with "expected success"
    assert_content 'done     2026_01_01_000000_old.sh\npending  2026_01_02_000000_new.sh' "$sandbox/output"
}

test_refuses_to_run_while_a_deploy_holds_the_lock() {
    add_operation 2026_01_01_000000_once.sh 'echo ran >> "$OPERATIONS_LOG"'
    if flock "$repo_dir/.deploy.lock" bash "$repo_dir/scripts/run_operations.sh" > "$sandbox/output" 2>&1; then
        fail_with "expected a refusal"
    fi
    grep -q 'A deploy is running' "$sandbox/output" || fail_with "expected an explanation"
    assert_content '' "$OPERATIONS_LOG"
}

run_test "it runs the pending operations in file name order and records each" in_sandbox test_runs_pending_operations_in_name_order
run_test "it never runs an operation twice" in_sandbox test_never_runs_an_operation_twice
run_test "a failure stops the run, is not recorded, and runs again next time" in_sandbox test_failure_stops_the_run_and_is_retried
run_test "it runs operations from the repo root" in_sandbox test_runs_from_the_repo_root
run_test "operations get no input, so a question can't hang the deploy" in_sandbox test_operations_get_no_input
run_test "it ignores files that are not .sh scripts" in_sandbox test_ignores_files_that_are_not_scripts
run_test "--mark-all-done records the pending operations without running them" in_sandbox test_mark_all_done_records_without_running
run_test "--list shows which operations ran" in_sandbox test_list_shows_what_ran
run_test "it refuses to run while a deploy holds the lock" in_sandbox test_refuses_to_run_while_a_deploy_holds_the_lock

finish_tests
