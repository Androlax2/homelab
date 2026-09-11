#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/sync_arr_settings.sh in a throwaway setup: a bare "GitHub" remote, the NAS
# checkout, fake apps (a folder that the stubbed export reads and that the stubbed
# `docker exec recyclarr recyclarr sync` overwrites with the repo's settings) and a stubbed
# GitHub API (`curl`).
#
# Usage: bash scripts/tests/sync_arr_settings_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

# Keep the caller's git config (signing, hooks, default branch) out of the sandbox.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=sync-test GIT_AUTHOR_EMAIL=sync-test@example.invalid
export GIT_COMMITTER_NAME=sync-test GIT_COMMITTER_EMAIL=sync-test@example.invalid

TOKEN=test-token-value

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'cleanup_sandbox $?' EXIT
    export NAS_DIR="$sandbox/nas" FAKE_APPS_DIR="$sandbox/apps"
    export DOCKER_CALLS_LOG="$sandbox/docker-calls.log" CURL_CALLS_LOG="$sandbox/curl-calls.log"
    export GITHUB_REPOSITORY=owner/homelab STUB_OPEN_PULL_REQUESTS='[]' STUB_MERGE_STATUS=200 STUB_SYNC_BROKEN=0
    touch "$DOCKER_CALLS_LOG" "$CURL_CALLS_LOG" "$sandbox/output"
    mkdir -p "$sandbox/bin"

    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS_LOG"
if [ "$*" = "exec recyclarr recyclarr sync" ] && [ "$STUB_SYNC_BROKEN" != 1 ]; then
    rm -rf "$FAKE_APPS_DIR/configs" "$FAKE_APPS_DIR/custom-formats"
    cp -R "$NAS_DIR/config/recyclarr/configs" "$NAS_DIR/config/recyclarr/custom-formats" "$FAKE_APPS_DIR/"
    find "$FAKE_APPS_DIR" -name .gitkeep -delete
fi
STUB
    cat > "$sandbox/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_CALLS_LOG"
output="" method=GET url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        -X) method="$2"; shift 2 ;;
        -H|-w|--data) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
respond() { printf '%s' "$2" > "$output"; printf '%s' "$1"; }
case "$method $url" in
    "GET https://api.github.com/repos/owner/homelab/pulls?"*) respond 200 "$STUB_OPEN_PULL_REQUESTS" ;;
    "POST https://api.github.com/repos/owner/homelab/pulls") respond 201 '{"number": 7, "node_id": "PR_7"}' ;;
    "PUT https://api.github.com/repos/owner/homelab/pulls/7/merge") respond "$STUB_MERGE_STATUS" '{}' ;;
    "POST https://api.github.com/graphql") respond 200 '{"data": {}}' ;;
    *) respond 404 '{"message": "unexpected call"}' ;;
esac
STUB
    chmod +x "$sandbox/bin/docker" "$sandbox/bin/curl"
    export PATH="$sandbox/bin:$PATH"

    git init --quiet --bare --initial-branch=main "$sandbox/origin.git"
    git init --quiet --initial-branch=main "$sandbox/dev"
    local dev="$sandbox/dev"
    mkdir -p "$dev/scripts" "$dev/config/recyclarr/configs" "$dev/config/recyclarr/custom-formats/sonarr" \
        "$dev/config/recyclarr/custom-formats/radarr"
    cp "$SCRIPTS_DIR/sync_arr_settings.sh" "$SCRIPTS_DIR/lib.sh" "$dev/scripts/"
    # Test double for the real export: copies the fake apps' settings into --to.
    cat > "$dev/scripts/export_arr_settings.sh" <<'EXPORT'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = --to ] && [ "$3" = --no-preview ] || { echo "unexpected arguments: $*" >&2; exit 2; }
