#!/usr/bin/env bash
set -euo pipefail

# create the cooklang recipes folder
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Docker creates a missing bind-mount folder as root, but CookCLI runs as PUID:PGID and
# its entrypoint exits when /recipes is not writable by that user: the folder must be
# theirs before the container first starts.

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

recipes_dir="$DOCKERSTORAGEDIR/recipes"
mkdir -p "$recipes_dir"
chown "$PUID:$PGID" "$recipes_dir"
echo "$recipes_dir belongs to $PUID:$PGID."
