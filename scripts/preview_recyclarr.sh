#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Shows what Recyclarr would change in Sonarr and Radarr if it synced the repo's
# config/recyclarr/ now, without changing anything (`recyclarr sync --preview`).
# Runs the Recyclarr version pinned in stacks/media/compose.yml, from this computer,
# against the NAS. Run it before pushing a change to config/recyclarr/.
#
# It asks for the API keys unless SONARR_API_KEY / RADARR_API_KEY are set.
#
# Usage: scripts/preview_recyclarr.sh
#        SONARR_URL=http://<nas>:8989 RADARR_URL=http://<nas>:7878 scripts/preview_recyclarr.sh
# ============================================================

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECYCLARR_DIR="$REPO_DIR/config/recyclarr"
SONARR_URL="${SONARR_URL:-http://jeancloud:8989}"
RADARR_URL="${RADARR_URL:-http://jeancloud:7878}"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

recyclarr_image=$(awk '$1 == "image:" && $2 ~ /^ghcr\.io\/recyclarr\/recyclarr:/ { print $2; exit }' "$REPO_DIR/stacks/media/compose.yml")
if [ -z "$recyclarr_image" ]; then
    echo "No ghcr.io/recyclarr/recyclarr image in stacks/media/compose.yml" >&2
    exit 1
fi

ask_api_key SONARR_API_KEY Sonarr
ask_api_key RADARR_API_KEY Radarr

# Recyclarr needs a writable /config for its state; the repo's files go inside it read-only, as on the NAS.
state_dir=$(mktemp -d)
trap 'rm -rf "$state_dir"' EXIT

# The keys are passed by name (-e VAR), so their values never appear in the process list.
docker run --rm --network host --user "$(id -u):$(id -g)" \
    -e SONARR_BASE_URL="$SONARR_URL" -e RADARR_BASE_URL="$RADARR_URL" \
    -e SONARR_API_KEY -e RADARR_API_KEY \
    -v "$state_dir:/config" \
    -v "$RECYCLARR_DIR/configs:/config/configs:ro" \
    -v "$RECYCLARR_DIR/settings.yml:/config/settings.yml:ro" \
    -v "$RECYCLARR_DIR/custom-formats:/config/custom-formats:ro" \
    "$recyclarr_image" sync --preview