[ -n "${SONARR_API_KEY:-}" ] && [ -n "${RADARR_API_KEY:-}" ] || { echo "API keys missing" >&2; exit 3; }
mkdir -p "$2"
rm -rf "$2/configs" "$2/custom-formats"
cp -R "$FAKE_APPS_DIR/configs" "$FAKE_APPS_DIR/custom-formats" "$2/"
EXPORT
    chmod +x "$dev/scripts/export_arr_settings.sh"
    printf 'resource_providers: []\n' > "$dev/config/recyclarr/settings.yml"
    printf 'profile: initial\n' > "$dev/config/recyclarr/configs/instances.yml"
    printf '{"name": "a"}\n' > "$dev/config/recyclarr/custom-formats/sonarr/a.json"
    touch "$dev/config/recyclarr/custom-formats/sonarr/.gitkeep" "$dev/config/recyclarr/custom-formats/radarr/.gitkeep"
    git -C "$dev" add -A
    git -C "$dev" commit --quiet -m "initial"
    git -C "$dev" remote add origin "$sandbox/origin.git"
    git -C "$dev" push --quiet origin main
    git clone --quiet "$sandbox/origin.git" "$NAS_DIR"
    mkdir -p "$NAS_DIR/stacks/media"
    printf 'SONARR_API_KEY=sonarr-key\nRADARR_API_KEY=radarr-key\n' > "$NAS_DIR/stacks/media/.env"
    printf '%s\n' "$TOKEN" > "$NAS_DIR/.github-token"

    mkdir -p "$FAKE_APPS_DIR"
    cp -R "$dev/config/recyclarr/configs" "$dev/config/recyclarr/custom-formats" "$FAKE_APPS_DIR/"
    find "$FAKE_APPS_DIR" -name .gitkeep -delete
}

in_sandbox() {
    create_sandbox
    "$@"
}

cleanup_sandbox() {
    local exit_status="$1"
    if [ "$exit_status" -ne 0 ]; then
        sed 's/^/      sync_arr_settings.sh | /' "$sandbox/output"
    fi
    rm -rf "$sandbox"
}

run_sync() {
    bash "$NAS_DIR/scripts/sync_arr_settings.sh" "$@" < /dev/null >> "$sandbox/output" 2>&1
}

# The first run finds apps and repo equal and records that as the agreed state.
record_first_sync() {
    run_sync
    : > "$DOCKER_CALLS_LOG"
    : > "$CURL_CALLS_LOG"
}

change_apps() {
    printf 'profile: changed in the apps\n' > "$FAKE_APPS_DIR/configs/instances.yml"
}

# $1 = new content of instances.yml on main
push_repo_change() {
    printf '%s\n' "${1:-profile: changed in the repo}" > "$sandbox/dev/config/recyclarr/configs/instances.yml"
    git -C "$sandbox/dev" commit --quiet -am "change settings"
    git -C "$sandbox/dev" push --quiet origin main
}

# What deploy.sh does to the NAS checkout.
deploy_on_nas() {
    git -C "$NAS_DIR" pull --quiet --ff-only
}

synced_commit() {
    cat "$NAS_DIR/.arr-settings-synced" 2>/dev/null || true
}

fail_with() {
    echo "      $1"
    return 1
}

test_first_run_records_the_agreement() {
    run_sync || fail_with "expected success"
    [ "$(synced_commit)" = "$(git -C "$NAS_DIR" rev-parse HEAD)" ] || fail_with "expected the deployed commit to be recorded"
    [ ! -s "$DOCKER_CALLS_LOG" ] && [ ! -s "$CURL_CALLS_LOG" ] || fail_with "nothing should have been touched"
}

test_apps_change_becomes_a_pull_request() {
    record_first_sync
    change_apps
    run_sync || fail_with "expected success"
    [ "$(git -C "$sandbox/origin.git" show arr-settings-sync:config/recyclarr/configs/instances.yml)" = "profile: changed in the apps" ] \
        || fail_with "expected the apps' settings on branch arr-settings-sync"
    grep -q '^-sS .* -X POST .*/repos/owner/homelab/pulls$' "$CURL_CALLS_LOG" || fail_with "expected a pull request"
    grep -q 'X PUT .*/pulls/7/merge' "$CURL_CALLS_LOG" || fail_with "expected the pull request to be merged"
    ! grep -q 'recyclarr sync' "$DOCKER_CALLS_LOG" || fail_with "the apps' change must not be overwritten"
}

