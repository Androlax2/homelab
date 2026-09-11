# Minimal test runner shared by the *_test.sh files. Source it.
#   run_test <description> <command...>   runs the command in a subshell with set -e
#   finish_tests                           prints the tally; fails if any test failed

tests_passed=0
tests_failed=0

run_test() {
    local description="$1"
    shift
    local test_status
    # Not `( ... ) || test_status=$?`: that context silently disables set -e inside the subshell.
    set +e
    (
        set -e
        "$@"
    )
    test_status=$?
    set -e
    if [ "$test_status" -eq 0 ]; then
        printf 'PASS  %s\n' "$description"
        tests_passed=$((tests_passed + 1))
    else
        printf 'FAIL  %s\n' "$description"
        tests_failed=$((tests_failed + 1))
    fi
}

finish_tests() {
    printf '\n%d passed, %d failed\n' "$tests_passed" "$tests_failed"
    [ "$tests_failed" -eq 0 ]
}
