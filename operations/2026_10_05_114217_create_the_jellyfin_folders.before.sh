#!/usr/bin/env bash
set -euo pipefail

# create the jellyfin folders
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Synology's Docker refuses to start a container whose bind-mounted folder doesn't exist.
# They stay root's: the jellyfin container runs as root.

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

for jellyfin_dir in "$DOCKERCONFDIR/jellyfin/config" "$DOCKERCONFDIR/jellyfin/cache"; do
    mkdir -p "$jellyfin_dir"
    echo "$jellyfin_dir is ready."
done