test_repo_change_is_applied_once_deployed() {
    record_first_sync
    push_repo_change
    deploy_on_nas
    run_sync || fail_with "expected success"
    grep -qx 'exec recyclarr recyclarr sync' "$DOCKER_CALLS_LOG" || fail_with "expected recyclarr to apply the repo"
    [ "$(cat "$FAKE_APPS_DIR/configs/instances.yml")" = "profile: changed in the repo" ] || fail_with "the apps should now match the repo"
    [ "$(synced_commit)" = "$(git -C "$NAS_DIR" rev-parse HEAD)" ] || fail_with "expected the new agreement to be recorded"
}

test_repo_change_waits_for_the_deploy() {
    record_first_sync
    push_repo_change
    run_sync || fail_with "expected success"
    [ ! -s "$DOCKER_CALLS_LOG" ] || fail_with "recyclarr must wait until the change is deployed"
}

test_deployed_change_already_replaced_on_main_is_not_applied() {
    record_first_sync
    push_repo_change "profile: a mistake"
    deploy_on_nas
    push_repo_change "profile: the fix"
    run_sync || fail_with "expected success"
    [ ! -s "$DOCKER_CALLS_LOG" ] || fail_with "a change main no longer has must not reach the apps"
}

test_conflict_touches_nothing() {
    record_first_sync
    change_apps
    push_repo_change
    deploy_on_nas
    if run_sync; then
        fail_with "expected a failure"
    fi
    grep -q 'conflict' "$sandbox/output" || fail_with "expected the conflict to be reported"
    grep -q -- '--take-apps' "$sandbox/output" || fail_with "expected the way out"
    [ ! -s "$DOCKER_CALLS_LOG" ] || fail_with "the apps must not be touched"
    ! grep -q -- '-X POST' "$CURL_CALLS_LOG" || fail_with "no pull request may be opened"
}

test_merged_apps_change_is_not_sent_twice() {
    record_first_sync
    change_apps
    push_repo_change "profile: changed in the apps"
    run_sync || fail_with "expected success"
    [ ! -s "$CURL_CALLS_LOG" ] || fail_with "main already has these settings: no pull request"
    [ ! -s "$DOCKER_CALLS_LOG" ] || fail_with "nothing to apply"
}

test_open_pull_request_is_updated_not_duplicated() {
    export STUB_OPEN_PULL_REQUESTS='[{"number": 3}]'
    record_first_sync
    change_apps
    run_sync || fail_with "expected success"
    ! grep -q -- '-X POST .*/pulls$' "$CURL_CALLS_LOG" || fail_with "no second pull request"
    [ "$(git -C "$sandbox/origin.git" show arr-settings-sync:config/recyclarr/configs/instances.yml)" = "profile: changed in the apps" ] \
        || fail_with "expected the branch to be updated"
}

test_refused_merge_turns_on_auto_merge() {
    export STUB_MERGE_STATUS=405
    record_first_sync
    change_apps
    run_sync || fail_with "expected success"
    grep -q -- '-X POST .*/graphql' "$CURL_CALLS_LOG" || fail_with "expected auto-merge to be turned on"
}

test_sync_that_leaves_differences_fails() {
    export STUB_SYNC_BROKEN=1
    record_first_sync
    local agreed
    agreed=$(synced_commit)
    push_repo_change
    deploy_on_nas
    if run_sync; then
        fail_with "expected a failure"
    fi
    grep -q 'still differ' "$sandbox/output" || fail_with "expected the remaining difference to be reported"
    [ "$(synced_commit)" = "$agreed" ] || fail_with "no new agreement may be recorded"
}

test_without_history_a_difference_asks_to_pick_a_side() {
    change_apps
    if run_sync; then
        fail_with "expected a failure"
    fi
    grep -q -- '--take-apps' "$sandbox/output" || fail_with "expected the way out"
    [ ! -s "$CURL_CALLS_LOG" ] && [ ! -s "$DOCKER_CALLS_LOG" ] || fail_with "nothing may be touched"
}

