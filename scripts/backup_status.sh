#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Describes the restic repositories for the dashboard, run hourly as root by DSM Task Scheduler:
#   PC → NAS            PC_RESTIC_NAS_REPOSITORY, a folder on this NAS, and the Synology
#                       snapshots of its share, in PC_RESTIC_NAS_SNAPSHOTS
#   PC → Storage Box    PC_RESTIC_STORAGEBOX_REPOSITORY
#   NAS → Storage Box   the path in RESTIC_REPOSITORY
# Each gets its snapshot count, the time of its last snapshot and the space it takes, without
# its password: restic writes every snapshot as one file in <repository>/snapshots when the
# backup ends, so the files alone give the count and the time, and their sizes the space. The
# Storage Box is listed over SFTP from the restic container, with the backup's SSH config.
#
# Writes STATUS_FILE, which the backup-status container (stacks/infrastructure) serves to
# Glance. A repository that can't be read is written with its error and fails the run, once
# the others are described.
#
# Usage: scripts/backup_status.sh
# ============================================================

# DSM Task Scheduler's PATH does not include /usr/local/bin, where docker lives.
PATH="$PATH:/usr/local/bin"

# Under DOCKERCONFDIR: the folder stacks/infrastructure mounts into backup-status.
STATUS_FILE="backup-status/backups.json"
# RESTIC_REPOSITORY is expected on this SSH host, defined in ${DOCKERCONFDIR}/restic/ssh/config.
STORAGEBOX_REPOSITORY_PREFIX="sftp:storagebox:"
# restic spreads its pack files over data/00 to data/ff.
DATA_FOLDER_COUNT=256
# Tolerated clock difference with the Storage Box before a date sftp shows without a year is
# taken for last year's.
MAX_CLOCK_SKEW_SECONDS=86400

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

config_root=$(required_env_value "$REPO_DIR/stacks/common.env" DOCKERCONFDIR common)
time_zone=$(required_env_value "$REPO_DIR/stacks/common.env" TZ common)
backup_env="$REPO_DIR/stacks/backup/.env"
nas_repository_url=$(required_env_value "$backup_env" RESTIC_REPOSITORY backup)
pc_nas_repository=$(required_env_value "$backup_env" PC_RESTIC_NAS_REPOSITORY backup)
pc_nas_snapshots=$(required_env_value "$backup_env" PC_RESTIC_NAS_SNAPSHOTS backup)
pc_storagebox_repository=$(required_env_value "$backup_env" PC_RESTIC_STORAGEBOX_REPOSITORY backup)

case "$nas_repository_url" in
    "$STORAGEBOX_REPOSITORY_PREFIX"?*) nas_storagebox_repository="${nas_repository_url#"$STORAGEBOX_REPOSITORY_PREFIX"}" ;;
    *)
        log "ERROR: RESTIC_REPOSITORY in $backup_env is not on the Storage Box (${STORAGEBOX_REPOSITORY_PREFIX}<path>): $nas_repository_url"
        exit 1
        ;;
esac

status_file="$config_root/$STATUS_FILE"
if [ ! -d "$(dirname "$status_file")" ]; then
    log "ERROR: $(dirname "$status_file") does not exist: the deploy creates it, run scripts/deploy.sh"
    exit 1
fi

# Prints "<snapshot count> <bytes> <newest snapshot epoch>" for the repository in the local folder
# $1, the epoch left out when it has no snapshot. Prints an error message and fails otherwise.
local_repository_summary() {
    local repository="$1" listing
    if [ ! -d "$repository/snapshots" ]; then
        echo "no restic repository in $repository"
        return 1
    fi
    if ! listing=$(find "$repository" -type f -printf '%s %T@ %P\n'); then
        echo "could not list $repository"
        return 1
    fi
    awk '
        { bytes += $1 }
        $3 ~ /^snapshots\// {
            count++
            if (count == 1 || $2 > newest) newest = $2
        }
        END {
            printf "%d %.0f", count, bytes
            if (count > 0) printf " %d", newest
            printf "\n"
        }' <<<"$listing"
}

# Prints "<count> <newest epoch>" for the Synology share snapshots in the folder $1, the epoch left
# out when there is none. Their names hold the local time and the offset from UTC:
# GMT+02-2026.09.16-00.00.06. Prints an error message and fails otherwise.
share_snapshots_summary() {
    local folder="$1" snapshot name epoch count=0 newest=""
    if [ ! -d "$folder" ]; then
        echo "no such folder: $folder"
        return 1
    fi
    for snapshot in "$folder"/GMT*; do
        [ -d "$snapshot" ] || continue
        name=$(basename "$snapshot")
        if [[ ! "$name" =~ ^GMT([+-][0-9]{2})-([0-9]{4})\.([0-9]{2})\.([0-9]{2})-([0-9]{2})\.([0-9]{2})\.([0-9]{2})$ ]]; then
            echo "unexpected snapshot name in $folder: $name"
            return 1
        fi
        if ! epoch=$(date -d "${BASH_REMATCH[2]}-${BASH_REMATCH[3]}-${BASH_REMATCH[4]} ${BASH_REMATCH[5]}:${BASH_REMATCH[6]}:${BASH_REMATCH[7]} ${BASH_REMATCH[1]}00" +%s); then
            echo "unreadable date in the snapshot name $name"
            return 1
        fi
        count=$((count + 1))
        if [ -z "$newest" ] || [ "$epoch" -gt "$newest" ]; then
            newest="$epoch"
        fi
    done
    echo "$count $newest"
}

