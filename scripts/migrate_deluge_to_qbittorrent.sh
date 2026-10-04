#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Copies Deluge's torrents into qBittorrent. Run by hand, as root on the NAS, while both
# containers run; it goes away with the deluge container.
#
# Each torrent Deluge holds is added to qBittorrent from Deluge's own copy of its .torrent
# file, with the same save path and its Deluge label as category, stopped. The added
# torrents are then rechecked against the files already on disk.
#
# Deluge is only read, and nothing is started in qBittorrent: once every torrent shows
# 100% there, pause them in Deluge and start them in qBittorrent.
#
# A torrent qBittorrent already has is skipped, so the script can be run again.
#
# Usage:
#   DELUGE_WEB_PASSWORD=... QBITTORRENT_USERNAME=... QBITTORRENT_PASSWORD=... \
#       scripts/migrate_deluge_to_qbittorrent.sh
#   DRY_RUN=1 ... scripts/migrate_deluge_to_qbittorrent.sh    only says what it would add
# ============================================================

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

# Both web UIs are published on the NAS itself.
DELUGE_URL=http://localhost:8112
QBITTORRENT_URL=http://localhost:8080
# qBittorrent answers an add before the torrent shows up in its list.
REGISTRATION_WAIT_SECONDS=30
DRY_RUN="${DRY_RUN:-0}"

DELUGE_WEB_PASSWORD="${DELUGE_WEB_PASSWORD:?DELUGE_WEB_PASSWORD is not set (the password of the Deluge web UI)}"
QBITTORRENT_USERNAME="${QBITTORRENT_USERNAME:?QBITTORRENT_USERNAME is not set}"
QBITTORRENT_PASSWORD="${QBITTORRENT_PASSWORD:?QBITTORRENT_PASSWORD is not set}"

config_root=$(required_env_value "$REPO_DIR/stacks/common.env" DOCKERCONFDIR common)
torrent_files_dir="${config_root%/}/deluge/state"

umask 077
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
deluge_cookies="$work_dir/deluge-cookies"
qbittorrent_cookies="$work_dir/qbittorrent-cookies"

# Calls a method of Deluge's web API and prints its result as JSON.
# $1 = method, $2 = its parameters, as a JSON array
deluge_rpc() {
    local response
    # The request goes through stdin: it may hold the password, which a command line would show in `ps`.
    if ! response=$(jq -cn --arg method "$1" --argjson params "$2" '{method: $method, params: $params, id: 1}' \
        | curl -sf -b "$deluge_cookies" -c "$deluge_cookies" -H 'Content-Type: application/json' \
            --data @- "$DELUGE_URL/json"); then
        log "ERROR: Deluge did not answer $1 ($DELUGE_URL)" >&2
        return 1
    fi
    if [ "$(jq -c '.error' <<<"$response")" != null ]; then
        log "ERROR: Deluge refused $1: $(jq -c '.error' <<<"$response")" >&2
        return 1
    fi
    jq -c '.result' <<<"$response"
}

# Calls qBittorrent's web API with the session of qbittorrent_login and prints the answer.
# $1 = API path, $2... = extra curl arguments
qbittorrent_api() {
    local api_path="$1"
    shift
    if ! curl -sf -b "$qbittorrent_cookies" "$@" "$QBITTORRENT_URL/api/v2/$api_path"; then
        log "ERROR: qBittorrent refused $api_path ($QBITTORRENT_URL)" >&2
        return 1
    fi
}

qbittorrent_login() {
    local answer
    printf '%s' "$QBITTORRENT_PASSWORD" > "$work_dir/qbittorrent-password"
    # The Referer is required: qBittorrent rejects a login whose Referer is not its own address.
    answer=$(curl -sf -c "$qbittorrent_cookies" -H "Referer: $QBITTORRENT_URL" \
        --data-urlencode "username=$QBITTORRENT_USERNAME" \
        --data-urlencode "password@$work_dir/qbittorrent-password" \
        "$QBITTORRENT_URL/api/v2/auth/login") || answer=""
    [ "$answer" = "Ok." ]
}

# Prints the hashes of the torrents qBittorrent holds, one per line.
qbittorrent_hashes() {
    local torrents
    torrents=$(qbittorrent_api torrents/info) || return 1
    jq -r '.[].hash' <<<"$torrents"
}

