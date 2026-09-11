#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Compares the containers running now with what stacks/<stack>/compose.yml
# would create, before you replace them. Run it once per stack, right before
# removing the old containers.
#
# Differences (exit 1):
#   - a service whose container does not exist
#   - bind mounts dropped, added, or pointing at another folder
#   - Docker volumes on the running containers (their data does not carry over)
#   - environment variables changed, dropped or new (names only, never values)
# Notes (do not fail):
#   - a mount moving into this repo's config/ folder, same target
#   - an image change, with the running image's version, to spot downgrades
#
# Usage: scripts/premigration_check.sh <stack>
# ============================================================

# DSM Task Scheduler's PATH does not include /usr/local/bin, where docker lives.
PATH="$PATH:/usr/local/bin"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stack="${1:?Usage: scripts/premigration_check.sh <stack>}"
if ! command -v jq > /dev/null; then
    echo "jq is required" >&2
    exit 1
fi

config_json=$("$REPO_DIR/scripts/compose.sh" "$stack" config --format json)
problem_count=0

report_problem() {
    printf '  %s\n' "$*"
    problem_count=$((problem_count + 1))
}

# $1 = note kind, rest = message
report_note() {
    printf '  (%s) %s\n' "$1" "${*:2}"
}

compare_mounts() {
    local service="$1" container_json="$2"
    local -A running_sources wanted_sources
    local target source
    while IFS=$'\t' read -r target source; do
        running_sources[$target]=$source
    done < <(jq -r '.[0].Mounts[] | select(.Type == "bind") | [.Destination, .Source] | @tsv' <<<"$container_json")
    while IFS=$'\t' read -r target source; do
        wanted_sources[$target]=$source
    done < <(jq -r --arg s "$service" '.services[$s].volumes // [] | .[] | select(.type == "bind") | [.target, .source] | @tsv' <<<"$config_json")

    while read -r target; do
        local running_source="${running_sources[$target]-}" wanted_source="${wanted_sources[$target]-}"
        if [ "$running_source" = "$wanted_source" ]; then
            continue
        elif [ -z "$wanted_source" ]; then
            report_problem "mount dropped: $target (was $running_source)"
        elif [ -z "$running_source" ]; then
            report_problem "mount added: $target <- $wanted_source"
        elif [[ "$wanted_source" == "$REPO_DIR/config/"* ]]; then
            report_note expected "mount moves into the repo: $target: $running_source -> $wanted_source"
        else
            report_problem "mount source changes: $target: $running_source -> $wanted_source"
        fi
    done < <(printf '%s\n' "${!running_sources[@]}" "${!wanted_sources[@]}" | sort -u)

    while read -r destination; do
        report_problem "Docker volume at $destination: its data does not carry over to a new container"
    done < <(jq -r '.[0].Mounts[] | select(.Type == "volume") | .Destination' <<<"$container_json")
}

# Variables the image sets itself (PATH...) are ignored unless the deployment overrode them.
compare_env() {
    local service="$1" container_json="$2" image_json="$3"
    local change key
    while read -r change key; do
        report_problem "env $change: $key"
    done < <(jq -rn \
        --argjson container "$container_json" \
        --argjson image "$image_json" \
        --argjson config "$config_json" \
        --arg service "$service" '
        def as_map: map(capture("^(?<key>[^=]+)=(?<value>.*)$"; "s") | {(.key): .value}) | add // {};
        ($container[0].Config.Env // [] | as_map) as $running
        | ($image[0].Config.Env // [] | as_map) as $image_defaults
        | ($config.services[$service].environment // {} | map_values(. // "")) as $wanted
        | ($running | with_entries(select($image_defaults[.key] != .value))) as $set_by_deployment
        | ($wanted | keys[] | select($running[.] == null) | "new \(.)"),
          ($wanted | to_entries[] | select($running[.key] != null and $running[.key] != .value) | "changed \(.key)"),
          ($set_by_deployment | keys[] | select($wanted[.] == null) | "dropped \(.)")')
}

compare_image() {
    local service="$1" container_json="$2" image_json="$3"
    local running_ref wanted_ref running_version
    running_ref=$(jq -r '.[0].Config.Image' <<<"$container_json")
    wanted_ref=$(jq -r --arg s "$service" '.services[$s].image' <<<"$config_json")
    if [ "$running_ref" = "$wanted_ref" ]; then
        return 0
    fi
    running_version=$(jq -r '.[0].Config.Labels["org.opencontainers.image.version"] // "unknown"' <<<"$image_json")
    report_note check "image: $running_ref (running version: $running_version) -> $wanted_ref"
}

compare_service() {
    local service="$1"
    local container container_json image_json
    printf '== %s\n' "$service"
    container=$(jq -r --arg s "$service" '.services[$s].container_name // empty' <<<"$config_json")
    if [ -z "$container" ]; then
        report_problem "no container_name in compose.yml: cannot tell which running container to compare"
        return 0
    fi
    if ! container_json=$(docker inspect "$container" 2>/dev/null); then
        report_problem "no container named $container"
        return 0
    fi
    image_json=$(docker image inspect "$(jq -r '.[0].Image' <<<"$container_json")")
    compare_mounts "$service" "$container_json"
    compare_env "$service" "$container_json" "$image_json"
    compare_image "$service" "$container_json" "$image_json"
}

while read -r service <&3; do
    compare_service "$service"
done 3< <(jq -r '.services | keys[]' <<<"$config_json")

echo
if [ "$problem_count" -gt 0 ]; then
    echo "$problem_count difference(s) to review before replacing the $stack containers."
    exit 1
fi
echo "No differences: the new compose file matches the running $stack containers."