# Prints the sftp commands listing every file of the Storage Box repository $1. Folder by folder:
# sftp stats each file a wildcard matches, minutes on a large repository, but not the files of a
# listed folder. A missing folder stops the batch, so a missing repository fails.
storagebox_listing_commands() {
    local repository="$1" folder data_folder_index
    for folder in keys index snapshots; do
        printf 'ls -l %s/%s\n' "$repository" "$folder"
    done
    for ((data_folder_index = 0; data_folder_index < DATA_FOLDER_COUNT; data_folder_index++)); do
        printf 'ls -l %s/data/%02x\n' "$repository" "$data_folder_index"
    done
}

# Prints the epoch of a date as sftp's ls -l shows it: "Sep 16 11:06" for recent files, without a
# year, "Sep 16 2025" for files older than about six months.
# $1 = month, $2 = day, $3 = time or year
sftp_date_epoch() {
    local month="$1" day="$2" time_or_year="$3" current_year epoch
    if [[ "$time_or_year" != *:* ]]; then
        TZ="$time_zone" date -d "$month $day $time_or_year" +%s
        return
    fi
    current_year=$(TZ="$time_zone" date +%Y) || return 1
    epoch=$(TZ="$time_zone" date -d "$month $day $current_year $time_or_year" +%s) || return 1
    # Without a year, the file is from the last six months: a date still to come this year is last year's.
    if [ "$epoch" -gt "$(($(date +%s) + MAX_CLOCK_SKEW_SECONDS))" ]; then
        epoch=$(TZ="$time_zone" date -d "$month $day $((current_year - 1)) $time_or_year" +%s) || return 1
    fi
    echo "$epoch"
}

# Prints "<snapshot count> <bytes> <newest snapshot epoch>" for the Storage Box repository $1, the
# epoch left out when it has no snapshot. Prints an error message and fails otherwise.
storagebox_repository_summary() {
    local repository="$1" listing parsed kind count bytes month day time_or_year epoch newest=""
    if ! listing=$(storagebox_listing_commands "$repository" \
        | "$REPO_DIR/scripts/compose.sh" backup run --rm -T --entrypoint sftp restic -b - storagebox); then
        echo "could not list $repository on the Storage Box over SFTP"
        return 1
    fi
    # sftp ls -l: <mode> <links> <user> <group> <size> <month> <day> <time or year> <path>
    parsed=$(awk '
        $1 ~ /^-/ {
            bytes += $5
            if ($9 ~ /\/snapshots\/[^\/]+$/) print "snapshot", $6, $7, $8
        }
        END { printf "total %.0f\n", bytes }' <<<"$listing")
    count=0
    while read -r kind month day time_or_year; do
        case "$kind" in
            snapshot)
                count=$((count + 1))
                if ! epoch=$(sftp_date_epoch "$month" "$day" "$time_or_year"); then
                    echo "unreadable snapshot date in the SFTP listing of $repository: $month $day $time_or_year"
                    return 1
                fi
                if [ -z "$newest" ] || [ "$epoch" -gt "$newest" ]; then
                    newest="$epoch"
                fi
                ;;
            total) bytes="$month" ;;
        esac
    done <<<"$parsed"
    echo "$count $bytes $newest"
}

repositories_json="[]"
failed=()

# Appends the repository <name> to repositories_json, with what <summary command> prints, or its
# error when it fails, and <extra fields>.
# $1 = name, $2 = extra fields as a JSON object, $3... = summary command
add_repository() {
    local name="$1" extra_fields="$2" output count bytes newest
    shift 2
    if ! output=$("$@"); then
        log "ERROR: $name: $output"
        failed+=("$name")
        repositories_json=$(jq --arg name "$name" --arg error "$output" --argjson extra "$extra_fields" \
            '. + [{name: $name, error: $error} + $extra]' <<<"$repositories_json")
        return
    fi
    read -r count bytes newest <<<"$output"
    log "$name: $count snapshots, $bytes bytes"
    repositories_json=$(jq --arg name "$name" --argjson count "$count" --argjson bytes "$bytes" --arg newest "$newest" \
        --argjson extra "$extra_fields" \
        '. + [{name: $name, snapshots: $count, size: $bytes}
              + (if $newest == "" then {} else {last_snapshot: ($newest | tonumber | todate)} end)
              + $extra]' <<<"$repositories_json")
}

if share_output=$(share_snapshots_summary "$pc_nas_snapshots"); then
    read -r share_count share_newest <<<"$share_output"
    log "NAS snapshots: $share_count"
    nas_snapshots_json=$(jq -n --argjson count "$share_count" --arg newest "$share_newest" \
        '{nas_snapshots: ({count: $count} + (if $newest == "" then {} else {last: ($newest | tonumber | todate)} end))}')
else
    log "ERROR: NAS snapshots: $share_output"
    failed+=("NAS snapshots")
    nas_snapshots_json=$(jq -n --arg error "$share_output" '{nas_snapshots: {error: $error}}')
fi

add_repository "PC → NAS" "$nas_snapshots_json" local_repository_summary "$pc_nas_repository"
add_repository "PC → Storage Box" "{}" storagebox_repository_summary "$pc_storagebox_repository"
add_repository "NAS → Storage Box" "{}" storagebox_repository_summary "$nas_storagebox_repository"

jq -n --argjson repositories "$repositories_json" '{generated: (now | floor | todate), repositories: $repositories}' \
    > "$status_file.partial"
chmod 644 "$status_file.partial"
mv "$status_file.partial" "$status_file"

if [ ${#failed[@]} -gt 0 ]; then
    log "ERROR: failed: $(printf '%s; ' "${failed[@]}")status written to $status_file"
    exit 1
fi
log "Backup status written to $status_file"
