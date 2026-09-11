#!/usr/bin/env bash
set -euo pipefail

# Creates operations/<timestamp>_<description>.sh from a template: a one-time
# operation the server runs once, after its next deploy (see run_operations.sh).
#
# Usage: scripts/new_operation.sh "reset immich password"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
description="${1:?Usage: scripts/new_operation.sh \"what the operation does\"}"
description=$(printf '%s' "$description" | tr '\n' ' ')
slug=$(printf '%s' "$description" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')
if [ -z "$slug" ]; then
    echo "The description needs at least one letter or digit." >&2
    exit 1
fi

mkdir -p "$REPO_DIR/operations"
# UTC, so that operations written on different machines still sort in the order they were written.
operation_file="$REPO_DIR/operations/$(date -u '+%Y_%m_%d_%H%M%S')_$slug.sh"
if [ -e "$operation_file" ]; then
    echo "$operation_file already exists." >&2
    exit 1
fi

cat > "$operation_file" <<TEMPLATE
#!/usr/bin/env bash
set -euo pipefail

# $description
#
# Runs once on each server, as root, from the repo root, after the stacks are deployed.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Commands inside a container go through scripts/compose.sh, with -T (no terminal):
#   scripts/compose.sh photos exec -T immich-database psql -U immich -d immich -c 'SELECT 1'

TEMPLATE
chmod 755 "$operation_file"
echo "${operation_file#"$REPO_DIR"/}"
