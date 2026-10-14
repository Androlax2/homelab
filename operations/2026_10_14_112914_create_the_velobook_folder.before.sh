#!/usr/bin/env bash
set -euo pipefail

# create the velobook folder
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Synology's Docker refuses to start a container whose bind-mounted folder doesn't exist.
# The velobook image runs as uid 65532 (distroless nonroot), so the folder is that uid's,
# and closed to others: it holds vélôToulouse logins and PIN hashes.

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

velobook_dir="$DOCKERCONFDIR/velobook"
mkdir -p "$velobook_dir"
chown -R 65532:65532 "$velobook_dir"
chmod 700 "$velobook_dir"
echo "$velobook_dir is ready."
