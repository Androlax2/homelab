#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Copies the quality profiles and custom formats currently set in Sonarr and Radarr
# into the Recyclarr config, exactly as they are, then runs preview_recyclarr.sh:
# when the preview shows no change, the repo mirrors the apps and can be pushed.
#   config/recyclarr/configs/instances.yml             profiles and custom format scores
#   config/recyclarr/custom-formats/<service>/*.json    every custom format, one file each
# Naming isn't copied: Recyclarr only accepts the TRaSH Guides' naming presets.
# sync_arr_settings.sh runs it on the NAS too, into a scratch folder (--to, --no-preview).
#
# It asks for the API keys (Settings > General in each app) unless SONARR_API_KEY /
# RADARR_API_KEY are set.
#
# Usage: scripts/export_arr_settings.sh [--to <directory>] [--no-preview]
#        SONARR_URL=http://<nas>:8989 RADARR_URL=http://<nas>:7878 scripts/export_arr_settings.sh
# ============================================================

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SONARR_URL="${SONARR_URL:-http://jeancloud:8989}"
export RADARR_URL="${RADARR_URL:-http://jeancloud:7878}"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

output_dir="$REPO_DIR/config/recyclarr"
run_preview=true
while [ $# -gt 0 ]; do
    case "$1" in
        --to)
            output_dir="${2:?--to needs a directory}"
            shift 2
            ;;
        --no-preview)
            run_preview=false
            shift
            ;;
        *)
            echo "Usage: scripts/export_arr_settings.sh [--to <directory>] [--no-preview]" >&2
            exit 1
            ;;
    esac
done

# $1 = base URL, $2 = API key, $3 = API path
api_get() {
    if ! curl -sf -H "X-Api-Key: $2" "$1$3"; then
        echo "Could not read $1$3 (check the URL and the API key)." >&2
        return 1
    fi
}

