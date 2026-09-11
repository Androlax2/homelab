#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/deploy.sh against a throwaway git remote, with `docker` stubbed to
# record its arguments instead of touching containers.
#
# Usage: bash scripts/tests/deploy_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

# Keep the caller's git config (signing, hooks, default branch) out of the sandbox.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=deploy-test GIT_AUTHOR_EMAIL=deploy-test@example.invalid
export GIT_COMMITTER_NAME=deploy-test GIT_COMMITTER_EMAIL=deploy-test@example.invalid

# origin.git plays GitHub, dev is where changes are pushed from, nas is the
# checkout deploy.sh runs in.
create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'cleanup_sandbox $?' EXIT
    export DOCKER_CALLS_LOG="$sandbox/docker-calls.log"

    mkdir "$sandbox/bin"
    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS_LOG"
[ "${DOCKER_SHOULD_FAIL:-0}" != "1" ]
STUB
    chmod +x "$sandbox/bin/docker"
    export PATH="$sandbox/bin:$PATH"

    git init --quiet --bare --initial-branch=main "$sandbox/origin.git"
    git init --quiet --initial-branch=main "$sandbox/dev"
    mkdir -p "$sandbox/dev/scripts" "$sandbox/dev/stacks" "$sandbox/dev/config/glance"
    cp "$SCRIPTS_DIR/deploy.sh" "$SCRIPTS_DIR/compose.sh" "$SCRIPTS_DIR/lib.sh" "$sandbox/dev/scripts/"
    printf 'TZ=\n' > "$sandbox/dev/stacks/common.env.example"
    for stack in media photos; do
        mkdir -p "$sandbox/dev/stacks/$stack"
        printf 'services: {}\n' > "$sandbox/dev/stacks/$stack/compose.yml"
        printf 'API_KEY=\n' > "$sandbox/dev/stacks/$stack/.env.example"
    done
    printf 'pages: []\n' > "$sandbox/dev/config/glance/glance.yml"
    git -C "$sandbox/dev" add -A
    git -C "$sandbox/dev" commit --quiet -m "initial"
    git -C "$sandbox/dev" remote add origin "$sandbox/origin.git"
    git -C "$sandbox/dev" push --quiet origin main
    git clone --quiet "$sandbox/origin.git" "$sandbox/nas"
    printf 'TZ=Europe/Paris\n' > "$sandbox/nas/stacks/common.env"
    for stack in media photos; do
        printf 'API_KEY=secret\n' > "$sandbox/nas/stacks/$stack/.env"
    done
}

in_sandbox() {
    create_sandbox
    "$@"
}

cleanup_sandbox() {
    local exit_status="$1"
    if [ "$exit_status" -ne 0 ] && [ -f "$sandbox/deploy.out" ]; then
        sed 's/^/      deploy.sh | /' "$sandbox/deploy.out"
    fi
    rm -rf "$sandbox"
}

# $1 = file to change, $2 = line to append (defaults to a dummy edit)
push_edit() {
    printf '%s\n' "${2:-edit}" >> "$sandbox/dev/$1"
    git -C "$sandbox/dev" commit --quiet -am "edit $1"
    git -C "$sandbox/dev" push --quiet origin main
}

push_removal() {
    git -C "$sandbox/dev" rm --quiet -r "$1"
    git -C "$sandbox/dev" commit --quiet -m "remove $1"
    git -C "$sandbox/dev" push --quiet origin main
}

run_deploy() {
    bash "$sandbox/nas/scripts/deploy.sh" >> "$sandbox/deploy.out" 2>&1
}

# The docker call scripts/compose.sh makes to bring stack $1 up.
compose_up_call() {
    printf 'compose --env-file stacks/common.env --env-file stacks/%s/.env -f stacks/%s/compose.yml up -d --remove-orphans' "$1" "$1"
}

forget_docker_calls() {
    rm -f "$DOCKER_CALLS_LOG"
}

