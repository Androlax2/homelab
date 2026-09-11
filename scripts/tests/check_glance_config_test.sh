#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/check_glance_config.sh with `docker` stubbed: checks which image it
# runs and which variables it hands to Glance. Glance itself only runs in CI.
#
# Usage: bash scripts/tests/check_glance_config_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    repo_dir="$sandbox/repo"
    mkdir -p "$repo_dir/scripts" "$repo_dir/stacks/infrastructure" "$repo_dir/config/glance/config" "$sandbox/bin"
    cp "$SCRIPTS_DIR/check_glance_config.sh" "$repo_dir/scripts/"
    printf 'services:\n  glance:\n    image: glanceapp/glance:v9.9.9\n' > "$repo_dir/stacks/infrastructure/compose.yml"
    printf '# a comment\nTZ=\nLAN_IP=\n' > "$repo_dir/stacks/common.env.example"
    printf 'GLANCE_SECRET_KEY=\nGLANCE_USERNAME=\nGLANCE_PASSWORD_HASH=\nSONARR_URL=\n' > "$repo_dir/stacks/infrastructure/.env.example"

    export DOCKER_CALLS_LOG="$sandbox/docker-calls.log" ENV_FILE_COPY="$sandbox/env-file-given-to-docker"
    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS_LOG"
while [ $# -gt 0 ]; do
    if [ "$1" = "--env-file" ]; then
        cp "$2" "$ENV_FILE_COPY"
    fi
    shift
done
STUB
    chmod +x "$sandbox/bin/docker"
    export PATH="$sandbox/bin:$PATH"
}

in_sandbox() {
    create_sandbox
    "$@"
}

run_check() {
    bash "$repo_dir/scripts/check_glance_config.sh" > "$sandbox/output" 2>&1
}

fail_with() {
    echo "      $1"
    sed 's/^/      check_glance_config.sh | /' "$sandbox/output" "$DOCKER_CALLS_LOG" 2>/dev/null
    return 1
}

test_validates_with_the_pinned_image() {
    run_check || fail_with "expected success"
    grep -q ' glanceapp/glance:v9.9.9 config:validate$' "$DOCKER_CALLS_LOG" || fail_with "expected config:validate with the pinned image"
    grep -q -- "-v $repo_dir/config/glance/config:/app/config:ro" "$DOCKER_CALLS_LOG" || fail_with "expected config/glance mounted read-only"
}

test_passes_every_example_variable() {
    run_check || fail_with "expected success"
    for key in TZ LAN_IP SONARR_URL GLANCE_SECRET_KEY GLANCE_USERNAME GLANCE_PASSWORD_HASH; do
        grep -q "^$key=" "$ENV_FILE_COPY" || fail_with "expected $key in the env file"
    done
    ! grep -q '^#' "$ENV_FILE_COPY" || fail_with "comments must not reach docker"
}

test_fills_the_login_values_glance_requires() {
    run_check || fail_with "expected success"
    grep -qx 'GLANCE_USERNAME=check' "$ENV_FILE_COPY" || fail_with "expected a username of 3+ characters"
    grep -qx 'GLANCE_SECRET_KEY=check' "$ENV_FILE_COPY" || fail_with "expected a non-empty secret key"
    grep -qx 'GLANCE_PASSWORD_HASH=check' "$ENV_FILE_COPY" || fail_with "expected a non-empty password hash"
}

test_fails_without_a_glance_image() {
    printf 'services: {}\n' > "$repo_dir/stacks/infrastructure/compose.yml"
    if run_check; then
        fail_with "expected a failure"
    fi
    grep -q 'No glanceapp/glance image' "$sandbox/output" || fail_with "expected an explanation"
}

run_test "it validates config/glance with the Glance image the stack pins" in_sandbox test_validates_with_the_pinned_image
run_test "it gives Glance every variable of the .env.example files" in_sandbox test_passes_every_example_variable
run_test "it fills the login values Glance requires" in_sandbox test_fills_the_login_values_glance_requires
run_test "it fails when the stack pins no Glance image" in_sandbox test_fails_without_a_glance_image

finish_tests