# Adds a stable trash_id (homelab-<service>-<name>) and keeps only what a custom format definition needs;
# the API's field objects become the name/value map Recyclarr expects.
CUSTOM_FORMATS_JQ='
    def slug: ascii_downcase | gsub("\\+"; "plus") | gsub("[^a-z0-9]+"; "-") | gsub("^-+|-+$"; "");
    (map(. + {slug: (if (.name | slug) == "" then "cf-\(.id)" else (.name | slug) end)})
     | group_by(.slug)
     | map(if length > 1 then map(.slug += "-\(.id)") else . end)
     | add) // []
    | map({
        id,
        trash_id: "homelab-\($service)-\(.slug)",
        name,
        includeCustomFormatWhenRenaming,
        specifications: [.specifications[] | {
            name, implementation, negate, required,
            fields: ((.fields // []) | map({(.name): .value}) | add // {})
        }]
    })'

# Writes the instance block: profiles with their qualities in screen order (the API lists
# them lowest first), then every custom format with the scores the profiles give it.
INSTANCE_YAML_JQ='
    def q: @json;
    def is_group: (.items // []) | length > 0;
    def item_name: if is_group then .name else .quality.name end;
    def quality_entry:
        "          - name: \(item_name | q)\n"
        + (if .allowed then "" else "            enabled: false\n" end)
        + (if is_group then "            qualities:\n" + ([.items | reverse[] | "              - \(.quality.name | q)\n"] | join("")) else "" end);
    def cutoff_name: .cutoff as $cutoff | [.items[] | select((is_group and .id == $cutoff) or ((is_group | not) and .quality.id == $cutoff)) | item_name] | first;
    .profiles as $profiles
    | .custom_formats as $custom_formats
    | ($profiles | map(
        "      - name: \(.name | q)\n"
        + "        upgrade:\n"
        + "          allowed: \(.upgradeAllowed)\n"
        + "          until_quality: \(cutoff_name | q)\n"
        + "          until_score: \(.cutoffFormatScore // 0)\n"
        + "        min_format_score: \(.minFormatScore // 0)\n"
        + (if has("minUpgradeFormatScore") then "        min_upgrade_format_score: \(.minUpgradeFormatScore)\n" else "" end)
        + "        reset_unmatched_scores:\n          enabled: true\n"
        + "        quality_sort: top\n"
        + "        qualities:\n"
        + ([.items | reverse[] | quality_entry] | join(""))
    ) | join("")) as $profiles_yaml
    | ($custom_formats | map(. as $format |
        "      - trash_ids:\n          - \(.trash_id)\n"
        + ([$profiles[] | .name as $profile | (.formatItems // [])[] | select(.format == $format.id and .score != 0)
            | "          - name: \($profile | q)\n            score: \(.score)\n"]
           | if length > 0 then "        assign_scores_to:\n" + join("") else "" end)
    ) | join("")) as $formats_yaml
    | "\($service):\n  \($instance):\n"
      + "    base_url: !env_var \($service | ascii_upcase)_BASE_URL\n"
      + "    api_key: !env_var \($service | ascii_upcase)_API_KEY\n"
      + "    delete_old_custom_formats: true\n"
      + (if $profiles_yaml == "" then "" else "    quality_profiles:\n" + $profiles_yaml end)
      + (if $formats_yaml == "" then "" else "    custom_formats:\n" + $formats_yaml end)'

ask_api_key SONARR_API_KEY Sonarr
ask_api_key RADARR_API_KEY Radarr

# Read everything first: nothing is written unless both apps answered.
sonarr_formats=$(api_get "$SONARR_URL" "$SONARR_API_KEY" /api/v3/customformat)
sonarr_profiles=$(api_get "$SONARR_URL" "$SONARR_API_KEY" /api/v3/qualityprofile)
radarr_formats=$(api_get "$RADARR_URL" "$RADARR_API_KEY" /api/v3/customformat)
radarr_profiles=$(api_get "$RADARR_URL" "$RADARR_API_KEY" /api/v3/qualityprofile)

# $1 = service, $2 = instance name in instances.yml, $3 = custom formats JSON, $4 = profiles JSON
export_service() {
    local service="$1" instance="$2" formats_json="$3" profiles_json="$4"
    local formats_dir="$output_dir/custom-formats/$service" custom_formats
    custom_formats=$(jq -c --arg service "$service" "$CUSTOM_FORMATS_JQ" <<<"$formats_json")

    mkdir -p "$formats_dir"
    find "$formats_dir" -maxdepth 1 -name '*.json' -delete
    jq -c '.[]' <<<"$custom_formats" | while read -r custom_format; do
        jq 'del(.id)' <<<"$custom_format" > "$formats_dir/$(jq -r .trash_id <<<"$custom_format").json"
    done

    # Through stdin: as an argument (--argjson), a real app's JSON exceeds the kernel's 128 KB limit.
    jq -r --arg service "$service" --arg instance "$instance" "$INSTANCE_YAML_JQ" \
        <<<"{\"profiles\": $profiles_json, \"custom_formats\": $custom_formats}"
}

sonarr_yaml=$(export_service sonarr series "$sonarr_formats" "$sonarr_profiles")
radarr_yaml=$(export_service radarr movies "$radarr_formats" "$radarr_profiles")
mkdir -p "$output_dir/configs"
{
    echo "# Sonarr/Radarr quality profiles and custom formats, synced both ways by scripts/sync_arr_settings.sh"
    echo "# on the NAS: changes made here are applied to the apps, changes made in the apps come back as a pull"
    echo "# request. Check a change before pushing it: scripts/preview_recyclarr.sh."
    echo
    printf '%s\n\n' "$sonarr_yaml"
    printf '%s\n' "$radarr_yaml"
} > "$output_dir/configs/instances.yml"

echo "Wrote $output_dir/configs/instances.yml and $output_dir/custom-formats/."
if [ "$run_preview" = true ]; then
    echo "Previewing what a sync of these files would change (it must show no change before you push):"
    exec "$REPO_DIR/scripts/preview_recyclarr.sh"
fi
