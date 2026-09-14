#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Edits secrets on the server: stacks/<stack>/.env, or stacks/common.env for the
# values every stack shares. Neither file is ever committed.
#
# Opens a copy in $EDITOR, then checks that it defines every key of the matching
# .env.example and that docker compose accepts every stack it affects. Only then
# does it replace the file (the old one is kept as <file>.previous) and redeploy:
# that stack, or every deployable stack for common. Compose recreates only the
# containers whose configuration changed.
#
# Usage: scripts/edit_env.sh <stack>|common
# ============================================================

# DSM Task Scheduler's PATH does not include /usr/local/bin, where docker lives.
PATH="$PATH:/usr/local/bin"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

target="${1:?Usage: scripts/edit_env.sh <stack>|common}"
common_env="$REPO_DIR/stacks/common.env"
affected_stacks=()

if [ "$target" = "common" ]; then
    env_file="$common_env"
    example_file="$REPO_DIR/stacks/common.env.example"
    for compose_file in "$REPO_DIR"/stacks/*/compose.yml; do
        stack=$(basename "$(dirname "$compose_file")")
        # A stack whose own .env doesn't exist yet can be neither validated nor deployed.
        if [ ! -f "$REPO_DIR/stacks/$stack/.env.example" ] || [ -f "$REPO_DIR/stacks/$stack/.env" ]; then
            affected_stacks+=("$stack")
        fi
    done
else
    stack_dir="$REPO_DIR/stacks/$target"
    if [ ! -f "$stack_dir/compose.yml" ]; then
        echo "No such stack: stacks/$target/compose.yml" >&2
        exit 1
    fi
    if [ ! -f "$stack_dir/.env.example" ]; then
        echo "stacks/$target has no .env.example: it only uses stacks/common.env (scripts/edit_env.sh common)." >&2
        exit 1
    fi
    if [ ! -f "$common_env" ]; then
        echo "Create stacks/common.env first: scripts/edit_env.sh common" >&2
        exit 1
    fi
    env_file="$stack_dir/.env"
    example_file="$stack_dir/.env.example"
    affected_stacks=("$target")
fi

# Waits for a running deploy instead of racing it.
exec 9>"$REPO_DIR/.deploy.lock"
flock 9

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
draft="$work_dir/draft.env"
if [ -f "$env_file" ]; then
    cp "$env_file" "$draft"
else
    cp "$example_file" "$draft"
fi
chmod 600 "$draft"

# The env files a stack would get if the draft were saved.
common_env_with_draft() {
    if [ "$target" = "common" ]; then
        echo "$draft"
    else
        echo "$common_env"
    fi
}

stack_env_with_draft() {
    local stack="$1"
    if [ ! -f "$REPO_DIR/stacks/$stack/.env.example" ]; then
        echo /dev/null
    elif [ "$stack" = "$target" ]; then
        echo "$draft"
    else
        echo "$REPO_DIR/stacks/$stack/.env"
    fi
}

# Prints what is wrong with the draft and returns non-zero, or returns zero.
validate_draft() {
    local missing_keys
    missing_keys=$(missing_env_keys "$example_file" "$draft")
    if [ -n "$missing_keys" ]; then
        echo "Missing keys from $(basename "$example_file"): $(printf '%s' "$missing_keys" | tr '\n' ' ')"
        return 1
    fi
    local stack warnings status has_problems=0
    for stack in "${affected_stacks[@]}"; do
        status=0
        warnings=$(stack_config_json "$REPO_DIR" "$stack" "$(common_env_with_draft)" "$(stack_env_with_draft "$stack")" 2>&1 >/dev/null) || status=$?
        if [ "$status" -ne 0 ] || grep -q 'variable is not set' <<<"$warnings"; then
            printf 'stacks/%s is rejected:\n%s\n' "$stack" "$warnings"
            has_problems=1
        fi
    done
    return "$has_problems"
}

while true; do
    "${EDITOR:-vi}" "$draft"
    if problems=$(validate_draft); then
        break
    fi
    printf '%s\n' "$problems" >&2
    if [ ! -t 0 ]; then
        echo "$env_file left unchanged." >&2
        exit 1
    fi
    read -r -p "Edit again? [Y/n] " answer
    if [ "$answer" = "n" ]; then
        echo "$env_file left unchanged." >&2
        exit 1
    fi
done

if [ -f "$env_file" ] && cmp -s "$draft" "$env_file"; then
    echo "No changes."
    exit 0
fi

if [ -f "$env_file" ]; then
    cp -p "$env_file" "$env_file.previous"
    chmod 600 "$env_file.previous"
fi
cp "$draft" "$env_file"
chmod 600 "$env_file"
log "$env_file updated. Redeploying: ${affected_stacks[*]}"
for stack in "${affected_stacks[@]}"; do
    compose_up_stack "$REPO_DIR" "$stack"
done
