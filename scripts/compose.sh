#!/usr/bin/env bash
set -euo pipefail

# Runs docker compose for one stack with the env files it needs: stacks/common.env
# (server-wide values), then stacks/<stack>/.env when the stack has an .env.example.
# Use it instead of calling docker compose directly: without these files every
# ${VAR} in compose.yml is silently empty.
#
# Usage: scripts/compose.sh <stack> <docker compose arguments...>
#   e.g. scripts/compose.sh media ps
#        scripts/compose.sh media logs -f sonarr

# DSM Task Scheduler's PATH does not include /usr/local/bin, where docker lives.
PATH="$PATH:/usr/local/bin"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stack="${1:?Usage: scripts/compose.sh <stack> <docker compose arguments...>}"
shift

if [ ! -f "$REPO_DIR/stacks/$stack/compose.yml" ]; then
    echo "No such stack: stacks/$stack/compose.yml" >&2
    exit 1
fi
if [ ! -f "$REPO_DIR/stacks/common.env" ]; then
    echo "Missing stacks/common.env: create it with scripts/edit_env.sh common" >&2
    exit 1
fi

env_file_args=(--env-file stacks/common.env)
if [ -f "$REPO_DIR/stacks/$stack/.env.example" ]; then
    if [ ! -f "$REPO_DIR/stacks/$stack/.env" ]; then
        echo "Missing stacks/$stack/.env: create it with scripts/edit_env.sh $stack" >&2
        exit 1
    fi
    env_file_args+=(--env-file "stacks/$stack/.env")
fi

cd "$REPO_DIR"
exec docker compose "${env_file_args[@]}" -f "stacks/$stack/compose.yml" "$@"
