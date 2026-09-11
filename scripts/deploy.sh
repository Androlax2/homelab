#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Deploys origin/main on the NAS. Run as root by a scheduler every 5 min.
#
# Fast-forwards this checkout, then redeploys what changed since the last
# successful run (commit stored in .last-deployed):
#   stacks/<stack>/...  -> docker compose up -d for that stack
#   config/<name>/...   -> docker restart <name>  (folder named after its container)
# then runs the one-time operations this server hasn't run yet (run_operations.sh).
#
# Nothing is touched until stacks/common.env and the .env of every stack about
# to be deployed define each key of their .env.example: a missing key would
# otherwise start the containers with an empty value.
#
# .last-deployed only moves once every step succeeded, so a failed run is
# retried on the next tick instead of being skipped.
# ============================================================

# DSM Task Scheduler's PATH does not include /usr/local/bin, where docker lives.
PATH="$PATH:/usr/local/bin"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAST_DEPLOYED_FILE="$REPO_DIR/.last-deployed"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

# $1 = env file, $2 = its .env.example, $3 = what to pass to edit_env.sh to fix it
assert_env_complete() {
    local env_file="$1" example_file="$2" edit_target="$3"
    if [ ! -f "$env_file" ]; then
        log "ERROR: $env_file is missing. Create it with scripts/edit_env.sh $edit_target"
        exit 1
    fi
    local missing_keys
    missing_keys=$(missing_env_keys "$example_file" "$env_file")
    if [ -n "$missing_keys" ]; then
        log "ERROR: $env_file lacks keys from $(basename "$example_file"): $(printf '%s' "$missing_keys" | tr '\n' ' ')"
        log "Add them with scripts/edit_env.sh $edit_target"
        exit 1
    fi
}

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
stacks_to_deploy=()
removed_stacks=()

for stack in $changed_stacks; do
    if [ -f "stacks/$stack/compose.yml" ]; then
        stacks_to_deploy+=("$stack")
    else
        removed_stacks+=("$stack")
    fi
done

if [ ${#stacks_to_deploy[@]} -gt 0 ]; then
    assert_env_complete stacks/common.env stacks/common.env.example common
fi
for stack in "${stacks_to_deploy[@]}"; do
    if [ -f "stacks/$stack/.env.example" ]; then
        assert_env_complete "stacks/$stack/.env" "stacks/$stack/.env.example" "$stack"
    fi
done

for stack in "${stacks_to_deploy[@]}"; do
    log "Stack $stack: compose up"
    "$REPO_DIR/scripts/compose.sh" "$stack" up -d --remove-orphans
done

for container in $changed_configs; do
    [ -d "config/$container" ] || continue
    log "Config $container: restart"
    docker restart "$container" > /dev/null
done

"$REPO_DIR/scripts/run_operations.sh"

printf '%s\n' "$current_commit" > "$LAST_DEPLOYED_FILE"
log "Deployed ${current_commit:0:7}."

# Tearing a stack down is never automatic. Exiting non-zero makes the scheduler
# report this once; .last-deployed already moved, so the next run does not repeat it.
if [ ${#removed_stacks[@]} -gt 0 ]; then
    for stack in "${removed_stacks[@]}"; do
        log "Stack $stack was removed from the repo. Tear it down by hand: docker compose -p $stack down"
    done
    exit 1
fi
