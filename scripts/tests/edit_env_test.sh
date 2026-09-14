#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/edit_env.sh with a scripted "editor" and `docker` stubbed to
# record its arguments.
#
# Usage: bash scripts/tests/edit_env_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    repo_dir="$sandbox/repo"
    mkdir -p "$repo_dir/scripts" "$repo_dir/stacks" "$sandbox/bin"
    cp "$SCRIPTS_DIR/edit_env.sh" "$SCRIPTS_DIR/compose.sh" "$SCRIPTS_DIR/lib.sh" "$repo_dir/scripts/"
    printf 'TZ=\n' > "$repo_dir/stacks/common.env.example"
    printf 'TZ=Europe/Paris\n' > "$repo_dir/stacks/common.env"
    add_stack app 'API_KEY=\nMODE=\n' 'API_KEY=old\nMODE=live\n'
    stack_dir="$repo_dir/stacks/app"

    export DOCKER_CALLS_LOG="$sandbox/docker-calls.log"
    touch "$DOCKER_CALLS_LOG"
    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS_LOG"
case "$*" in
    *" config --services")
        # STUB_PROFILE_ONLY=1: every service of the stack is behind a profile.
        [ "${STUB_PROFILE_ONLY:-0}" = "1" ] || echo app
        ;;
    *" config --format json")
        if [ "${DOCKER_CONFIG_SHOULD_FAIL:-0}" = "1" ]; then
            echo "invalid interpolation format" >&2
            exit 1
        fi
        echo '{}'
        ;;
esac
STUB
    chmod +x "$sandbox/bin/docker"
    export PATH="$sandbox/bin:$PATH"
}

# $1 = stack, $2 = its .env.example content ("" = none), $3 = its .env content ("" = none)
add_stack() {
    mkdir -p "$repo_dir/stacks/$1"
    printf 'services: {}\n' > "$repo_dir/stacks/$1/compose.yml"
    if [ -n "$2" ]; then
        printf '%b' "$2" > "$repo_dir/stacks/$1/.env.example"
    fi
    if [ -n "$3" ]; then
        printf '%b' "$3" > "$repo_dir/stacks/$1/.env"
    fi
}

in_sandbox() {
    create_sandbox
    "$@"
}

# $1 = what to edit (a stack or common), $2 = shell snippet the fake editor runs on the draft ($1 inside it)
run_edit() {
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$sandbox/bin/fake-editor"
    chmod +x "$sandbox/bin/fake-editor"
    EDITOR="$sandbox/bin/fake-editor" bash "$repo_dir/scripts/edit_env.sh" "$1" < /dev/null > "$sandbox/output" 2>&1
}

# $1 = stack; counts the times it was brought up
redeploy_count() {
    grep -c -- "-f stacks/$1/compose.yml up -d" "$DOCKER_CALLS_LOG" || true
}

fail_with_output() {
    echo "      $1"
    sed 's/^/      edit_env.sh | /' "$sandbox/output"
    return 1
}

test_profile_only_stack_is_saved_without_compose_up() {
    export STUB_PROFILE_ONLY=1
    run_edit app 'sed -i "s/^API_KEY=.*/API_KEY=new/" "$1"' || fail_with_output "expected success"
    grep -qx 'API_KEY=new' "$stack_dir/.env" || fail_with_output ".env was not updated"
    [ "$(redeploy_count app)" -eq 0 ] || fail_with_output "a stack with nothing to run must not be brought up"
}

test_valid_edit_replaces_env_and_redeploys() {
    run_edit app 'sed -i "s/^API_KEY=.*/API_KEY=new/" "$1"' || fail_with_output "expected success"
    grep -qx 'API_KEY=new' "$stack_dir/.env" || fail_with_output ".env was not updated"
    grep -qx 'API_KEY=old' "$stack_dir/.env.previous" || fail_with_output ".env.previous does not hold the old value"
    [ "$(redeploy_count app)" -eq 1 ] || fail_with_output "expected exactly one redeploy"
}

test_secrets_stay_owner_only() {
    run_edit app 'sed -i "s/^API_KEY=.*/API_KEY=new/" "$1"' || fail_with_output "expected success"
    [ "$(stat -c %a "$stack_dir/.env")" = "600" ] || fail_with_output ".env is $(stat -c %a "$stack_dir/.env"), expected 600"
    [ "$(stat -c %a "$stack_dir/.env.previous")" = "600" ] || fail_with_output ".env.previous is $(stat -c %a "$stack_dir/.env.previous"), expected 600"
}

