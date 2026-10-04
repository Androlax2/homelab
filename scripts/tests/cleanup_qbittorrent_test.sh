#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/cleanup_qbittorrent.sh with `docker` and `curl` stubbed: qBittorrent holds
# the torrent under test (its content at TORRENT_CONTENT_PATH, saved in TORRENT_SAVE_PATH)
# and an unrelated one, and the downloads folder one orphaned file (ORPHAN_FILE), old
# enough to be purged. By default the orphan sits in the folder of the torrent under test,
# so a healthy run removes that torrent and only that one. The stub answers a login like
# qBittorrent 5 unless a test says otherwise: QBITTORRENT_LOGIN_ANSWER is the body of a
# 200, or "refused" for the 401 qBittorrent 5 answers a wrong login with.
#
# Usage: bash scripts/tests/cleanup_qbittorrent_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

export TORRENT_HASH=0123456789abcdef0123456789abcdef01234567
export UNRELATED_TORRENT_HASH=ffffffffffffffffffffffffffffffffffffffff

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    mkdir "$sandbox/bin"
    export DOCKER_CALLS_LOG="$sandbox/docker-calls.log" CURL_CALLS_LOG="$sandbox/curl-calls.log"
    touch "$DOCKER_CALLS_LOG" "$CURL_CALLS_LOG"
    export TORRENT_CONTENT_PATH=/downloads/Show.S01 TORRENT_SAVE_PATH=/downloads
    export ORPHAN_FILE=/downloads/Show.S01/Show.S01E01.mkv
    export QBITTORRENT_LOGIN_ANSWER=""
    export QBITTORRENT_USERNAME=admin QBITTORRENT_PASSWORD=test SONARR_API_KEY=test RADARR_API_KEY=test

    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS_LOG"
case "$*" in
    "exec qbittorrent find "*)
        printf '%s\0' "$ORPHAN_FILE" ;;
esac
STUB
    # TORRENT_CONTENT_PATH empty: qBittorrent holds no torrent at all.
    cat > "$sandbox/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_CALLS_LOG"
case "$*" in
    *":${CURL_FAILING_PORT:-none}/"*) exit 22 ;;
    *"/api/v2/auth/login")
        [ "$QBITTORRENT_LOGIN_ANSWER" != refused ] || exit 22
        printf '%s' "$QBITTORRENT_LOGIN_ANSWER"
        ;;
    *"/api/v2/torrents/info")
        if [ -z "$TORRENT_CONTENT_PATH" ]; then
            printf '[]'
        else
            printf '[{"hash": "%s", "content_path": "%s", "save_path": "%s"},' \
                "$TORRENT_HASH" "$TORRENT_CONTENT_PATH" "$TORRENT_SAVE_PATH"
            printf ' {"hash": "%s", "content_path": "/downloads/Unrelated.Release", "save_path": "/downloads"}]' \
                "$UNRELATED_TORRENT_HASH"
        fi
        ;;
    *"/api/v2/torrents/delete") ;;
    *) printf '{"records": []}' ;;
esac
STUB
    chmod +x "$sandbox/bin/docker" "$sandbox/bin/curl"
    export PATH="$sandbox/bin:$PATH"
}

# Prints the hashes of the torrents removed with their files, one per line.
removed_hashes() {
    sed -n 's/.*hashes=\([0-9a-f]*\) .*deleteFiles=true .*\/api\/v2\/torrents\/delete$/\1/p' "$CURL_CALLS_LOG"
}

purge_count() {
    grep -c '^exec qbittorrent rm -f ' "$DOCKER_CALLS_LOG" || true
}

fail_with_output() {
    echo "      $1"
    sed 's/^/      cleanup_qbittorrent.sh | /' "$sandbox/output"
    return 1
}

run_cleanup() {
    bash "$SCRIPTS_DIR/cleanup_qbittorrent.sh" > "$sandbox/output" 2>&1
}

# $1 = port whose API fails ("none" = all answer), $2 = expected outcome: removes | stops
check_api_outcome() {
    local failing_port="$1" expected_outcome="$2"
    create_sandbox
    local exit_status=0
    CURL_FAILING_PORT="$failing_port" run_cleanup || exit_status=$?

    if [ "$expected_outcome" = "removes" ]; then
        [ "$exit_status" -eq 0 ] || fail_with_output "expected exit 0, got $exit_status"
        [ "$(removed_hashes)" = "$TORRENT_HASH" ] || fail_with_output "expected the orphaned torrent, and only it, to be removed"
    else
        [ "$exit_status" -ne 0 ] || fail_with_output "expected a non-zero exit"
        [ -z "$(removed_hashes)" ] || fail_with_output "expected no torrent to be removed"
        [ "$(purge_count)" -eq 0 ] || fail_with_output "expected no file to be purged"
    fi
}

