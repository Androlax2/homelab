#!/usr/bin/env bash
set -euo pipefail

# remove OPUSLINE_VERSION from opusline env
#
# Runs once on each server, as root, from the repo root, after the stacks are deployed.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# The Opusline versions are written in stacks/opusline/compose.yml now (Renovate updates them),
# so the key is no longer read. Nothing is restarted: the API containers drop the unused variable
# the next time they are recreated.

env_file=stacks/opusline/.env

if [ ! -f "$env_file" ]; then
    echo "No $env_file on this server: nothing to remove."
    exit 0
fi
if ! grep -q '^OPUSLINE_VERSION=' "$env_file"; then
    echo "OPUSLINE_VERSION is already gone from $env_file."
    exit 0
fi

cp -p "$env_file" "$env_file.previous"
chmod 600 "$env_file.previous"
# Also drops the comment line the old .env.example put above the key.
without_version=$(awk '!/^OPUSLINE_VERSION=/ && !/^# Version of the Opusline images/' "$env_file")
# Rewritten in place, so the file keeps its owner and its 600 permissions.
printf '%s\n' "$without_version" > "$env_file"
echo "Removed OPUSLINE_VERSION from $env_file (previous version kept in $env_file.previous)."

