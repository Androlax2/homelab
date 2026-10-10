#!/usr/bin/env bash
set -euo pipefail

# create the adguardhome folders
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Synology's Docker refuses to start a container whose bind-mounted folder doesn't exist.
# They stay root's: the adguardhome container runs as root.

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

for adguardhome_dir in "$DOCKERCONFDIR/adguardhome/conf" "$DOCKERCONFDIR/adguardhome/work"; do
    mkdir -p "$adguardhome_dir"
    echo "$adguardhome_dir is ready."
done
