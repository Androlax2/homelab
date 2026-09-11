#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/premigration_check.sh against fixture JSON: `docker` is stubbed to
# return a compose config, a running container and its image. The base fixtures
# match each other; every case changes one thing.
#
# Usage: bash scripts/tests/premigration_check_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    repo_dir="$sandbox/repo"
    export FIXTURES_DIR="$sandbox/fixtures"
    mkdir -p "$repo_dir/scripts" "$repo_dir/stacks/app" "$sandbox/bin" "$FIXTURES_DIR"
    cp "$SCRIPTS_DIR/premigration_check.sh" "$SCRIPTS_DIR/compose.sh" "$repo_dir/scripts/"
    printf 'services: {}\n' > "$repo_dir/stacks/app/compose.yml"
    printf 'TZ=Europe/Paris\n' > "$repo_dir/stacks/common.env"

    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    compose) cat "$FIXTURES_DIR/config.json" ;;
    image) cat "$FIXTURES_DIR/image.json" ;;
    inspect) cat "$FIXTURES_DIR/container-$2.json" 2>/dev/null ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$sandbox/bin/docker"
    export PATH="$sandbox/bin:$PATH"

    cat > "$FIXTURES_DIR/config.json" <<'JSON'
{"services": {"app": {
    "container_name": "app",
    "image": "example/app:1.2.0",
    "environment": {"API_KEY": "old-secret"},
    "volumes": [{"type": "bind", "source": "/volume1/appdata/app", "target": "/config"}]
}}}
JSON
    cat > "$FIXTURES_DIR/container-app.json" <<'JSON'
[{"Image": "sha256:0123",
  "Config": {"Image": "example/app:1.2.0", "Env": ["PATH=/usr/bin", "API_KEY=old-secret"]},
  "Mounts": [{"Type": "bind", "Source": "/volume1/appdata/app", "Destination": "/config"}]}]
JSON
    cat > "$FIXTURES_DIR/image.json" <<'JSON'
[{"Config": {"Env": ["PATH=/usr/bin"], "Labels": {"org.opencontainers.image.version": "1.1.0"}}}]
JSON
}

# $1 = fixture file, $2 = jq filter ($repo is the sandbox repo path)
rewrite_fixture() {
    local fixture="$FIXTURES_DIR/$1"
    jq --arg repo "$repo_dir" "$2" "$fixture" > "$fixture.new"
    mv "$fixture.new" "$fixture"
}

# $1 = expected exit status, $2 = text the output must contain, $3 = text it must not contain ("" = none),
# $4 = jq filter for the compose config, $5 = jq filter for the running container ("delete" removes it)
check_case() {
    local expected_exit="$1" expected_text="$2" forbidden_text="$3" config_filter="$4" container_filter="$5"
    create_sandbox
    rewrite_fixture config.json "$config_filter"
    if [ "$container_filter" = "delete" ]; then
        rm "$FIXTURES_DIR/container-app.json"
    else
        rewrite_fixture container-app.json "$container_filter"
    fi

    local actual_exit=0
    bash "$repo_dir/scripts/premigration_check.sh" app > "$sandbox/output" 2>&1 || actual_exit=$?

    local failure=""
    if [ "$actual_exit" -ne "$expected_exit" ]; then
        failure="expected exit $expected_exit, got $actual_exit"
    elif ! grep -qF "$expected_text" "$sandbox/output"; then
        failure="expected the output to contain: $expected_text"
    elif [ -n "$forbidden_text" ] && grep -qF "$forbidden_text" "$sandbox/output"; then
        failure="the output must not contain: $forbidden_text"
    fi
    if [ -n "$failure" ]; then
        echo "      $failure"
        sed 's/^/      premigration_check.sh | /' "$sandbox/output"
        return 1
    fi
}

run_test "it passes when the running container matches the new compose file" \
    check_case 0 "No differences" "" '.' '.'
run_test "it flags a bind mount whose source changes" \
    check_case 1 "mount source changes: /config: /volume1/appdata/app -> /volume2/app" "" \
    '.services.app.volumes[0].source = "/volume2/app"' '.'
run_test "it accepts a mount moving into the repo's config folder" \
    check_case 0 "(expected) mount moves into the repo: /config" "" \
    '.services.app.volumes[0].source = $repo + "/config/app"' '.'
run_test "it flags a mount the new compose file drops" \
    check_case 1 "mount dropped: /config (was /volume1/appdata/app)" "" '.services.app.volumes = []' '.'
run_test "it flags data kept in a Docker volume" \
    check_case 1 "Docker volume at /cache" "" \
    '.' '.[0].Mounts += [{"Type": "volume", "Name": "0abc", "Destination": "/cache"}]'
run_test "it flags a changed variable without printing either value" \
    check_case 1 "env changed: API_KEY" "secret" '.services.app.environment.API_KEY = "new-secret"' '.'
run_test "it flags a variable the running container has but the new compose file drops" \
    check_case 1 "env dropped: STACK_ENV_FILE" "" '.' '.[0].Config.Env += ["STACK_ENV_FILE=stack.env"]'
run_test "it flags a variable only the new compose file sets" \
    check_case 1 "env new: TZ" "" '.services.app.environment.TZ = "Europe/Paris"' '.'
run_test "it ignores variables the image sets itself" \
    check_case 0 "No differences" "PATH" '.' '.'
run_test "it flags a service whose container does not exist" \
    check_case 1 "no container named app" "" '.' 'delete'
run_test "it shows the running version when the image changes" \
    check_case 0 "image: example/app:latest (running version: 1.1.0) -> example/app:1.2.0" "" \
    '.' '.[0].Config.Image = "example/app:latest"'

finish_tests
