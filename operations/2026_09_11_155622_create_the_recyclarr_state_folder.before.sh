#!/usr/bin/env bash
set -euo pipefail

# create the recyclarr state folder
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Docker creates a missing bind-mount folder as root, but recyclarr runs as PUID:PGID and
# writes its state there: the folder must be theirs before the container first starts.

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

state_dir="$DOCKERCONFDIR/recyclarr"
mkdir -p "$state_dir"
chown "$PUID:$PGID" "$state_dir"
echo "$state_dir belongs to $PUID:$PGID."
