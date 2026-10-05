#!/usr/bin/env bash
set -euo pipefail

# create the monitoring folders
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Synology's Docker refuses to start a container whose bind-mounted folder doesn't exist.
# Only root may read them: Dozzle's holds its users file, Beszel's the key its agent trusts.
# beszel/volume1 stays empty: the agent only mounts it to read the volume's disk usage.

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

for state_dir in dozzle beszel beszel/data beszel/agent beszel/volume1 gatus; do
    mkdir -p "$DOCKERCONFDIR/$state_dir"
    chmod 700 "$DOCKERCONFDIR/$state_dir"
    echo "$DOCKERCONFDIR/$state_dir is ready."
done