test_take_repo_settles_a_conflict() {
    record_first_sync
    change_apps
    push_repo_change
    deploy_on_nas
    run_sync --take-repo || fail_with "expected success"
    [ "$(cat "$FAKE_APPS_DIR/configs/instances.yml")" = "profile: changed in the repo" ] || fail_with "the repo should win"
    [ "$(synced_commit)" = "$(git -C "$NAS_DIR" rev-parse HEAD)" ] || fail_with "expected the agreement to be recorded"
}

test_take_apps_settles_a_conflict() {
    record_first_sync
    change_apps
    push_repo_change
    deploy_on_nas
    run_sync --take-apps || fail_with "expected success"
    [ "$(git -C "$sandbox/origin.git" show arr-settings-sync:config/recyclarr/configs/instances.yml)" = "profile: changed in the apps" ] \
        || fail_with "the apps should win"
    [ ! -s "$DOCKER_CALLS_LOG" ] || fail_with "the apps must not be overwritten"
}

test_take_apps_is_not_a_conflict_while_its_pull_request_waits() {
    export STUB_MERGE_STATUS=405 STUB_OPEN_PULL_REQUESTS='[{"number": 7}]'
    record_first_sync
    change_apps
    push_repo_change
    deploy_on_nas
    run_sync --take-apps || fail_with "expected success"
    run_sync || fail_with "the next scheduled run must not report a conflict"
    ! grep -q 'conflict' "$sandbox/output" || fail_with "no conflict expected"
    [ ! -s "$DOCKER_CALLS_LOG" ] || fail_with "the apps must not be overwritten"
}

test_token_stays_off_the_command_line() {
    record_first_sync
    change_apps
    run_sync || fail_with "expected success"
    [ -s "$CURL_CALLS_LOG" ] || fail_with "expected GitHub calls"
    ! grep -q "$TOKEN" "$CURL_CALLS_LOG" || fail_with "the token reached curl's arguments"
}

test_skips_while_a_deploy_runs() {
    change_apps
    flock "$NAS_DIR/.deploy.lock" bash "$NAS_DIR/scripts/sync_arr_settings.sh" < /dev/null >> "$sandbox/output" 2>&1 \
        || fail_with "a scheduled run must just skip"
    grep -q 'skipping' "$sandbox/output" || fail_with "expected the skip to be logged"
    [ ! -s "$CURL_CALLS_LOG" ] && [ ! -s "$DOCKER_CALLS_LOG" ] || fail_with "nothing may be touched"
}

run_test "the first run records the state the apps and the repo agree on" in_sandbox test_first_run_records_the_agreement
run_test "a change made in the apps becomes a merged pull request" in_sandbox test_apps_change_becomes_a_pull_request
run_test "a change made in the repo is applied to the apps once deployed" in_sandbox test_repo_change_is_applied_once_deployed
run_test "a change in the repo waits for the deploy before being applied" in_sandbox test_repo_change_waits_for_the_deploy
run_test "a deployed change that main has already replaced is not applied" in_sandbox test_deployed_change_already_replaced_on_main_is_not_applied
run_test "a change on both sides is a conflict that touches nothing" in_sandbox test_conflict_touches_nothing
run_test "an apps change already on main is not sent twice" in_sandbox test_merged_apps_change_is_not_sent_twice
run_test "an open pull request is updated, not duplicated" in_sandbox test_open_pull_request_is_updated_not_duplicated
run_test "when GitHub can't merge yet, auto-merge is turned on" in_sandbox test_refused_merge_turns_on_auto_merge
run_test "a sync that leaves the apps different fails and records nothing" in_sandbox test_sync_that_leaves_differences_fails
run_test "without a previous sync, a difference asks you to pick a side" in_sandbox test_without_history_a_difference_asks_to_pick_a_side
run_test "--take-repo settles a conflict in favour of the repo" in_sandbox test_take_repo_settles_a_conflict
run_test "--take-apps settles a conflict in favour of the apps" in_sandbox test_take_apps_settles_a_conflict
run_test "after --take-apps, the next run waits for its pull request instead of reporting a conflict" in_sandbox test_take_apps_is_not_a_conflict_while_its_pull_request_waits
run_test "the GitHub token never appears on a command line" in_sandbox test_token_stays_off_the_command_line
run_test "a scheduled run skips while a deploy runs" in_sandbox test_skips_while_a_deploy_runs

finish_tests
