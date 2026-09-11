#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# One-time operations: scripts in operations/ that each server runs exactly once,
# in file name order (the names start with a timestamp, see new_operation.sh).
# deploy.sh calls this after the stacks are updated.
#
# An operation is recorded in .operations-done only once it succeeded. The first
# failure stops the run, and the next deploy retries it. A recorded operation never
# runs again, even if its file changes: write a new one instead.
#
# Usage: scripts/run_operations.sh                  run the pending operations
#        scripts/run_operations.sh --list           show every operation and whether it ran
#        scripts/run_operations.sh --mark-all-done  record the pending operations as done
#                                                   without running them (a rebuilt server)
# ============================================================

# DSM Task Scheduler's PATH does not include /usr/local/bin, where docker lives.
PATH="$PATH:/usr/local/bin"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPERATIONS_DIR="$REPO_DIR/operations"
DONE_FILE="$REPO_DIR/.operations-done"
USAGE="Usage: scripts/run_operations.sh [--list | --mark-all-done]"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

# deploy.sh hands down its locked fd 9; run by hand, take the same lock so that an
# operation can never run twice at the same time.
take_deploy_lock() {
    if ! (: >&9) 2>/dev/null; then
        exec 9>"$REPO_DIR/.deploy.lock"
    fi
    if ! flock -n 9; then
        echo "A deploy is running: try again once it's done." >&2
        exit 1
    fi
}

operation_names() {
    local operation_file
    for operation_file in "$OPERATIONS_DIR"/*.sh; do
        [ -f "$operation_file" ] || continue
        basename "$operation_file"
    done | LC_ALL=C sort
}

is_done() {
    [ -f "$DONE_FILE" ] && grep -qxF "$1" "$DONE_FILE"
}

pending_operations() {
    local name
    while read -r name; do
        if ! is_done "$name"; then
            printf '%s\n' "$name"
        fi
    done < <(operation_names)
}

run_pending_operations() {
    local pending name
    pending=$(pending_operations)
    if [ -z "$pending" ]; then
        return 0
    fi
    while read -r name <&3; do
        log "Operation $name: running"
        # No input, and no fd 3 (the list of the next operations): a command that waits for an
        # answer gets end-of-file and fails, instead of hanging the deploy.
        if ! (cd "$REPO_DIR" && bash "$OPERATIONS_DIR/$name" < /dev/null 3<&-); then
            log "ERROR: operation $name failed. It runs again on the next deploy; the operations after it wait."
            exit 1
        fi
        printf '%s\n' "$name" >> "$DONE_FILE"
        log "Operation $name: done"
    done 3<<<"$pending"
}

list_operations() {
    local name
    while read -r name; do
        if is_done "$name"; then
            echo "done     $name"
        else
            echo "pending  $name"
        fi
    done < <(operation_names)
}

mark_all_done() {
    local pending name count=0
    pending=$(pending_operations)
    while read -r name; do
        [ -n "$name" ] || continue
        printf '%s\n' "$name" >> "$DONE_FILE"
        count=$((count + 1))
    done <<<"$pending"
    log "Recorded $count operation(s) as done without running them."
}

case "${1:-}" in
    "")
        take_deploy_lock
        run_pending_operations
        ;;
    --list)
        list_operations
        ;;
    --mark-all-done)
        take_deploy_lock
        mark_all_done
        ;;
    *)
        echo "$USAGE" >&2
        exit 1
        ;;
esac
