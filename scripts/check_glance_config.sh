#!/usr/bin/env bash
set -euo pipefail

# Validates config/glance with the Glance version stacks/infrastructure pins (`glance
# config:validate`), giving it every variable of the .env.example files. Glance refuses
# a config that references an unset variable, so this also catches a widget using a
# variable nobody declared. Pulls the Glance image: meant for CI.
#
# Usage: bash scripts/check_glance_config.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

glance_image=$(awk '$1 == "image:" && $2 ~ /^glanceapp\/glance:/ { print $2; exit }' "$REPO_DIR/stacks/infrastructure/compose.yml")
if [ -z "$glance_image" ]; then
    echo "No glanceapp/glance image in stacks/infrastructure/compose.yml" >&2
    exit 1
fi

env_file=$(mktemp)
trap 'rm -f "$env_file"' EXIT
grep -hE '^[A-Za-z_][A-Za-z0-9_]*=' "$REPO_DIR/stacks/common.env.example" "$REPO_DIR/stacks/infrastructure/.env.example" > "$env_file"
# Glance's own rules for a login: a secret key, a username of 3+ characters, a password hash.
sed -i \
    -e 's/^GLANCE_SECRET_KEY=.*/GLANCE_SECRET_KEY=check/' \
    -e 's/^GLANCE_USERNAME=.*/GLANCE_USERNAME=check/' \
    -e 's/^GLANCE_PASSWORD_HASH=.*/GLANCE_PASSWORD_HASH=check/' \
    "$env_file"

docker run --rm --env-file "$env_file" \
    -v "$REPO_DIR/config/glance/config:/app/config:ro" \
    -v "$REPO_DIR/config/glance/assets:/app/assets:ro" \
    "$glance_image" config:validate
