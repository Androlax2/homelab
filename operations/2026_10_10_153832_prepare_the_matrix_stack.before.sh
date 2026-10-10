#!/usr/bin/env bash
set -euo pipefail

# prepare the matrix stack
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Creates what the matrix stack can't start without and what can't be committed. Each step
# leaves alone what already exists, so a run that failed halfway can run again:
#   - its folders: Synology's Docker refuses to start a container whose bind-mounted folder doesn't exist
#   - stacks/matrix/.env, with a generated database password: the deploy refuses a stack without its .env
#   - local.yaml, the part of Synapse's configuration that holds the domain and that password
#   - Synapse's signing key: Synapse doesn't start without one

# DSM Task Scheduler's PATH does not include /usr/local/bin, where docker lives.
PATH="$PATH:/usr/local/bin"

# shellcheck source=scripts/lib.sh
source scripts/lib.sh

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

synapse_dir="$DOCKERCONFDIR/matrix/synapse"
env_file=stacks/matrix/.env
local_config="$synapse_dir/local.yaml"

mkdir -p "$synapse_dir" "$DOCKERCONFDIR/matrix/postgres"
# Synapse runs as this user (UID and GID in stacks/matrix/compose.yml).
chown "$PUID:$PGID" "$synapse_dir"
echo "$DOCKERCONFDIR/matrix is ready."

if [ ! -e "$env_file" ]; then
    (
        umask 077
        printf "SYNAPSE_DB_PASSWORD='%s'\n" "$(openssl rand -hex 32)" > "$env_file"
    )
    echo "$env_file is created."
fi
database_password=$(required_env_value "$env_file" SYNAPSE_DB_PASSWORD matrix)

if [ ! -e "$local_config" ]; then
    (
        umask 077
        cat > "$local_config.partial" <<YAML
# Written once by operations/2026_10_10_153832_prepare_the_matrix_stack.before.sh: what
# config/synapse/homeserver.yaml can't hold, because the repo is public.

# Part of every user ID (@name:matrix.$PROXY_DOMAIN): it can never change.
server_name: "matrix.$PROXY_DOMAIN"
public_baseurl: "https://matrix.$PROXY_DOMAIN/"

database:
  name: psycopg2
  args:
    host: synapse-db
    dbname: synapse
    user: synapse
    # The same as SYNAPSE_DB_PASSWORD in stacks/matrix/.env.
    password: "$database_password"
    cp_min: 5
    cp_max: 10
YAML
    )
    chown "$PUID:$PGID" "$local_config.partial"
    mv "$local_config.partial" "$local_config"
    echo "$local_config is created."
fi

if [ ! -e "$synapse_dir/signing.key" ]; then
    image=$(awk '$1 == "image:" && $2 ~ /^ghcr\.io\/element-hq\/synapse:/ { print $2 }' stacks/matrix/compose.yml)
    docker run --rm --user "$PUID:$PGID" --entrypoint python \
        -v "$PWD/config/synapse:/config:ro" -v "$synapse_dir:/data" \
        "$image" -m synapse.app.homeserver \
        --config-path=/config/homeserver.yaml --config-path=/data/local.yaml --generate-keys
    [ -s "$synapse_dir/signing.key" ] || { echo "Synapse did not write $synapse_dir/signing.key" >&2; exit 1; }
    echo "$synapse_dir/signing.key is created."
fi
