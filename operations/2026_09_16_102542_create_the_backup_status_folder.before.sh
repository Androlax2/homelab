#!/usr/bin/env bash
set -euo pipefail

# create the backup status folder
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# scripts/backup_status.sh writes backups.json there, and the backup-status container
# (stacks/infrastructure) serves it to Glance. Synology's Docker refuses to start a container
# whose bind-mounted folder doesn't exist. Readable by everyone, whatever user the container
# runs as.

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

status_dir="$DOCKERCONFDIR/backup-status"
mkdir -p "$status_dir"
chmod 755 "$status_dir"
echo "$status_dir is ready."
