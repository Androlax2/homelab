#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/preview_recyclarr.sh with `docker` stubbed to record its arguments.
#
# Usage: bash scripts/tests/preview_recyclarr_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    repo_dir="$sandbox/repo"
    mkdir -p "$repo_dir/scripts" "$repo_dir/stacks/media" "$repo_dir/config/recyclarr/configs" "$sandbox/bin"
    cp "$SCRIPTS_DIR/preview_recyclarr.sh" "$SCRIPTS_DIR/lib.sh" "$repo_dir/scripts/"
    printf 'services:\n  recyclarr:\n    image: ghcr.io/recyclarr/recyclarr:9.9.9\n' > "$repo_dir/stacks/media/compose.yml"

    export DOCKER_CALLS_LOG="$sandbox/docker-calls.log"
    touch "$DOCKER_CALLS_LOG"
    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$DOCKER_CALLS_LOG"
STUB
    chmod +x "$sandbox/bin/docker"
    export PATH="$sandbox/bin:$PATH"
    export SONARR_API_KEY=sonarr-secret-key RADARR_API_KEY=radarr-secret-key
    export SONARR_URL=http://nas:8989 RADARR_URL=http://nas:7878
}

in_sandbox() {
    create_sandbox
    "$@"
}

run_preview() {
    bash "$repo_dir/scripts/preview_recyclarr.sh" < /dev/null > "$sandbox/output" 2>&1
}

# $1 = one argument docker must have received
assert_docker_argument() {
    grep -qxF -- "$1" "$DOCKER_CALLS_LOG" || { echo "      docker did not get: $1"; sed 's/^/      docker | /' "$DOCKER_CALLS_LOG"; return 1; }
}

test_previews_with_the_pinned_image() {
    run_preview
    assert_docker_argument ghcr.io/recyclarr/recyclarr:9.9.9
    [ "$(tail -n 2 "$DOCKER_CALLS_LOG" | tr '\n' ' ')" = "sync --preview " ] || { echo "      expected to end with: sync --preview"; return 1; }
}

test_mounts_the_repo_files_read_only() {
    run_preview
    assert_docker_argument "$repo_dir/config/recyclarr/configs:/config/configs:ro"
    assert_docker_argument "$repo_dir/config/recyclarr/settings.yml:/config/settings.yml:ro"
    assert_docker_argument "$repo_dir/config/recyclarr/custom-formats:/config/custom-formats:ro"
}

test_points_recyclarr_at_the_nas() {
    run_preview
    assert_docker_argument SONARR_BASE_URL=http://nas:8989
    assert_docker_argument RADARR_BASE_URL=http://nas:7878
}

test_never_puts_a_key_on_the_command_line() {
    run_preview
    assert_docker_argument SONARR_API_KEY
    assert_docker_argument RADARR_API_KEY
    if grep -q 'secret-key' "$DOCKER_CALLS_LOG"; then
        echo "      a key value reached the docker arguments"
        return 1
    fi
}

test_fails_without_a_pinned_recyclarr_image() {
    printf 'services: {}\n' > "$repo_dir/stacks/media/compose.yml"
    if run_preview; then
        echo "      expected a failure"
        return 1
    fi
    grep -q 'No ghcr.io/recyclarr/recyclarr image' "$sandbox/output" || { echo "      expected an explanation"; return 1; }
}

run_test "it previews with the Recyclarr version the media stack pins" in_sandbox test_previews_with_the_pinned_image
run_test "it mounts the repo's Recyclarr files read-only, as on the NAS" in_sandbox test_mounts_the_repo_files_read_only
run_test "it points Recyclarr at the NAS's Sonarr and Radarr" in_sandbox test_points_recyclarr_at_the_nas
run_test "it never puts an API key on the command line" in_sandbox test_never_puts_a_key_on_the_command_line
run_test "it fails when the media stack pins no Recyclarr image" in_sandbox test_fails_without_a_pinned_recyclarr_image

finish_tests
