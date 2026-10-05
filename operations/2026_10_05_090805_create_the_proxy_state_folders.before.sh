#!/usr/bin/env bash
set -euo pipefail

# create the proxy state folders
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Synology's Docker refuses to start a container whose bind-mounted folder doesn't exist.
# Both hold a private key (the tailnet node's, the certificates'), so only root may read them.

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

for state_dir in "$DOCKERCONFDIR/tailscale" "$DOCKERCONFDIR/traefik"; do
    mkdir -p "$state_dir"
    chmod 700 "$state_dir"
    echo "$state_dir is ready."
done

