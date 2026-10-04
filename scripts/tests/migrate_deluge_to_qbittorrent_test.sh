#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/migrate_deluge_to_qbittorrent.sh in a sandbox repo with `curl` stubbed as both
# web UIs: Deluge holds two torrents (a labelled one saved in /downloads/tv, an unlabelled one
# in /downloads), each with its .torrent file, and qBittorrent starts empty. The stub lists a
# torrent in qBittorrent as soon as it is added.
#
# Usage: bash scripts/tests/migrate_deluge_to_qbittorrent_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

LABELLED_HASH=1111111111111111111111111111111111111111
UNLABELLED_HASH=2222222222222222222222222222222222222222

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    repo_dir="$sandbox/repo"
    torrent_files_dir="$sandbox/appdata/deluge/state"
    mkdir -p "$repo_dir/scripts" "$repo_dir/stacks" "$sandbox/bin" "$torrent_files_dir"
    cp "$SCRIPTS_DIR/migrate_deluge_to_qbittorrent.sh" "$SCRIPTS_DIR/lib.sh" "$repo_dir/scripts/"
    printf 'DOCKERCONFDIR=%s\n' "$sandbox/appdata" > "$repo_dir/stacks/common.env"
    touch "$torrent_files_dir/$LABELLED_HASH.torrent" "$torrent_files_dir/$UNLABELLED_HASH.torrent"

    export CURL_CALLS_LOG="$sandbox/curl-calls.log" QBITTORRENT_HASHES_FILE="$sandbox/qbittorrent-hashes"
    touch "$CURL_CALLS_LOG" "$QBITTORRENT_HASHES_FILE"
    export DELUGE_LOGIN_RESULT=true QBITTORRENT_LOGIN_ANSWER=Ok.
    export DELUGE_WEB_PASSWORD=deluge-secret QBITTORRENT_USERNAME=admin QBITTORRENT_PASSWORD=qbittorrent-secret
    DELUGE_TORRENTS=$(printf '{"%s": {"name": "Show.S01", "save_path": "/downloads/tv", "label": "tv-sonarr"}, "%s": {"name": "Film.2024", "save_path": "/downloads", "label": ""}}' \
        "$LABELLED_HASH" "$UNLABELLED_HASH")
    export DELUGE_TORRENTS

    cat > "$sandbox/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_CALLS_LOG"
case "$*" in
    *":8112/json")
        case "$(cat)" in
            *auth.login*) printf '{"result": %s, "error": null, "id": 1}' "$DELUGE_LOGIN_RESULT" ;;
            *core.get_torrents_status*) printf '{"result": %s, "error": null, "id": 1}' "$DELUGE_TORRENTS" ;;
        esac
        ;;
    *"/api/v2/auth/login") printf '%s' "$QBITTORRENT_LOGIN_ANSWER" ;;
    *"/api/v2/torrents/info") jq -Rn '[inputs | {hash: .}]' "$QBITTORRENT_HASHES_FILE" ;;
    *"/api/v2/torrents/categories") printf '{}' ;;
    *"/api/v2/torrents/add")
        printf '%s\n' "$*" | sed -E 's/.*\/([0-9a-f]{40})\.torrent.*/\1/' >> "$QBITTORRENT_HASHES_FILE"
        printf 'Ok.'
        ;;
esac
STUB
    # A torrent qBittorrent never lists would otherwise make the script wait for real.
    printf '#!/usr/bin/env bash\n' > "$sandbox/bin/sleep"
    chmod +x "$sandbox/bin/curl" "$sandbox/bin/sleep"
    export PATH="$sandbox/bin:$PATH"
}

in_sandbox() {
    create_sandbox
    "$@"
}

fail_with_output() {
    echo "      $1"
    sed 's/^/      migrate_deluge_to_qbittorrent.sh | /' "$sandbox/output"
    return 1
}

# $@ = what this run changes in its environment, as `env` arguments
run_migration() {
    env "$@" bash "$repo_dir/scripts/migrate_deluge_to_qbittorrent.sh" > "$sandbox/output" 2>&1
}

# Prints the curl call that added the torrent with hash $1, or nothing.
add_call() {
    grep '/api/v2/torrents/add$' "$CURL_CALLS_LOG" | grep "$1.torrent" || true
}

# Number of calls that changed something in qBittorrent.
write_call_count() {
    grep -cE '/api/v2/torrents/(add|createCategory|recheck)$' "$CURL_CALLS_LOG" || true
}

test_adds_each_torrent_with_its_save_path() {
    run_migration || fail_with_output "expected exit 0"
    [[ "$(add_call "$LABELLED_HASH")" == *"savepath=/downloads/tv "* ]] || fail_with_output "expected Show.S01 in /downloads/tv"
    [[ "$(add_call "$UNLABELLED_HASH")" == *"savepath=/downloads "* ]] || fail_with_output "expected Film.2024 in /downloads"
}