# Waits until qBittorrent lists every given hash; prints the ones still absent after
# REGISTRATION_WAIT_SECONDS and fails.
# $@ = hashes
wait_until_registered() {
    local absent_hashes waited_seconds=0
    while true; do
        absent_hashes=$(comm -23 <(printf '%s\n' "$@" | sort) <(qbittorrent_hashes | sort))
        [ -n "$absent_hashes" ] || return 0
        if [ "$waited_seconds" -ge "$REGISTRATION_WAIT_SECONDS" ]; then
            printf '%s\n' "$absent_hashes"
            return 1
        fi
        sleep 1
        waited_seconds=$((waited_seconds + 1))
    done
}

if [ "$(deluge_rpc auth.login "$(jq -cn --arg password "$DELUGE_WEB_PASSWORD" '[$password]')")" != true ]; then
    log "ERROR: Deluge refused the login. Check DELUGE_WEB_PASSWORD."
    exit 1
fi
if ! qbittorrent_login; then
    log "ERROR: qBittorrent refused the login. Check QBITTORRENT_USERNAME and QBITTORRENT_PASSWORD."
    exit 1
fi

# "label" only exists while Deluge's Label plugin is on.
deluge_torrents=$(deluge_rpc core.get_torrents_status '[{}, ["name", "save_path", "label"]]')
log "Deluge holds $(jq 'length' <<<"$deluge_torrents") torrents."

present_hashes=$(qbittorrent_hashes)
known_categories=$(qbittorrent_api torrents/categories | jq -r 'keys[]')

added_hashes=()
already_present=0
missing_torrent_files=0

while IFS= read -r torrent_hash; do
    torrent_name=$(jq -r --arg hash "$torrent_hash" '.[$hash].name' <<<"$deluge_torrents")
    save_path=$(jq -r --arg hash "$torrent_hash" '.[$hash].save_path' <<<"$deluge_torrents")
    label=$(jq -r --arg hash "$torrent_hash" '.[$hash].label // ""' <<<"$deluge_torrents")
    torrent_file="$torrent_files_dir/$torrent_hash.torrent"

    if grep -qxF "$torrent_hash" <<<"$present_hashes"; then
        already_present=$((already_present + 1))
        continue
    fi
    if [ ! -f "$torrent_file" ]; then
        log "ERROR: $torrent_name: no $torrent_file, add this torrent to qBittorrent by hand"
        missing_torrent_files=$((missing_torrent_files + 1))
        continue
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY-RUN] would add $torrent_name (save path $save_path, category ${label:-none})"
        continue
    fi

    if [ -n "$label" ] && ! grep -qxF "$label" <<<"$known_categories"; then
        qbittorrent_api torrents/createCategory --data-urlencode "category=$label" > /dev/null
        known_categories+=$'\n'"$label"
    fi

    # autoTMM=false: with automatic management on, the category would decide the save path.
    # stopped and paused are the same option, renamed in qBittorrent 5.
    add_answer=$(qbittorrent_api torrents/add \
        -F "torrents=@$torrent_file" \
        --form-string "savepath=$save_path" \
        --form-string "category=$label" \
        --form-string autoTMM=false \
        --form-string contentLayout=Original \
        --form-string stopped=true \
        --form-string paused=true)
    if [ "$add_answer" = "Fails." ]; then
        log "ERROR: qBittorrent refused $torrent_name ($torrent_file)"
        exit 1
    fi
    log "Added $torrent_name (save path $save_path, category ${label:-none})"
    added_hashes+=("$torrent_hash")
done < <(jq -r 'keys[]' <<<"$deluge_torrents")

if [ ${#added_hashes[@]} -gt 0 ]; then
    if ! absent_hashes=$(wait_until_registered "${added_hashes[@]}"); then
        log "ERROR: qBittorrent accepted these torrents but does not list them: $(tr '\n' ' ' <<<"$absent_hashes")"
        exit 1
    fi
    qbittorrent_api torrents/recheck --data-urlencode "hashes=$(IFS='|'; printf '%s' "${added_hashes[*]}")" > /dev/null
    log "Recheck started on the added torrents: wait for 100% before starting them in qBittorrent."
fi

log "Done. Added: ${#added_hashes[@]} | Already in qBittorrent: $already_present | Without .torrent file: $missing_torrent_files"
if [ "$DRY_RUN" = "1" ]; then
    log "(DRY-RUN: nothing was added)"
fi
[ "$missing_torrent_files" -eq 0 ]
