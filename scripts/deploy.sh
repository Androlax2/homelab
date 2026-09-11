#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Deploys origin/main on the NAS. Run as root by DSM Task Scheduler every 5 min.
#
# Fast-forwards this checkout, then redeploys what changed since the last
# successful run (commit stored in .last-deployed):
#   stacks/<stack>/...  -> docker compose up -d for that stack
#   config/<name>/...   -> docker restart <name>  (folder named after its container)
#
# .last-deployed only moves once every step succeeded, so a failed run is
# retried on the next tick instead of being skipped.
# ============================================================

# DSM Task Scheduler's PATH does not include /usr/local/bin, where docker lives.
PATH="$PATH:/usr/local/bin"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAST_DEPLOYED_FILE="$REPO_DIR/.last-deployed"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

cd "$REPO_DIR"

exec 9>"$REPO_DIR/.deploy.lock"
if ! flock -n 9; then
    log "Another deploy is still running, skipping."
    exit 0
fi

git fetch --quiet origin main
git merge --ff-only --quiet origin/main
current_commit=$(git rev-parse HEAD)

if [ -f "$LAST_DEPLOYED_FILE" ]; then
    last_deployed_commit=$(cat "$LAST_DEPLOYED_FILE")
    if [ "$last_deployed_commit" = "$current_commit" ]; then
        exit 0
    fi
    log "Deploying ${last_deployed_commit:0:7}..${current_commit:0:7}"
    changed_paths=$(git diff --name-only --no-renames "$last_deployed_commit" "$current_commit")
else
    log "No .last-deployed yet: deploying everything at ${current_commit:0:7}"
    changed_paths=$(git ls-files)
fi

changed_stacks=$(printf '%s\n' "$changed_paths" | awk -F/ '$1 == "stacks" && NF > 2 { print $2 }' | sort -u)
changed_configs=$(printf '%s\n' "$changed_paths" | awk -F/ '$1 == "config" && NF > 2 { print $2 }' | sort -u)
removed_stacks=()

for stack in $changed_stacks; do
    compose_file="stacks/$stack/compose.yml"
    if [ ! -f "$compose_file" ]; then
        removed_stacks+=("$stack")
        continue
    fi
    log "Stack $stack: compose up"
    docker compose -f "$compose_file" up -d --remove-orphans
done

for container in $changed_configs; do
    [ -d "config/$container" ] || continue
    log "Config $container: restart"
    docker restart "$container" > /dev/null
done

printf '%s\n' "$current_commit" > "$LAST_DEPLOYED_FILE"
log "Deployed ${current_commit:0:7}."

# Tearing a stack down is never automatic. Exiting non-zero makes DSM email this
# once; .last-deployed already moved, so the next run does not repeat it.
if [ ${#removed_stacks[@]} -gt 0 ]; then
    for stack in "${removed_stacks[@]}"; do
        log "Stack $stack was removed from the repo. Tear it down by hand: docker compose -p $stack down"
    done
    exit 1
fi
