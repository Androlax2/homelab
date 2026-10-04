#!/usr/bin/env bash
set -euo pipefail

# remove what the recyclarr settings sync left behind
#
# Runs once on each server, as root, from the repo root, after the stacks are deployed.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Configarr replaced the two-way settings sync and its recyclarr container. Left on the server:
# the sync's GitHub token and last-synced marker in this checkout, no longer ignored by git,
# and recyclarr's folder, which only held its cache and state.

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

rm -f .github-token .arr-settings-synced
rm -rf "${DOCKERCONFDIR:?DOCKERCONFDIR is not set in stacks/common.env}/recyclarr"
echo "Removed .github-token, .arr-settings-synced and $DOCKERCONFDIR/recyclarr."