test_unchanged_draft_does_not_redeploy() {
    run_edit app 'true' || fail_with_output "expected success"
    grep -q 'No changes' "$sandbox/output" || fail_with_output "expected 'No changes'"
    [ "$(redeploy_count app)" -eq 0 ] || fail_with_output "expected no redeploy"
}

test_missing_env_starts_from_example() {
    rm "$stack_dir/.env"
    run_edit app 'sed -i "s/^API_KEY=.*/API_KEY=first/" "$1"' || fail_with_output "expected success"
    grep -qx 'API_KEY=first' "$stack_dir/.env" || fail_with_output ".env was not created from .env.example"
    [ ! -e "$stack_dir/.env.previous" ] || fail_with_output "no .env.previous expected"
    [ "$(redeploy_count app)" -eq 1 ] || fail_with_output "expected exactly one redeploy"
}

# $1 = editor snippet, $2 = whether `docker compose config` fails (0/1), $3 = text the output must mention
check_rejected_edit() {
    local editor_snippet="$1" expected_text="$3"
    export DOCKER_CONFIG_SHOULD_FAIL="$2"
    local original_env
    original_env=$(cat "$stack_dir/.env")
    if run_edit app "$editor_snippet"; then
        fail_with_output "expected a failure"
    fi
    [ "$(cat "$stack_dir/.env")" = "$original_env" ] || fail_with_output ".env was modified"
    [ ! -e "$stack_dir/.env.previous" ] || fail_with_output "no .env.previous expected"
    [ "$(redeploy_count app)" -eq 0 ] || fail_with_output "expected no redeploy"
    grep -qF "$expected_text" "$sandbox/output" || fail_with_output "expected the output to mention: $expected_text"
}

test_common_edit_redeploys_every_deployable_stack() {
    add_stack web 'API_KEY=\n' ''
    add_stack bare '' ''
    run_edit common 'sed -i "s/^TZ=.*/TZ=UTC/" "$1"' || fail_with_output "expected success"
    grep -qx 'TZ=UTC' "$repo_dir/stacks/common.env" || fail_with_output "common.env was not updated"
    [ "$(redeploy_count app)" -eq 1 ] || fail_with_output "expected app to be redeployed"
    [ "$(redeploy_count bare)" -eq 1 ] || fail_with_output "expected bare (no .env.example) to be redeployed"
    [ "$(redeploy_count web)" -eq 0 ] || fail_with_output "web has no .env yet: it must not be redeployed"
}

test_stack_edit_needs_common_env_first() {
    rm "$repo_dir/stacks/common.env"
    if run_edit app 'true'; then
        fail_with_output "expected a failure"
    fi
    grep -qF "Create stacks/common.env first" "$sandbox/output" || fail_with_output "expected a hint to create common.env"
}

test_stack_without_env_example_is_refused() {
    add_stack bare '' ''
    if run_edit bare 'true'; then
        fail_with_output "expected a failure"
    fi
    grep -qF "has no .env.example" "$sandbox/output" || fail_with_output "expected an explanation"
}

run_test "it replaces .env, keeps the previous one and redeploys the stack" in_sandbox test_valid_edit_replaces_env_and_redeploys
run_test "it saves the .env of a stack whose services are all behind a profile without bringing it up" in_sandbox test_profile_only_stack_is_saved_without_compose_up
run_test "it keeps .env and .env.previous readable by their owner only" in_sandbox test_secrets_stay_owner_only
run_test "it does not redeploy when nothing changed" in_sandbox test_unchanged_draft_does_not_redeploy
run_test "it starts from .env.example when the stack has no .env yet" in_sandbox test_missing_env_starts_from_example
run_test "it leaves .env untouched when a key from .env.example is missing" \
    in_sandbox check_rejected_edit 'sed -i "/^MODE=/d" "$1"' 0 "Missing keys from .env.example: MODE"
run_test "it leaves .env untouched when docker compose rejects it" \
    in_sandbox check_rejected_edit 'sed -i "s/^API_KEY=.*/API_KEY=new/" "$1"' 1 "invalid interpolation format"
run_test "it redeploys every deployable stack after editing common.env" in_sandbox test_common_edit_redeploys_every_deployable_stack
run_test "it asks for common.env before a stack's .env" in_sandbox test_stack_edit_needs_common_env_first
run_test "it refuses to edit a stack that has no .env.example" in_sandbox test_stack_without_env_example_is_refused

finish_tests
