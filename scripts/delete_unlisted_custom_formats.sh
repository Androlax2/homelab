#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Deletes from Sonarr and Radarr the custom formats Configarr wants gone, one request each,
# waiting as long as each one takes. Run by hand, as root on the NAS.
#
# Configarr gives up on a request after 10 seconds, and here Sonarr takes about that long to
# delete one custom format: with many to delete, its own run never gets through them. Once
# they are gone, `docker start -a configarr` carries on from there.
#
# The list comes from Configarr itself, run in dry-run mode on config/configarr/config.yml.
#
# Usage: scripts/delete_unlisted_custom_formats.sh
#        DRY_RUN=1 scripts/delete_unlisted_custom_formats.sh    only lists what it would delete
# ============================================================

# DSM Task Scheduler's PATH does not include /usr/local/bin, where docker lives.
PATH="$PATH:/usr/local/bin"

REPO_DIR="${REPO_DIR:-/volume1/docker/homelab}"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

# Sonarr and Radarr use the host network: from the NAS they answer on localhost.
SONARR_URL=http://localhost:8989
RADARR_URL=http://localhost:7878
DELETE_TIMEOUT_SECONDS=300
DRY_RUN="${DRY_RUN:-0}"

media_env="$REPO_DIR/stacks/media/.env"
sonarr_key=$(required_env_value "$media_env" SONARR_API_KEY media)
radarr_key=$(required_env_value "$media_env" RADARR_API_KEY media)

configarr_image=$(awk '$1 == "image:" && $2 ~ /\/configarr:/ { print $2; exit }' "$REPO_DIR/stacks/media/compose.yml")
if [ -z "$configarr_image" ]; then
    log "ERROR: no configarr image in $REPO_DIR/stacks/media/compose.yml"
    exit 1
fi

log "Asking Configarr what it would delete (dry run)..."
# The keys are handed over through the environment: as arguments they would show in `ps`.
if ! configarr_plan=$(SONARR_API_KEY="$sonarr_key" RADARR_API_KEY="$radarr_key" docker run --rm --network host \
    -e SONARR_API_KEY -e RADARR_API_KEY -e DRY_RUN=true -e STOP_ON_ERROR=true \
    -v "$REPO_DIR/config/configarr:/app/config:ro" "$configarr_image" 2>&1); then
    log "ERROR: the Configarr dry run failed:"
    printf '%s\n' "$configarr_plan" | tail -n 20
    exit 1
fi

# Prints the names of the custom formats the dry run would delete from <app>, one per line:
# the "  - <name> (removed)" lines of the "CustomFormat (...)" block in that app's diff report.
# $1 = SONARR | RADARR, as in Configarr's "### Processing <app> ..." headings
unlisted_custom_formats() {
    printf '%s\n' "$configarr_plan" | awk -v app="$1" '
        /### Processing [A-Z]+ / { in_app = index($0, "### Processing " app " ") > 0; block = "" }
        /^[A-Za-z]+ \(.*\)$/ { block = $1 }
        in_app && block == "CustomFormat" && /^  - .* \(removed\)$/ {
            sub(/^  - /, ""); sub(/ \(removed\)$/, ""); print
        }'
}

failed_deletions=0

# $1 = SONARR | RADARR, $2 = the app's URL, $3 = its API key
delete_unlisted() {
    local app="$1" url="$2" api_key="$3"
    local names existing total position=0 name format_id seconds
    names=$(unlisted_custom_formats "$app")
    if [ -z "$names" ]; then
        log "$app: nothing to delete."
        return 0
    fi
    total=$(printf '%s\n' "$names" | wc -l)
    if ! existing=$(curl -sf -H "X-Api-Key: $api_key" "$url/api/v3/customformat"); then
        log "ERROR: $app did not answer ($url)"
        failed_deletions=$((failed_deletions + total))
        return 0
    fi

    while IFS= read -r name; do
        position=$((position + 1))
        format_id=$(printf '%s\n' "$existing" | jq --arg name "$name" '.[] | select(.name == $name) | .id')
        if [ -z "$format_id" ]; then
            log "ERROR: $app: no custom format named \"$name\" ($position/$total)"
            failed_deletions=$((failed_deletions + 1))
        elif [ "$DRY_RUN" = "1" ]; then
            log "[DRY-RUN] $app: would delete $name ($position/$total)"
        elif seconds=$(curl -sf -o /dev/null -w '%{time_total}' --max-time "$DELETE_TIMEOUT_SECONDS" \
            -X DELETE -H "X-Api-Key: $api_key" "$url/api/v3/customformat/$format_id"); then
            log "$app: deleted $name ($position/$total, ${seconds}s)"
        else
            log "ERROR: $app: could not delete $name ($position/$total)"
            failed_deletions=$((failed_deletions + 1))
        fi
    done <<<"$names"
}

delete_unlisted SONARR "$SONARR_URL" "$sonarr_key"
delete_unlisted RADARR "$RADARR_URL" "$radarr_key"

if [ "$failed_deletions" -gt 0 ]; then
    log "Done, with $failed_deletions custom formats not deleted: see the errors above."
    exit 1
fi
if [ "$DRY_RUN" = "1" ]; then
    log "Done (DRY-RUN: nothing was deleted)."
else
    log "Done. Now run: docker start -a configarr"
fi