assert_docker_calls() {
    local expected_calls="$1"
    local actual_calls=""
    if [ -f "$DOCKER_CALLS_LOG" ]; then
        actual_calls=$(cat "$DOCKER_CALLS_LOG")
    fi
    if [ "$actual_calls" != "$expected_calls" ]; then
        printf '      expected docker calls:\n%s\n      actual docker calls:\n%s\n' "$expected_calls" "$actual_calls"
        return 1
    fi
}

expect_deploy_failure_mentioning() {
    if run_deploy; then
        echo "      expected deploy.sh to fail"
        return 1
    fi
    if ! grep -qF "$1" "$sandbox/deploy.out"; then
        echo "      expected the output to mention: $1"
        return 1
    fi
}

test_first_run_deploys_everything() {
    run_deploy
    assert_docker_calls "$(compose_up_call media)
$(compose_up_call photos)
restart glance"
}

test_unchanged_main_does_nothing() {
    run_deploy
    forget_docker_calls
    run_deploy
    assert_docker_calls ""
}

test_stack_change_redeploys_only_that_stack() {
    run_deploy
    forget_docker_calls
    push_edit stacks/media/compose.yml
    run_deploy
    assert_docker_calls "$(compose_up_call media)"
}

test_config_change_restarts_its_container() {
    run_deploy
    forget_docker_calls
    push_edit config/glance/glance.yml
    run_deploy
    assert_docker_calls "restart glance"
}

test_failed_deploy_is_retried() {
    run_deploy
    push_edit stacks/media/compose.yml
    if (export DOCKER_SHOULD_FAIL=1; run_deploy); then
        echo "      expected the deploy to fail"
        return 1
    fi
    forget_docker_calls
    run_deploy
    assert_docker_calls "$(compose_up_call media)"
}

test_removed_stack_is_reported_once_and_never_torn_down() {
    run_deploy
    forget_docker_calls
    push_removal stacks/photos
    expect_deploy_failure_mentioning "docker compose -p photos down"
    run_deploy
    assert_docker_calls ""
}

test_missing_key_holds_the_deploy_until_added() {
    run_deploy
    forget_docker_calls
    push_edit stacks/media/.env.example "NEW_KEY="
    expect_deploy_failure_mentioning "stacks/media/.env lacks keys from .env.example: NEW_KEY"
    assert_docker_calls ""
    printf 'NEW_KEY=value\n' >> "$sandbox/nas/stacks/media/.env"
    run_deploy
    assert_docker_calls "$(compose_up_call media)"
}

test_missing_env_file_holds_the_deploy() {
    run_deploy
    forget_docker_calls
    rm "$sandbox/nas/stacks/media/.env"
    push_edit stacks/media/compose.yml
    expect_deploy_failure_mentioning "stacks/media/.env is missing"
    assert_docker_calls ""
}

test_incomplete_common_env_holds_every_stack() {
    run_deploy
    forget_docker_calls
    push_edit stacks/common.env.example "NEW_SHARED="
    push_edit stacks/media/compose.yml
    expect_deploy_failure_mentioning "stacks/common.env lacks keys from common.env.example: NEW_SHARED"
    assert_docker_calls ""
}

run_test "it deploys every stack and restarts every config container on the first run" in_sandbox test_first_run_deploys_everything
run_test "it does nothing when main has not moved" in_sandbox test_unchanged_main_does_nothing
run_test "it only redeploys the stack whose files changed" in_sandbox test_stack_change_redeploys_only_that_stack
run_test "it restarts the container named after a changed config folder" in_sandbox test_config_change_restarts_its_container
run_test "it retries a failed deploy on the next run" in_sandbox test_failed_deploy_is_retried
run_test "it reports a removed stack once and never tears it down" in_sandbox test_removed_stack_is_reported_once_and_never_torn_down
run_test "it holds back a stack whose .env lacks a key from .env.example until the key is added" in_sandbox test_missing_key_holds_the_deploy_until_added
run_test "it holds back a stack that has no .env" in_sandbox test_missing_env_file_holds_the_deploy
run_test "it holds back every stack while common.env lacks a key from common.env.example" in_sandbox test_incomplete_common_env_holds_every_stack

finish_tests
