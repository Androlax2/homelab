#!/usr/bin/env bash
set -euo pipefail

# create the runway folders
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Synology's Docker refuses to start a container whose bind-mounted folder doesn't exist.
# The runway image runs as uid 1000, so the folders are that uid's. Nothing in them is
# created or replaced: a database already there (restored from a backup) is kept as it is,
# and only given to that uid. `secrets` holds the Enable Banking private key: closed to others.

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

runway_dir="$DOCKERCONFDIR/runway"
mkdir -p "$runway_dir/database" "$runway_dir/storage" "$runway_dir/secrets"
chown -R 1000:1000 "$runway_dir"
chmod 700 "$runway_dir/secrets"
echo "$runway_dir is ready."
