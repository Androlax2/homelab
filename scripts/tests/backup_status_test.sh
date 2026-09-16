#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/backup_status.sh in a sandbox repo with the real compose.sh: the PC's NAS
# repository and its share snapshots are local folders, `docker` is stubbed to run the sftp batch
# against STUB_STORAGEBOX (each folder's .listing file holds its canned `ls -l` lines), and `date`
# is stubbed for "now" only, so sftp dates without a year give the same result on any day.
#
# Usage: bash scripts/tests/backup_status_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

REAL_DATE=$(command -v date)
TIME_ZONE="Europe/Paris"

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    repo_dir="$sandbox/repo"
    status_file="$sandbox/appdata/backup-status/backups.json"
    pc_nas_repository="$sandbox/volume1/restic/archlinux"
    pc_nas_snapshots="$sandbox/volume1/@sharesnap/restic"
    mkdir -p "$repo_dir/scripts" "$repo_dir/stacks/backup" "$sandbox/bin" "$(dirname "$status_file")" \
        "$pc_nas_repository/snapshots" "$pc_nas_snapshots"
    cp "$SCRIPTS_DIR/backup_status.sh" "$SCRIPTS_DIR/compose.sh" "$SCRIPTS_DIR/lib.sh" "$repo_dir/scripts/"
    printf 'DOCKERCONFDIR=%s\nTZ=%s\n' "$sandbox/appdata" "$TIME_ZONE" > "$repo_dir/stacks/common.env"
    printf 'services: {}\n' > "$repo_dir/stacks/backup/compose.yml"
    printf 'RESTIC_REPOSITORY=\n' > "$repo_dir/stacks/backup/.env.example"
    cat > "$repo_dir/stacks/backup/.env" <<ENV
RESTIC_REPOSITORY=sftp:storagebox:restic/jeancloud
PC_RESTIC_NAS_REPOSITORY=$pc_nas_repository
PC_RESTIC_NAS_SNAPSHOTS=$pc_nas_snapshots
PC_RESTIC_STORAGEBOX_REPOSITORY=restic/archlinux
ENV

    export STUB_STORAGEBOX="$sandbox/storagebox" REAL_DATE
    # STUB_NOW: the epoch `date +%s` prints, and the year `date +%Y` prints in TIME_ZONE.
    export STUB_NOW
    STUB_NOW=$(TZ="$TIME_ZONE" "$REAL_DATE" -d '2026-09-17 12:00' +%s)
    create_storagebox_repository restic/archlinux
    create_storagebox_repository restic/jeancloud

    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" != *"run --rm -T --entrypoint sftp restic -b - storagebox" ]]; then
    echo "unexpected docker call: $*" >&2
    exit 99
fi
while read -r command flag folder; do
    echo "sftp> $command $flag $folder"
    if [ ! -d "$STUB_STORAGEBOX/$folder" ]; then
        echo "Can't ls: \"/home/$folder\" not found" >&2
        exit 1
    fi
    if [ -f "$STUB_STORAGEBOX/$folder/.listing" ]; then
        cat "$STUB_STORAGEBOX/$folder/.listing"
    fi
done
STUB
    cat > "$sandbox/bin/date" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "+%s") echo "$STUB_NOW" ;;
    "+%Y") exec "$REAL_DATE" -d "@$STUB_NOW" +%Y ;;
    *) exec "$REAL_DATE" "$@" ;;
esac
STUB
    chmod +x "$sandbox/bin/docker" "$sandbox/bin/date"
    export PATH="$sandbox/bin:$PATH"
}

in_sandbox() {
    create_sandbox
    "$@"
}

# Creates the folders of an empty repository on the stubbed Storage Box. $1 = path on the box
create_storagebox_repository() {
    local repository="$STUB_STORAGEBOX/$1" data_folder_index
    mkdir -p "$repository/keys" "$repository/index" "$repository/snapshots"
    for ((data_folder_index = 0; data_folder_index < 256; data_folder_index++)); do
        mkdir -p "$repository/data/$(printf '%02x' "$data_folder_index")"
    done
}

# Adds a file to the `ls -l` of a folder on the stubbed Storage Box.
# $1 = folder, $2 = size, $3 = date as sftp shows it, $4 = file name
add_storagebox_file() {
    printf -- '-r--------    ? u669485  u669485  %s %s %s/%s\n' "$2" "$3" "$1" "$4" >> "$STUB_STORAGEBOX/$1/.listing"
}

# $1 = path in the PC's NAS repository, $2 = size, $3 = modification time
add_local_file() {
    local file="$pc_nas_repository/$1"
    mkdir -p "$(dirname "$file")"
    head -c "$2" /dev/zero > "$file"
    touch -d "$3" "$file"
}

run_status() {
    bash "$repo_dir/scripts/backup_status.sh" > "$sandbox/output" 2>&1
}

fail_with() {
    echo "      $1"
    sed 's/^/      backup_status.sh | /' "$sandbox/output" 2>/dev/null || true
    return 1
}

# Prints a field of a repository in the status file. $1 = repository name, $2 = jq path, e.g. .size
repository_field() {
    jq -r --arg name "$1" ".repositories[] | select(.name == \$name) | $2" "$status_file"
}

# $1 = repository name, $2 = jq path, $3 = expected value
assert_field() {
    local actual
    actual=$(repository_field "$1" "$2")
    [ "$actual" = "$3" ] || fail_with "$1 $2: expected \"$3\", got \"$actual\""
}

test_counts_the_local_repository_snapshots_and_sums_its_file_sizes() {
    add_local_file config 100 '2026-09-14 12:00'
    add_local_file snapshots/aaa 400 '2026-09-15 10:20'
    add_local_file snapshots/bbb 450 '2026-09-16 11:06'
    add_local_file data/00/pack 5000 '2026-09-16 11:05'
    run_status || fail_with "expected success"
    assert_field "PC → NAS" .snapshots 2
    assert_field "PC → NAS" .size 5950
}

