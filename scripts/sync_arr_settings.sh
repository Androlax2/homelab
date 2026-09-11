#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Two-way sync between the Recyclarr config in this repo (config/recyclarr/) and the
# Sonarr/Radarr settings. Run as root on the NAS, every 15 minutes.
#
# Each run exports the apps' settings and compares them with the repo (this deployed
# checkout and origin/main) and with the last state both sides agreed on (the commit
# recorded in .arr-settings-synced):
#   - only the apps changed  -> the export goes to GitHub as a pull request (branch
#                               arr-settings-sync), merged once CI passes
#   - only the repo changed  -> once deployed, Recyclarr applies it to the apps
#   - both changed           -> nothing is touched, and every run fails until you pick
#                               a side: --take-apps or --take-repo
#
# Needs .github-token (a fine-grained token for this repository: Contents and Pull
# requests, read and write) and the API keys in stacks/media/.env.
#
# Usage: scripts/sync_arr_settings.sh              the scheduled run
#        scripts/sync_arr_settings.sh --take-apps  keep the apps' settings: send them to the repo
#        scripts/sync_arr_settings.sh --take-repo  keep the repo's settings: apply them to the apps
# ============================================================

# DSM Task Scheduler's PATH does not include /usr/local/bin, where docker lives.
PATH="$PATH:/usr/local/bin"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNCED_FILE="$REPO_DIR/.arr-settings-synced"
TOKEN_FILE="$REPO_DIR/.github-token"
SYNC_BRANCH=arr-settings-sync
# Sonarr and Radarr use the host network: from the NAS they answer on localhost.
SONARR_URL=http://localhost:8989
RADARR_URL=http://localhost:7878
USAGE="Usage: scripts/sync_arr_settings.sh [--take-apps | --take-repo]"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

case "${1:-}" in
    "") mode=scheduled ;;
    --take-apps) mode=take-apps ;;
    --take-repo) mode=take-repo ;;
    *)
        echo "$USAGE" >&2
        exit 1
        ;;
esac

cd "$REPO_DIR"
REPO_SLUG="${GITHUB_REPOSITORY:-$(git remote get-url origin | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')}"
if [[ ! "$REPO_SLUG" =~ ^[^/]+/[^/]+$ ]]; then
    log "ERROR: can't tell the GitHub repository from the origin remote ($REPO_SLUG)."
    exit 1
fi

# Shares the deploy's lock: the checkout must not move while it is compared.
exec 9>"$REPO_DIR/.deploy.lock"
if ! flock -n 9; then
    log "A deploy is running, skipping."
    [ "$mode" = scheduled ] || exit 1
    exit 0
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# $1 = git revision, $2 = directory: fills <directory>/config/recyclarr with that revision's files.
tree_at() {
    mkdir -p "$2"
    git archive "$1" config/recyclarr | tar -x -C "$2"
    find "$2" -name .gitkeep -delete
}

# $1 = directory: fills it with the apps' current settings, laid out like config/recyclarr.
export_apps() {
    local media_env="$REPO_DIR/stacks/media/.env" sonarr_key radarr_key
    sonarr_key=$(env_value "$media_env" SONARR_API_KEY)
    radarr_key=$(env_value "$media_env" RADARR_API_KEY)
    if [ -z "$sonarr_key" ] || [ -z "$radarr_key" ]; then
        log "ERROR: SONARR_API_KEY and RADARR_API_KEY must be set in stacks/media/.env."
        exit 1
    fi
    SONARR_API_KEY="$sonarr_key" RADARR_API_KEY="$radarr_key" SONARR_URL="$SONARR_URL" RADARR_URL="$RADARR_URL" \
        "$REPO_DIR/scripts/export_arr_settings.sh" --to "$1" --no-preview > /dev/null
}

# Succeeds when two directories hold the same settings. settings.yml is the repo's own, not the apps'.
same_settings() {
    diff -rq "$1/configs" "$2/configs" > /dev/null 2>&1 && diff -rq "$1/custom-formats" "$2/custom-formats" > /dev/null 2>&1
}

# $1 = before, $2 = after: the files that differ, for logs and pull requests.
changed_files() {
    { diff -rq "$1/configs" "$2/configs"; diff -rq "$1/custom-formats" "$2/custom-formats"; } 2>&1 \
        | sed "s#$1/##g; s#$2/##g" || true
}

