#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/deploy.sh against a throwaway git remote, with `docker` stubbed to
# record its arguments instead of touching containers.
#
# Usage: bash scripts/tests/deploy_test.sh

DEPLOY_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy.sh"

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
    mkdir -p "$sandbox/dev/scripts" "$sandbox/dev/stacks/media" "$sandbox/dev/stacks/photos" "$sandbox/dev/config/glance"
    cp "$DEPLOY_SCRIPT" "$sandbox/dev/scripts/deploy.sh"
    printf 'services: {}\n' > "$sandbox/dev/stacks/media/compose.yml"
    printf 'services: {}\n' > "$sandbox/dev/stacks/photos/compose.yml"
    printf 'pages: []\n' > "$sandbox/dev/config/glance/glance.yml"
    git -C "$sandbox/dev" add -A
    git -C "$sandbox/dev" commit --quiet -m "initial"
    git -C "$sandbox/dev" remote add origin "$sandbox/origin.git"
    git -C "$sandbox/dev" push --quiet origin main
    git clone --quiet "$sandbox/origin.git" "$sandbox/nas"
}

cleanup_sandbox() {
    local exit_status="$1"
    if [ "$exit_status" -ne 0 ] && [ -f "$sandbox/deploy.out" ]; then
        sed 's/^/      deploy.sh | /' "$sandbox/deploy.out"
    fi
    rm -rf "$sandbox"
}

push_edit() {
    printf 'edit\n' >> "$sandbox/dev/$1"
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

test_first_run_deploys_everything() {
    run_deploy
    assert_docker_calls "compose -f stacks/media/compose.yml up -d --remove-orphans
compose -f stacks/photos/compose.yml up -d --remove-orphans
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
    assert_docker_calls "compose -f stacks/media/compose.yml up -d --remove-orphans"
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
    assert_docker_calls "compose -f stacks/media/compose.yml up -d --remove-orphans"
}

test_removed_stack_is_reported_once_and_never_torn_down() {
    run_deploy
    forget_docker_calls
    push_removal stacks/photos
    if run_deploy; then
        echo "      expected a non-zero exit asking for a manual teardown"
        return 1
    fi
    if ! grep -q 'docker compose -p photos down' "$sandbox/deploy.out"; then
        echo "      expected the teardown command in the output"
        return 1
    fi
    run_deploy
    assert_docker_calls ""
}

passed=0
failed=0

run_test() {
    local description="$1"
    local test_function="$2"
    local test_status

    # Not `( ... ) || status=$?`: that context silently disables set -e inside the subshell.
    set +e
    (
        set -e
        create_sandbox
        "$test_function"
    )
    test_status=$?
    set -e

    if [ "$test_status" -eq 0 ]; then
        printf 'PASS  %s\n' "$description"
        passed=$((passed + 1))
    else
        printf 'FAIL  %s\n' "$description"
        failed=$((failed + 1))
    fi
}

run_test "it deploys every stack and restarts every config container on the first run" test_first_run_deploys_everything
run_test "it does nothing when main has not moved" test_unchanged_main_does_nothing
run_test "it only redeploys the stack whose files changed" test_stack_change_redeploys_only_that_stack
run_test "it restarts the container named after a changed config folder" test_config_change_restarts_its_container
run_test "it retries a failed deploy on the next run" test_failed_deploy_is_retried
run_test "it reports a removed stack once and never tears it down" test_removed_stack_is_reported_once_and_never_torn_down

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