# $1 = the torrent's content path, $2 = its save path, $3 = orphan file inside that content
check_torrent_is_removed() {
    create_sandbox
    export TORRENT_CONTENT_PATH="$1" TORRENT_SAVE_PATH="$2" ORPHAN_FILE="$3"
    local exit_status=0
    run_cleanup || exit_status=$?
    [ "$exit_status" -eq 0 ] || fail_with_output "expected exit 0, got $exit_status"
    [ "$(removed_hashes)" = "$TORRENT_HASH" ] || fail_with_output "expected the torrent at $1, and only it, to be removed"
}

# $1 = the torrent's content path, $2 = its save path, $3 = orphan file that is not its own
check_torrent_is_kept() {
    create_sandbox
    export TORRENT_CONTENT_PATH="$1" TORRENT_SAVE_PATH="$2" ORPHAN_FILE="$3"
    local exit_status=0
    run_cleanup || exit_status=$?
    [ "$exit_status" -eq 0 ] || fail_with_output "expected exit 0, got $exit_status"
    [ -z "$(removed_hashes)" ] || fail_with_output "removed a torrent, when none is the orphan's"
}

# $1 = what qBittorrent answers a good login with
check_login_is_accepted() {
    create_sandbox
    export QBITTORRENT_LOGIN_ANSWER="$1"
    local exit_status=0
    run_cleanup || exit_status=$?
    [ "$exit_status" -eq 0 ] || fail_with_output "expected exit 0, got $exit_status"
    [ "$(removed_hashes)" = "$TORRENT_HASH" ] || fail_with_output "expected the orphaned torrent to be removed"
}

# $@ = what makes the run stop before deleting, as environment assignments
check_run_stops() {
    create_sandbox
    export "$@"
    local exit_status=0
    run_cleanup || exit_status=$?
    [ "$exit_status" -ne 0 ] || fail_with_output "expected a non-zero exit"
    [ -z "$(removed_hashes)" ] || fail_with_output "expected no torrent to be removed"
    [ "$(purge_count)" -eq 0 ] || fail_with_output "expected no file to be purged"
}

# $1 = the variable left unset
check_missing_variable() {
    create_sandbox
    local exit_status=0
    env -u "$1" bash "$SCRIPTS_DIR/cleanup_qbittorrent.sh" > "$sandbox/output" 2>&1 || exit_status=$?
    [ "$exit_status" -ne 0 ] || fail_with_output "expected a non-zero exit"
    [ ! -s "$DOCKER_CALLS_LOG" ] || fail_with_output "expected no docker call at all"
    [ ! -s "$CURL_CALLS_LOG" ] || fail_with_output "expected no curl call at all"
}

run_test "it removes an orphaned torrent when both queues answer" check_api_outcome none removes
run_test "it stops before deleting anything when the Sonarr queue is unreachable" check_api_outcome 8989 stops
run_test "it stops before deleting anything when the Radarr queue is unreachable" check_api_outcome 7878 stops
run_test "it stops before deleting anything when qBittorrent is unreachable" check_api_outcome 8080 stops
run_test "it stops before deleting anything when qBittorrent 5 refuses the login" check_run_stops QBITTORRENT_LOGIN_ANSWER=refused
run_test "it stops before deleting anything when qBittorrent 4 refuses the login" check_run_stops QBITTORRENT_LOGIN_ANSWER=Fails.
run_test "it takes qBittorrent 5's empty answer as a good login" check_login_is_accepted ""
run_test "it takes qBittorrent 4's Ok. as a good login" check_login_is_accepted Ok.
run_test "it stops before purging anything when qBittorrent lists no torrent" check_run_stops TORRENT_CONTENT_PATH=
run_test "it removes a single-file torrent whose file is the orphan" \
    check_torrent_is_removed /downloads/Film.2024.mkv /downloads /downloads/Film.2024.mkv
run_test "it removes the torrent of an orphan nested deeper in its folder" \
    check_torrent_is_removed /downloads/Show.S01 /downloads /downloads/Show.S01/Show.S01E01/Show.S01E01.mkv
run_test "it never removes a torrent whose folder only starts like the orphan's folder" \
    check_torrent_is_kept /downloads/Dune.Part.Two.2024.2160p /downloads /downloads/Dune/Dune.mkv
run_test "it never removes a torrent whose folder is only the start of the orphan's folder" \
    check_torrent_is_kept /downloads/Dune /downloads /downloads/Dune.Part.Two.2024.2160p/Dune.Part.Two.mkv
run_test "it never removes a torrent that has no folder of its own" \
    check_torrent_is_kept /downloads/tv /downloads/tv /downloads/tv/Show.S01E01.mkv
run_test "it refuses to run without QBITTORRENT_USERNAME" check_missing_variable QBITTORRENT_USERNAME
run_test "it refuses to run without QBITTORRENT_PASSWORD" check_missing_variable QBITTORRENT_PASSWORD
run_test "it refuses to run without SONARR_API_KEY" check_missing_variable SONARR_API_KEY
run_test "it refuses to run without RADARR_API_KEY" check_missing_variable RADARR_API_KEY

finish_tests