# $1 = the commit whose settings both sides now agree on
record_synced() {
    printf '%s\n' "$1" > "$SYNCED_FILE"
}

apply_repo_to_apps() {
    log "Applying the repo's settings to Sonarr and Radarr (recyclarr sync)"
    docker exec recyclarr recyclarr sync
    export_apps "$work_dir/after-sync"
    if ! same_settings "$work_dir/after-sync" "$deployed_settings"; then
        log "ERROR: after the sync, the apps still differ from the repo:"
        changed_files "$deployed_settings" "$work_dir/after-sync"
        log "Recyclarr can't apply everything (a quality profile deleted from the repo, for instance):"
        log "fix it in the app, or keep the apps' version with --take-apps."
        exit 1
    fi
    record_synced "$deployed_commit"
    log "Sonarr and Radarr now match the repo."
}

# $1 = method, $2 = API path, $3 = JSON body (optional). Leaves the response in response.json and
# prints the HTTP status. The token stays in a root-only header file, never on a command line.
github_api() {
    local data_args=()
    if [ -n "${3:-}" ]; then
        data_args=(--data "$3")
    fi
    curl -sS -o "$work_dir/response.json" -w '%{http_code}' -X "$1" -H @"$work_dir/github-headers" \
        "${data_args[@]}" "https://api.github.com$2"
}

# $1 = what failed
github_error() {
    log "ERROR: could not $1: $(jq -r '.errors[0].message // .message // "no details"' "$work_dir/response.json" 2>/dev/null)"
    exit 1
}

# $1 = the changed files, for the pull request's description
open_or_update_pull_request() {
    local changes="$1" status number node_id request
    status=$(github_api GET "/repos/$REPO_SLUG/pulls?head=${REPO_SLUG%%/*}:$SYNC_BRANCH&state=open")
    [ "$status" = 200 ] || github_error "list the pull requests"
    number=$(jq -r '.[0].number // empty' "$work_dir/response.json")
    if [ -n "$number" ]; then
        log "Pull request #$number holds the apps' latest settings."
        return 0
    fi

    request=$(jq -nc --arg head "$SYNC_BRANCH" --arg changes "$changes" '{
        title: "Sonarr/Radarr settings changed in the apps",
        head: $head,
        base: "main",
        body: ("Sent by scripts/sync_arr_settings.sh on the NAS: these settings were changed in Sonarr/Radarr.\n\n```\n" + $changes + "\n```")
    }')
    status=$(github_api POST "/repos/$REPO_SLUG/pulls" "$request")
    [ "$status" = 201 ] || github_error "open the pull request"
    number=$(jq -r .number "$work_dir/response.json")
    node_id=$(jq -r .node_id "$work_dir/response.json")

    status=$(github_api PUT "/repos/$REPO_SLUG/pulls/$number/merge" '{"merge_method": "squash"}')
    if [ "$status" = 200 ]; then
        log "Pull request #$number opened and merged."
        return 0
    fi
    # Required checks still running: GitHub merges it by itself once they pass.
    request=$(jq -nc --arg id "$node_id" '{
        query: "mutation($id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: SQUASH}) { clientMutationId } }",
        variables: {id: $id}
    }')
    status=$(github_api POST /graphql "$request")
    if [ "$status" != 200 ] || jq -e '.errors' "$work_dir/response.json" > /dev/null; then
        github_error "turn on auto-merge for pull request #$number (is \"Allow auto-merge\" on in the repository settings?)"
    fi
    log "Pull request #$number opened: it merges once CI passes."
}

