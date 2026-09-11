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
# Needs .github-token (see github.sh) and the API keys in stacks/media/.env.
#
# Usage: scripts/sync_arr_settings.sh              the scheduled run
#        scripts/sync_arr_settings.sh --take-apps  keep the apps' settings: send them to the repo
#        scripts/sync_arr_settings.sh --take-repo  keep the repo's settings: apply them to the apps
# ============================================================

# DSM Task Scheduler's PATH does not include /usr/local/bin, where docker lives.
PATH="$PATH:/usr/local/bin"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNCED_FILE="$REPO_DIR/.arr-settings-synced"
SYNC_BRANCH=arr-settings-sync
# Sonarr and Radarr use the host network: from the NAS they answer on localhost.
SONARR_URL=http://localhost:8989
RADARR_URL=http://localhost:7878
USAGE="Usage: scripts/sync_arr_settings.sh [--take-apps | --take-repo]"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"
# shellcheck source=scripts/github.sh
source "$REPO_DIR/scripts/github.sh"

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
REPO_SLUG=$(github_repo_slug)

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

send_apps_to_repo() {
    local clone="$work_dir/clone" service
    clone_main "$clone"
    cp "$apps_settings/configs/instances.yml" "$clone/config/recyclarr/configs/instances.yml"
    for service in sonarr radarr; do
        mkdir -p "$clone/config/recyclarr/custom-formats/$service"
        find "$clone/config/recyclarr/custom-formats/$service" -name '*.json' -delete
        find "$apps_settings/custom-formats/$service" -name '*.json' -exec cp {} "$clone/config/recyclarr/custom-formats/$service/" \;
    done
    send_as_pull_request "$clone" "$SYNC_BRANCH" "Sonarr/Radarr settings changed in the apps" \
        "$(printf 'Sent by scripts/sync_arr_settings.sh on the NAS: these settings were changed in Sonarr/Radarr.\n\n```\n%s\n```' \
            "$(changed_files "$main_settings" "$apps_settings")")"
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
