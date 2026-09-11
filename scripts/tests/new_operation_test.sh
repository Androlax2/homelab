#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/new_operation.sh in a throwaway repo.
#
# Usage: bash scripts/tests/new_operation_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    repo_dir="$sandbox/repo"
    mkdir -p "$repo_dir/scripts"
    cp "$SCRIPTS_DIR/new_operation.sh" "$repo_dir/scripts/"
}

in_sandbox() {
    create_sandbox
    "$@"
}

new_operation() {
    bash "$repo_dir/scripts/new_operation.sh" "$@" 2> "$sandbox/stderr"
}

test_creates_a_timestamped_executable_file() {
    local created
    created=$(new_operation "Reset Immich password!")
    [[ "$created" =~ ^operations/[0-9]{4}_[0-9]{2}_[0-9]{2}_[0-9]{6}_reset_immich_password\.sh$ ]] \
        || { echo "      unexpected file name: $created"; return 1; }
    [ -x "$repo_dir/$created" ] || { echo "      $created is not executable"; return 1; }
}

test_keeps_the_description_in_the_file() {
    local created
    created=$(new_operation "Reset Immich password!")
    grep -qx '# Reset Immich password!' "$repo_dir/$created" || { echo "      description missing from $created"; return 1; }
}

test_the_untouched_template_runs_as_a_no_op() {
    local created
    created=$(new_operation "nothing yet")
    (cd "$repo_dir" && bash "$created" < /dev/null) || { echo "      the template must run cleanly as is"; return 1; }
}

test_refuses_a_description_without_letters_or_digits() {
    if new_operation "!!!" > /dev/null; then
        echo "      expected a refusal"
        return 1
    fi
    [ ! -d "$repo_dir/operations" ] || [ -z "$(ls -A "$repo_dir/operations")" ] || { echo "      no file should be created"; return 1; }
}

test_before_creates_an_operation_that_runs_before_the_stacks() {
    local created
    created=$(new_operation --before "Create the recyclarr folder")
    [[ "$created" =~ ^operations/[0-9]{4}_[0-9]{2}_[0-9]{2}_[0-9]{6}_create_the_recyclarr_folder\.before\.sh$ ]] \
        || { echo "      unexpected file name: $created"; return 1; }
    grep -q 'right after the pull, before any container changes' "$repo_dir/$created" \
        || { echo "      the header must say when it runs"; return 1; }
}

run_test "it creates a timestamped, executable operation named after the description" in_sandbox test_creates_a_timestamped_executable_file
run_test "--before creates a .before.sh operation that says it runs before the stacks" in_sandbox test_before_creates_an_operation_that_runs_before_the_stacks
run_test "it keeps the description at the top of the file" in_sandbox test_keeps_the_description_in_the_file
run_test "the untouched template runs as a no-op" in_sandbox test_the_untouched_template_runs_as_a_no_op
run_test "it refuses a description without letters or digits" in_sandbox test_refuses_a_description_without_letters_or_digits

finish_tests
