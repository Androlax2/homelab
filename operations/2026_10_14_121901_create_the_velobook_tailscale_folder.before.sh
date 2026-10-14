#!/usr/bin/env bash
set -euo pipefail

# create the velobook tailscale folder
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Synology's Docker refuses to start a container whose bind-mounted folder doesn't exist.
# It stays root's: the velobook-tailscale container runs as root. It holds the node's key.

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

ts_dir="$DOCKERCONFDIR/velobook-tailscale"
mkdir -p "$ts_dir"
chmod 700 "$ts_dir"
echo "$ts_dir is ready."