test_gives_a_torrent_its_label_as_category() {
    run_migration || fail_with_output "expected exit 0"
    grep -q 'category=tv-sonarr .*/api/v2/torrents/createCategory$' "$CURL_CALLS_LOG" || fail_with_output "expected the category to be created"
    [[ "$(add_call "$LABELLED_HASH")" == *"category=tv-sonarr "* ]] || fail_with_output "expected Show.S01 in category tv-sonarr"
}

test_adds_torrents_stopped() {
    run_migration || fail_with_output "expected exit 0"
    [[ "$(add_call "$LABELLED_HASH")" == *"stopped=true"*"paused=true"* ]] || fail_with_output "expected the torrent to be added stopped"
}

test_rechecks_the_torrents_it_added() {
    run_migration || fail_with_output "expected exit 0"
    grep -q "hashes=$LABELLED_HASH|$UNLABELLED_HASH .*/api/v2/torrents/recheck$" "$CURL_CALLS_LOG" || fail_with_output "expected a recheck of both torrents"
}

test_skips_a_torrent_qbittorrent_already_has() {
    printf '%s\n' "$LABELLED_HASH" > "$QBITTORRENT_HASHES_FILE"
    run_migration || fail_with_output "expected exit 0"
    [ -z "$(add_call "$LABELLED_HASH")" ] || fail_with_output "expected Show.S01 not to be added again"
    [ -n "$(add_call "$UNLABELLED_HASH")" ] || fail_with_output "expected Film.2024 to be added"
}

test_changes_nothing_in_a_dry_run() {
    run_migration DRY_RUN=1 || fail_with_output "expected exit 0"
    [ "$(write_call_count)" -eq 0 ] || fail_with_output "expected no change in qBittorrent"
    grep -q 'would add Show.S01' "$sandbox/output" || fail_with_output "expected the run to say what it would add"
}

# $@ = the environment assignment that makes a login fail
check_refused_login_stops_the_run() {
    create_sandbox
    local exit_status=0
    run_migration "$@" || exit_status=$?
    [ "$exit_status" -ne 0 ] || fail_with_output "expected a non-zero exit"
    [ "$(write_call_count)" -eq 0 ] || fail_with_output "expected no change in qBittorrent"
}

test_reports_a_torrent_without_its_torrent_file() {
    rm "$torrent_files_dir/$LABELLED_HASH.torrent"
    local exit_status=0
    run_migration || exit_status=$?
    [ "$exit_status" -ne 0 ] || fail_with_output "expected a non-zero exit"
    grep -q "ERROR: Show.S01: no $torrent_files_dir/$LABELLED_HASH.torrent" "$sandbox/output" || fail_with_output "expected the missing file to be named"
    [ -n "$(add_call "$UNLABELLED_HASH")" ] || fail_with_output "expected the other torrent to be added anyway"
}

test_fails_when_qbittorrent_never_lists_an_added_torrent() {
    # The stub then records nothing, as if qBittorrent had dropped the torrents it accepted.
    export QBITTORRENT_HASHES_FILE=/dev/null
    local exit_status=0
    run_migration || exit_status=$?
    [ "$exit_status" -ne 0 ] || fail_with_output "expected a non-zero exit"
    grep -q 'does not list them' "$sandbox/output" || fail_with_output "expected the unlisted torrents to be reported"
}

# $1 = the variable left unset
check_missing_variable() {
    create_sandbox
    local exit_status=0
    run_migration -u "$1" || exit_status=$?
    [ "$exit_status" -ne 0 ] || fail_with_output "expected a non-zero exit"
    [ ! -s "$CURL_CALLS_LOG" ] || fail_with_output "expected no call at all"
}

run_test "it adds each torrent with the save path it has in Deluge" in_sandbox test_adds_each_torrent_with_its_save_path
run_test "it gives a torrent its Deluge label as category" in_sandbox test_gives_a_torrent_its_label_as_category
run_test "it adds torrents stopped" in_sandbox test_adds_torrents_stopped
run_test "it rechecks the torrents it added" in_sandbox test_rechecks_the_torrents_it_added
run_test "it skips a torrent qBittorrent already has" in_sandbox test_skips_a_torrent_qbittorrent_already_has
run_test "it changes nothing in qBittorrent with DRY_RUN=1" in_sandbox test_changes_nothing_in_a_dry_run
run_test "it stops before changing anything when Deluge refuses the login" check_refused_login_stops_the_run DELUGE_LOGIN_RESULT=false
run_test "it stops before changing anything when qBittorrent refuses the login" check_refused_login_stops_the_run QBITTORRENT_LOGIN_ANSWER=Fails.
run_test "it fails and names a torrent whose .torrent file is missing" in_sandbox test_reports_a_torrent_without_its_torrent_file
run_test "it fails when qBittorrent never lists a torrent it accepted" in_sandbox test_fails_when_qbittorrent_never_lists_an_added_torrent
run_test "it refuses to run without DELUGE_WEB_PASSWORD" check_missing_variable DELUGE_WEB_PASSWORD
run_test "it refuses to run without QBITTORRENT_USERNAME" check_missing_variable QBITTORRENT_USERNAME
run_test "it refuses to run without QBITTORRENT_PASSWORD" check_missing_variable QBITTORRENT_PASSWORD

finish_tests
