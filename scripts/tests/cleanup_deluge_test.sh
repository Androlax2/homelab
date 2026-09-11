#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/cleanup_deluge.sh with `docker` and `curl` stubbed: Deluge holds one
# torrent (TORRENT_NAME) and the downloads folder one orphaned file (ORPHAN_FILE).
# By default the orphan sits in the torrent's own folder, so a healthy run removes
# that torrent.
#
# Usage: bash scripts/tests/cleanup_deluge_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

export TORRENT_HASH=0123456789abcdef0123456789abcdef01234567

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    mkdir "$sandbox/bin"
    export DOCKER_CALLS_LOG="$sandbox/docker-calls.log"
    touch "$DOCKER_CALLS_LOG"
    export TORRENT_NAME=Show.S01 ORPHAN_FILE=/downloads/Show.S01/Show.S01E01.mkv

    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS_LOG"
case "$*" in
    "exec deluge deluge-console -c /config/ info")
        printf '[S]   100%% %s %s\n    DL: 1 G (0 B) UL: 2 G (0 B) ETA: -\n' "$TORRENT_NAME" "$TORRENT_HASH" ;;
    "exec deluge find "*)
        printf '%s\0' "$ORPHAN_FILE" ;;
esac
STUB
    cat > "$sandbox/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *":${CURL_FAILING_PORT:-none}/"*) exit 22 ;;
esac
printf '{"records": []}'
STUB
    chmod +x "$sandbox/bin/docker" "$sandbox/bin/curl"
    export PATH="$sandbox/bin:$PATH"
}

removal_count() {
    grep -c "rm $TORRENT_HASH" "$DOCKER_CALLS_LOG" || true
}

fail_with_output() {
    echo "      $1"
    sed 's/^/      cleanup_deluge.sh | /' "$sandbox/output"
    return 1
}

run_cleanup() {
    SONARR_API_KEY=test RADARR_API_KEY=test bash "$SCRIPTS_DIR/cleanup_deluge.sh" > "$sandbox/output" 2>&1
}

# $1 = port whose queue API fails ("none" = both answer), $2 = expected outcome: removes | stops
check_queue_outcome() {
    local failing_port="$1" expected_outcome="$2"
    create_sandbox
    local exit_status=0
    CURL_FAILING_PORT="$failing_port" run_cleanup || exit_status=$?

    if [ "$expected_outcome" = "removes" ]; then
        [ "$exit_status" -eq 0 ] || fail_with_output "expected exit 0, got $exit_status"
        [ "$(removal_count)" -eq 1 ] || fail_with_output "expected the orphaned torrent to be removed"
    else
        [ "$exit_status" -ne 0 ] || fail_with_output "expected a non-zero exit"
        [ "$(removal_count)" -eq 0 ] || fail_with_output "expected nothing to be removed"
    fi
}

# $1 = torrent name, $2 = orphan file whose folder name only shares a prefix with it
check_prefix_is_not_a_match() {
    create_sandbox
    export TORRENT_NAME="$1" ORPHAN_FILE="$2"
    local exit_status=0
    run_cleanup || exit_status=$?
    [ "$exit_status" -eq 0 ] || fail_with_output "expected exit 0, got $exit_status"
    [ "$(removal_count)" -eq 0 ] || fail_with_output "removed torrent $1, which is not the orphan's torrent"
}

# $@ = the API key assignments to keep; the other key is left unset
check_missing_key() {
    create_sandbox
    local exit_status=0
    env -u SONARR_API_KEY -u RADARR_API_KEY "$@" \
        bash "$SCRIPTS_DIR/cleanup_deluge.sh" > "$sandbox/output" 2>&1 || exit_status=$?
    [ "$exit_status" -ne 0 ] || fail_with_output "expected a non-zero exit"
    [ ! -s "$DOCKER_CALLS_LOG" ] || fail_with_output "expected no docker call at all"
}

run_test "it removes an orphaned torrent when both queues answer" check_queue_outcome none removes
run_test "it stops before deleting anything when the Sonarr queue is unreachable" check_queue_outcome 8989 stops
run_test "it stops before deleting anything when the Radarr queue is unreachable" check_queue_outcome 7878 stops
run_test "it never removes a torrent whose name only starts like the orphan's folder" \
    check_prefix_is_not_a_match Dune.Part.Two.2024.2160p /downloads/Dune/Dune.mkv
run_test "it never removes a torrent whose name is only the start of the orphan's folder" \
    check_prefix_is_not_a_match Dune /downloads/Dune.Part.Two.2024.2160p/Dune.Part.Two.mkv
run_test "it refuses to run without SONARR_API_KEY" check_missing_key RADARR_API_KEY=test
run_test "it refuses to run without RADARR_API_KEY" check_missing_key SONARR_API_KEY=test

finish_tests
