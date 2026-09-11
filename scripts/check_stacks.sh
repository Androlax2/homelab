#!/usr/bin/env bash
set -euo pipefail

# Validates every stack without touching any real .env, using stacks/common.env.example
# and the stack's own .env.example as its env files:
#   - docker compose accepts the stack
#   - every ${VAR} it uses is listed in an .env.example
#   - no service runs privileged, and only the services in DOCKER_SOCKET_SERVICES mount
#     the Docker socket: whoever holds it is root on the server
#
# Usage: bash scripts/check_stacks.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

DOCKER_SOCKET_SERVICES="portainer docker-socket-proxy"

# Values the example files leave empty but compose can't accept empty: an empty DOCKERSTORAGEDIR
# turns "${DOCKERSTORAGEDIR}:/data" into an invalid ":/data", and OPUSLINE_VERSION is required.
export DOCKERCONFDIR=/check/config DOCKERSTORAGEDIR=/check/storage FILEBROWSER_ROOT=/check/filebrowser
export OPUSLINE_VERSION=check

# Prints one line per service that breaks the privilege rules above.
privilege_violations() {
    jq -r --arg allowed "$DOCKER_SOCKET_SERVICES" '
        ($allowed | split(" ")) as $allowed_services
        | .services | to_entries[]
        | (select(.value.privileged == true) | "\(.key): privileged: true"),
          (select(any(.value.volumes[]?; .source == "/var/run/docker.sock"))
           | select(.key | IN($allowed_services[]) | not)
           | "\(.key): mounts the Docker socket (allowed only for: \($allowed_services | join(", ")))")'
}

failed_stacks=0
for compose_file in "$REPO_DIR"/stacks/*/compose.yml; do
    stack_dir=$(dirname "$compose_file")
    stack=$(basename "$stack_dir")
    stack_env_example=/dev/null
    if [ -f "$stack_dir/.env.example" ]; then
        stack_env_example="$stack_dir/.env.example"
    fi

    warnings_file=$(mktemp)
    if config_json=$(stack_config_json "$REPO_DIR" "$stack" "$REPO_DIR/stacks/common.env.example" "$stack_env_example" 2>"$warnings_file"); then
        problems=$({
            grep 'variable is not set' "$warnings_file" || true
            privilege_violations <<<"$config_json"
        })
    else
        problems=$(cat "$warnings_file")
        problems=${problems:-"docker compose config failed without a message"}
    fi
    rm -f "$warnings_file"

    if [ -z "$problems" ]; then
        echo "OK    $stack"
    else
        echo "FAIL  $stack"
        sed 's/^/      /' <<<"$problems"
        failed_stacks=$((failed_stacks + 1))
    fi
done

[ "$failed_stacks" -eq 0 ]
