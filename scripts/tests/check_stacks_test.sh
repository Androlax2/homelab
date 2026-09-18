#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/check_stacks.sh on a one-stack fixture repo with the real `docker compose`.
# Only `docker compose config` runs: nothing is pulled or started.
#
# Usage: bash scripts/tests/check_stacks_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    repo_dir="$sandbox/repo"
    mkdir -p "$repo_dir/scripts" "$repo_dir/stacks/app"
    cp "$SCRIPTS_DIR/check_stacks.sh" "$SCRIPTS_DIR/lib.sh" "$repo_dir/scripts/"
    printf 'TZ=\n' > "$repo_dir/stacks/common.env.example"
    printf 'API_KEY=\n' > "$repo_dir/stacks/app/.env.example"
}

# $1 = service name, $2 = extra service lines (\n escapes are expanded),
# $3 = expected result: passes | fails, $4 = text the output must contain
check_stack() {
    local service_name="$1" service_lines="$2" expected_result="$3" expected_text="$4"
    create_sandbox
    printf 'services:\n  %s:\n    image: example/app:1.0\n    container_name: app\n%b\n' \
        "$service_name" "$service_lines" > "$repo_dir/stacks/app/compose.yml"

    local exit_status=0
    bash "$repo_dir/scripts/check_stacks.sh" > "$sandbox/output" 2>&1 || exit_status=$?

    local failure=""
    if [ "$expected_result" = "passes" ] && [ "$exit_status" -ne 0 ]; then
        failure="expected check_stacks.sh to pass"
    elif [ "$expected_result" = "fails" ] && [ "$exit_status" -eq 0 ]; then
        failure="expected check_stacks.sh to fail"
    elif ! grep -qF "$expected_text" "$sandbox/output"; then
        failure="expected the output to contain: $expected_text"
    fi
    if [ -n "$failure" ]; then
        echo "      $failure"
        sed 's/^/      check_stacks.sh | /' "$sandbox/output"
        return 1
    fi
}

run_test "it passes a stack whose variables are all listed in an .env.example" \
    check_stack app '    environment:\n      - TZ=${TZ}\n      - API_KEY=${API_KEY}' passes "OK    app"
run_test "it fails a stack using a variable no .env.example lists" \
    check_stack app '    environment:\n      - TOKEN=${NOT_LISTED}' fails "NOT_LISTED"
run_test "it fails a service that mounts the Docker socket without being allowed to" \
    check_stack app '    volumes:\n      - /var/run/docker.sock:/var/run/docker.sock:ro' fails "app: mounts the Docker socket"
run_test "it lets the Docker socket proxy mount the Docker socket" \
    check_stack docker-socket-proxy '    volumes:\n      - /var/run/docker.sock:/var/run/docker.sock:ro' passes "OK    app"
run_test "it fails a privileged service" \
    check_stack app '    privileged: true' fails "app: privileged: true"
run_test "it fails a stack docker compose rejects" \
    check_stack app '    ports:\n      - "not-a-port"' fails "FAIL  app"
run_test "it fails a service with a writable volume but no homelab.backup label" \
    check_stack app '    volumes:\n      - /check/data:/data' fails "app: has a writable volume but no homelab.backup label"
run_test "it lets a service with only read-only volumes skip the homelab.backup label" \
    check_stack app '    volumes:\n      - /check/data:/data:ro' passes "OK    app"
run_test "it passes a service whose writable volume has a homelab.backup label" \
    check_stack app '    labels:\n      homelab.backup: "sqlite"\n    volumes:\n      - /check/data:/data' passes "OK    app"
run_test "it accepts the sqlite-unchecked homelab.backup kind" \
    check_stack app '    labels:\n      homelab.backup: "sqlite-unchecked"\n    volumes:\n      - /check/data:/data' passes "OK    app"
run_test "it checks services behind a compose profile too" \
    check_stack app '    profiles: ["manual"]\n    volumes:\n      - /check/data:/data' fails "app: has a writable volume but no homelab.backup label"
run_test "it fails an unknown homelab.backup kind" \
    check_stack app '    labels:\n      homelab.backup: "mongo"\n    volumes:\n      - /check/data:/data' fails 'app: unknown homelab.backup label "mongo"'

finish_tests
