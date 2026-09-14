#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Fails when a nightly backup hasn't succeeded within MAX_AGE_HOURS, so a task that was
# never scheduled, or silently stopped working, gets noticed. Each backup touches a marker
# file in BACKUPDIR when it succeeds (see MARKERS). scripts/deploy.sh runs this every 5
# minutes and DSM emails its failures: to send one email per problem rather than one every
# 5 minutes, the problem is remembered in .backup-alert and not failed again until the
# backups recover. When several markers are late, the first is reported, the next once
# that one recovers.
#
# Usage: scripts/check_backups.sh
# ============================================================

MAX_AGE_HOURS=26
# <marker file in BACKUPDIR>:<what it proves>, touched by backup_databases.sh and backup_nas.sh.
MARKERS=(
    "last-success:database backup"
    "offsite-last-success:off-NAS backup"
)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALERT_FILE="$REPO_DIR/.backup-alert"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

# Prints "<problem id><TAB><message>" for the first backup that needs attention, nothing when
# all are fine. The id stays the same for as long as the same problem lasts, unlike the message.
backup_problem() {
    local backup_root=""
    if [ -f "$REPO_DIR/stacks/common.env" ]; then
        backup_root=$(env_value "$REPO_DIR/stacks/common.env" BACKUPDIR)
    fi
    if [ -z "$backup_root" ]; then
        printf 'no-backupdir\tBACKUPDIR is not set in stacks/common.env. Add it with scripts/edit_env.sh common\n'
        return
    fi

    local marker marker_file what last_success age_hours
    for marker in "${MARKERS[@]}"; do
        marker_file="$backup_root/${marker%%:*}"
        what="${marker#*:}"
        if [ ! -f "$marker_file" ]; then
            printf 'never-%s\tno %s has succeeded yet (%s is missing)\n' "${marker%%:*}" "$what" "$marker_file"
            return
        fi
        last_success=$(stat -c %Y "$marker_file")
        age_hours=$(( ($(date +%s) - last_success) / 3600 ))
        if [ "$age_hours" -ge "$MAX_AGE_HOURS" ]; then
            printf 'stale-%s-%s\tthe last successful %s was %s hours ago\n' "${marker%%:*}" "$last_success" "$what" "$age_hours"
            return
        fi
    done
}

problem=$(backup_problem)
if [ -z "$problem" ]; then
    rm -f "$ALERT_FILE"
    exit 0
fi

problem_id="${problem%%$'\t'*}"
message="${problem#*$'\t'}"
if [ -f "$ALERT_FILE" ] && [ "$(cat "$ALERT_FILE")" = "$problem_id" ]; then
    exit 0
fi
printf '%s\n' "$problem_id" > "$ALERT_FILE"
log "ERROR: Backups: $message. Check the backup_nas.sh task in DSM Task Scheduler and its last output."
exit 1