send_apps_to_repo() {
    local clone="$work_dir/clone" owner="${REPO_SLUG%%/*}" service
    if [ ! -s "$TOKEN_FILE" ]; then
        log "ERROR: $TOKEN_FILE is missing: the NAS can't send the apps' settings to GitHub without it."
        exit 1
    fi
    (
        umask 077
        printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' \
            "$(tr -d '[:space:]' < "$TOKEN_FILE")" > "$work_dir/github-headers"
        printf '#!/usr/bin/env bash\ncase "$1" in Username*) echo %q ;; *) tr -d "[:space:]" < %q ;; esac\n' \
            "$owner" "$TOKEN_FILE" > "$work_dir/askpass"
    )
    chmod 700 "$work_dir/askpass"
    export GIT_ASKPASS="$work_dir/askpass" GIT_TERMINAL_PROMPT=0

    git clone --quiet --depth 1 --branch main "$(git remote get-url origin)" "$clone"
    git -C "$clone" checkout --quiet -B "$SYNC_BRANCH"
    cp "$apps_settings/configs/instances.yml" "$clone/config/recyclarr/configs/instances.yml"
    for service in sonarr radarr; do
        mkdir -p "$clone/config/recyclarr/custom-formats/$service"
        find "$clone/config/recyclarr/custom-formats/$service" -name '*.json' -delete
        find "$apps_settings/custom-formats/$service" -name '*.json' -exec cp {} "$clone/config/recyclarr/custom-formats/$service/" \;
    done
    git -C "$clone" add -A config/recyclarr
    if git -C "$clone" diff --cached --quiet; then
        log "main already has the apps' settings: nothing to send."
        return 0
    fi
    git -C "$clone" -c user.name="homelab NAS" -c user.email="nas@homelab.invalid" \
        commit --quiet -m "Sonarr/Radarr settings changed in the apps"

    # Don't rewrite the pull request's branch when it already holds exactly these settings.
    if git -C "$clone" fetch --quiet --depth 1 origin "$SYNC_BRANCH" 2>/dev/null \
        && [ "$(git -C "$clone" rev-parse 'FETCH_HEAD^{tree}')" = "$(git -C "$clone" rev-parse 'HEAD^{tree}')" ]; then
        log "Branch $SYNC_BRANCH already holds the apps' settings."
    else
        git -C "$clone" push --quiet --force origin "$SYNC_BRANCH"
    fi
    open_or_update_pull_request "$(changed_files "$main_settings" "$apps_settings")"
}

git fetch --quiet origin main
deployed_commit=$(git rev-parse HEAD)
main_commit=$(git rev-parse origin/main)
tree_at "$deployed_commit" "$work_dir/deployed"
tree_at "$main_commit" "$work_dir/main"
deployed_settings="$work_dir/deployed/config/recyclarr"
main_settings="$work_dir/main/config/recyclarr"
apps_settings="$work_dir/apps"
export_apps "$apps_settings"

case "$mode" in
    take-apps)
        send_apps_to_repo
        # main's settings are now overruled: until the pull request is merged, only the apps count as changed.
        record_synced "$main_commit"
        exit 0
        ;;
    take-repo)
        if ! same_settings "$deployed_settings" "$main_settings"; then
            log "ERROR: main has settings this NAS hasn't deployed yet: run this again after the next deploy."
            exit 1
        fi
        apply_repo_to_apps
        exit 0
        ;;
esac

if same_settings "$apps_settings" "$deployed_settings"; then
    record_synced "$deployed_commit"
    exit 0
fi
if same_settings "$apps_settings" "$main_settings"; then
    log "main already has the apps' settings; waiting for the deploy."
    exit 0
fi
if [ ! -f "$SYNCED_FILE" ]; then
    log "ERROR: no previous sync to compare with, and the apps differ from the repo:"
    changed_files "$deployed_settings" "$apps_settings"
    log "Pick a side: sudo scripts/sync_arr_settings.sh --take-apps (keep the apps) or --take-repo (keep the repo)."
    exit 1
fi

tree_at "$(cat "$SYNCED_FILE")" "$work_dir/synced"
synced_settings="$work_dir/synced/config/recyclarr"
apps_changed=false
same_settings "$apps_settings" "$synced_settings" || apps_changed=true
repo_changed=false
same_settings "$main_settings" "$synced_settings" || repo_changed=true

if [ "$apps_changed" = true ] && [ "$repo_changed" = true ]; then
    log "ERROR: conflict: the settings changed both in the apps and in the repo since the last sync."
    log "Changed in the apps:"
    changed_files "$synced_settings" "$apps_settings"
    log "Changed in the repo:"
    changed_files "$synced_settings" "$main_settings"
    log "Nothing was touched. Pick a side: sudo scripts/sync_arr_settings.sh --take-apps or --take-repo."
    exit 1
elif [ "$apps_changed" = true ]; then
    send_apps_to_repo
elif ! same_settings "$deployed_settings" "$main_settings"; then
    log "The repo's settings changed; they'll be applied after the next deploy."
else
    apply_repo_to_apps
fi