test_reports_the_newest_local_snapshot_time() {
    add_local_file snapshots/newest 400 '2026-09-16T11:06:30+02:00'
    add_local_file snapshots/older 400 '2026-09-15T10:20:00+02:00'
    run_status || fail_with "expected success"
    assert_field "PC → NAS" .last_snapshot "2026-09-16T09:06:30Z"
}

test_a_repository_without_snapshots_has_no_last_snapshot_time() {
    run_status || fail_with "expected success"
    assert_field "PC → NAS" .snapshots 0
    assert_field "PC → NAS" 'has("last_snapshot")' false
}

test_reads_the_nas_share_snapshots_from_their_folder_names() {
    # Newest in winter time: sorting the names would pick the older summer one.
    mkdir -p "$pc_nas_snapshots/GMT+02-2026.10.20-00.00.06" "$pc_nas_snapshots/GMT+01-2026.11.01-00.00.06"
    touch "$pc_nas_snapshots/desktop.ini"
    run_status || fail_with "expected success"
    assert_field "PC → NAS" .nas_snapshots.count 2
    assert_field "PC → NAS" .nas_snapshots.last "2026-10-31T23:00:06Z"
}

test_reads_a_storagebox_repository_from_the_sftp_listing() {
    add_storagebox_file restic/jeancloud/keys 460 "Sep 14 14:43" key
    add_storagebox_file restic/jeancloud/index 9000 "Sep 16 02:38" index1
    add_storagebox_file restic/jeancloud/snapshots 380 "Mar  3  2025" old
    add_storagebox_file restic/jeancloud/snapshots 430 "Sep 16 02:38" new
    add_storagebox_file restic/jeancloud/data/00 17013787 "Sep 14 15:06" pack1
    add_storagebox_file restic/jeancloud/data/ff 19798249 "Sep 16 02:37" pack2
    run_status || fail_with "expected success"
    assert_field "NAS → Storage Box" .snapshots 2
    assert_field "NAS → Storage Box" .size 36822306
    assert_field "NAS → Storage Box" .last_snapshot "2026-09-16T00:38:00Z"
}

test_a_date_without_a_year_still_to_come_is_from_last_year() {
    STUB_NOW=$(TZ="$TIME_ZONE" "$REAL_DATE" -d '2026-01-05 12:00' +%s)
    add_storagebox_file restic/archlinux/snapshots 430 "Dec 20 14:00" before_new_year
    run_status || fail_with "expected success"
    assert_field "PC → Storage Box" .last_snapshot "2025-12-20T13:00:00Z"
}

test_an_unreadable_repository_gets_an_error_and_fails_the_run() {
    add_local_file snapshots/aaa 400 '2026-09-16 11:06'
    add_storagebox_file restic/archlinux/snapshots 430 "Sep 16 11:06" snapshot
    rm -rf "$STUB_STORAGEBOX/restic/jeancloud"
    if run_status; then
        fail_with "expected the run to fail"
    fi
    assert_field "NAS → Storage Box" .error "could not list restic/jeancloud on the Storage Box over SFTP"
    assert_field "PC → NAS" .snapshots 1
    assert_field "PC → Storage Box" .snapshots 1
}

test_writes_a_status_file_readable_by_others_without_a_partial_file() {
    run_status || fail_with "expected success"
    [ "$(stat -c %a "$status_file")" = 644 ] || fail_with "expected mode 644, got $(stat -c %a "$status_file")"
    [ ! -e "$status_file.partial" ] || fail_with "the partial file must be renamed"
    jq -e '.generated | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "$status_file" > /dev/null \
        || fail_with "expected an RFC3339 generated time"
}

test_fails_when_the_nas_repository_is_not_on_the_storagebox() {
    sed -i 's|^RESTIC_REPOSITORY=.*|RESTIC_REPOSITORY=sftp:elsewhere:restic/jeancloud|' "$repo_dir/stacks/backup/.env"
    if run_status; then
        fail_with "expected the run to fail"
    fi
    grep -q 'RESTIC_REPOSITORY .* is not on the Storage Box' "$sandbox/output" || fail_with "expected the reason to be logged"
    [ ! -e "$status_file" ] || fail_with "no status file must be written"
}

run_test "it counts the local repository's snapshots and sums its file sizes" in_sandbox test_counts_the_local_repository_snapshots_and_sums_its_file_sizes
run_test "it reports the time of the newest local snapshot" in_sandbox test_reports_the_newest_local_snapshot_time
run_test "a repository without snapshots has no last snapshot time" in_sandbox test_a_repository_without_snapshots_has_no_last_snapshot_time
run_test "it counts the NAS share snapshots and reads the latest time from their names" in_sandbox test_reads_the_nas_share_snapshots_from_their_folder_names
run_test "it reads a Storage Box repository's count, size and last time from the sftp listing" in_sandbox test_reads_a_storagebox_repository_from_the_sftp_listing
run_test "an sftp date without a year that is still to come is from last year" in_sandbox test_a_date_without_a_year_still_to_come_is_from_last_year
run_test "an unreadable repository gets an error, the others are still described, and the run fails" in_sandbox test_an_unreadable_repository_gets_an_error_and_fails_the_run
run_test "it writes the status file readable by others, never leaving a partial file" in_sandbox test_writes_a_status_file_readable_by_others_without_a_partial_file
run_test "it fails when RESTIC_REPOSITORY is not on the Storage Box" in_sandbox test_fails_when_the_nas_repository_is_not_on_the_storagebox

finish_tests
