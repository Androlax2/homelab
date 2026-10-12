#!/usr/bin/env bash
set -euo pipefail

# prepare the paperless stack
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Creates what the paperless stack can't start without. Each step leaves alone what already
# exists, so a run that failed halfway can run again:
#   - its folders: Synology's Docker refuses to start a container whose bind-mounted folder doesn't exist
#   - stacks/paperless/.env, with a generated secret key and database password, and the inbox
#     in a folder of its own: the deploy refuses a stack without its .env

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

paperless_dir="$DOCKERCONFDIR/paperless"
env_file=stacks/paperless/.env

mkdir -p "$paperless_dir/data" "$paperless_dir/media" "$paperless_dir/consume" \
    "$paperless_dir/postgres" "$paperless_dir/redis"
# Paperless runs as this user (USERMAP_UID and USERMAP_GID in stacks/paperless/compose.yml).
chown "$PUID:$PGID" "$paperless_dir/data" "$paperless_dir/media" "$paperless_dir/consume"
echo "$paperless_dir is ready."

if [ ! -e "$env_file" ]; then
    (
        umask 077
        {
            printf "PAPERLESS_SECRET_KEY='%s'\n" "$(openssl rand -hex 48)"
            printf "PAPERLESS_DB_PASSWORD='%s'\n" "$(openssl rand -hex 32)"
            printf "PAPERLESS_CONSUME_DIR='%s'\n" "$paperless_dir/consume"
        } > "$env_file"
    )
    echo "$env_file is created."
fi
