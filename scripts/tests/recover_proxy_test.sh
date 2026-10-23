#!/usr/bin/env bash
set -euo pipefail

# Runs the recovery entry point with device checks and host commands isolated from the NAS.
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    mkdir -p "$sandbox/repo/scripts" "$sandbox/bin" "$sandbox/state"
    cp "$SCRIPTS_DIR/lib.sh" "$sandbox/repo/scripts/"
    if [ -f "$SCRIPTS_DIR/recover_proxy.sh" ]; then
        cp "$SCRIPTS_DIR/recover_proxy.sh" "$sandbox/repo/scripts/"
    fi
    export RECOVERY_TEST_STATE="$sandbox/state"
    export RECOVERY_TEST_CALLS="$sandbox/calls"
    : > "$RECOVERY_TEST_CALLS"
    touch "$RECOVERY_TEST_STATE/tun" "$RECOVERY_TEST_STATE/module" "$RECOVERY_TEST_STATE/docker"
    for container in tailscale adguardhome traefik; do
        printf 'proxy %s\n' "$container" > "$RECOVERY_TEST_STATE/$container.identity"
        echo exited > "$RECOVERY_TEST_STATE/$container.status"
    done

    # Only intercept the host device/module checks; all other tests use Bash's real builtin.
    cat > "$sandbox/environment" <<'STUB'
[() {
    if [[ "$*" == '-c /dev/net/tun ]' ]]; then
        builtin test -f "$RECOVERY_TEST_STATE/tun"
    elif [[ "$*" == '! -c /dev/net/tun ]' ]]; then
        builtin test ! -f "$RECOVERY_TEST_STATE/tun"
    elif [[ "$*" == '-d /sys/module/tun ]' ]]; then
        builtin test -f "$RECOVERY_TEST_STATE/module"
    elif [[ "$*" == '! -d /sys/module/tun ]' ]]; then
        builtin test ! -f "$RECOVERY_TEST_STATE/module"
    else
        builtin [ "$@"
    fi
}
STUB
    export BASH_ENV="$sandbox/environment"

    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "$RECOVERY_TEST_CALLS"
case "$1" in
    info) test -f "$RECOVERY_TEST_STATE/docker" ;;
    inspect)
        test "$2" = --format
        container="$4"
        case "$3" in
            *com.docker.compose.project*com.docker.compose.service*)
                cat "$RECOVERY_TEST_STATE/$container.identity" ;;
            '{{.State.Status}}') cat "$RECOVERY_TEST_STATE/$container.status" ;;
            *) echo "unexpected inspect format: $3" >&2; exit 1 ;;
        esac
        ;;
    start)
        test "$#" -eq 2
        test ! -f "$RECOVERY_TEST_STATE/$2.fail"
        if [ ! -f "$RECOVERY_TEST_STATE/$2.stays-stopped" ]; then
            echo running > "$RECOVERY_TEST_STATE/$2.status"
        fi
        ;;
    *) echo "unexpected Docker mutation: $*" >&2; exit 1 ;;
esac
STUB
    cat > "$sandbox/bin/insmod" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'insmod %s\n' "$*" >> "$RECOVERY_TEST_CALLS"
test "$*" = /lib/modules/tun.ko
if [ -f "$RECOVERY_TEST_STATE/loader-fails" ]; then
    echo 'module load failed' >&2
    exit 1
fi
touch "$RECOVERY_TEST_STATE/module" "$RECOVERY_TEST_STATE/tun"
STUB
    cat > "$sandbox/bin/sleep" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'sleep %s\n' "$*" >> "$RECOVERY_TEST_CALLS"
for prerequisite in tun docker; do
    if [ -f "$RECOVERY_TEST_STATE/$prerequisite.late" ]; then
        touch "$RECOVERY_TEST_STATE/$prerequisite"
    fi
done
STUB
    chmod +x "$sandbox/bin/"*
    export PATH="$sandbox/bin:$PATH"
}

in_sandbox() {
    create_sandbox
    "$@"
}

recover() {
    bash "$sandbox/repo/scripts/recover_proxy.sh" > "$sandbox/output" 2>&1
}

assert_starts() {
    grep '^docker start ' "$RECOVERY_TEST_CALLS" > "$sandbox/starts" || true
    printf '%s' "$1" > "$sandbox/expected"
    diff -u "$sandbox/expected" "$sandbox/starts"
}

assert_failure() {
    if recover; then
        echo 'expected recovery to fail'
        return 1
    fi
    grep -qF "$1" "$sandbox/output"
}

test_recovers_in_order() {
    recover
    assert_starts $'docker start tailscale\ndocker start adguardhome\ndocker start traefik\n'
}

test_skips_running_containers() {
    for container in tailscale adguardhome traefik; do
        echo running > "$RECOVERY_TEST_STATE/$container.status"
    done
    recover
    assert_starts ''
    ! grep -q '^insmod ' "$RECOVERY_TEST_CALLS"
    [ ! -s "$sandbox/output" ]
}

test_loads_missing_module() {
    rm "$RECOVERY_TEST_STATE/tun" "$RECOVERY_TEST_STATE/module"
    recover
    [ "$(head -n 1 "$RECOVERY_TEST_CALLS")" = 'insmod /lib/modules/tun.ko' ]
    assert_starts $'docker start tailscale\ndocker start adguardhome\ndocker start traefik\n'
}

test_waits_for_prerequisite() {
    local prerequisite="$1"
    rm "$RECOVERY_TEST_STATE/$prerequisite"
    touch "$RECOVERY_TEST_STATE/$prerequisite.late"
    recover
    grep -q '^sleep 5$' "$RECOVERY_TEST_CALLS"
    assert_starts $'docker start tailscale\ndocker start adguardhome\ndocker start traefik\n'
}

test_times_out() {
    local prerequisite="$1"
    rm "$RECOVERY_TEST_STATE/$prerequisite"
    assert_failure "$2"
    assert_starts ''
    local sleep_count
    sleep_count=$(grep -c '^sleep 5$' "$RECOVERY_TEST_CALLS")
    [ "$sleep_count" -gt 0 ] && [ "$sleep_count" -lt 24 ]
}

test_reports_module_failure() {
    rm "$RECOVERY_TEST_STATE/tun" "$RECOVERY_TEST_STATE/module"
    touch "$RECOVERY_TEST_STATE/loader-fails"
    assert_failure 'module load failed'
    assert_starts ''
}

test_preflights_all_containers() {
    local problem="$1"
    case "$problem" in
        missing) rm "$RECOVERY_TEST_STATE/traefik.identity" ;;
        wrong-project) echo 'other traefik' > "$RECOVERY_TEST_STATE/traefik.identity" ;;
        wrong-service) echo 'proxy other' > "$RECOVERY_TEST_STATE/traefik.identity" ;;
    esac
    assert_failure traefik
    assert_starts ''
}

test_stops_after_failed_start() {
    touch "$RECOVERY_TEST_STATE/tailscale.$1"
    assert_failure tailscale
    assert_starts $'docker start tailscale\n'
}

test_refuses_unsafe_state() {
    echo "$1" > "$RECOVERY_TEST_STATE/tailscale.status"
    assert_failure "$1"
    assert_starts ''
}

test_retries_on_next_run() {
    touch "$RECOVERY_TEST_STATE/adguardhome.fail"
    assert_failure adguardhome
    rm "$RECOVERY_TEST_STATE/adguardhome.fail"
    : > "$RECOVERY_TEST_CALLS"
    recover
    assert_starts $'docker start adguardhome\ndocker start traefik\n'
}

test_accepts_created_container() {
    echo created > "$RECOVERY_TEST_STATE/tailscale.status"
    test_recovers_in_order
}

test_skips_when_locked() {
    exec 8> "$sandbox/repo/.deploy.lock"
    flock -n 8
    recover
    [ ! -s "$RECOVERY_TEST_CALLS" ]
}

run_test 'it starts existing containers in dependency order' in_sandbox test_recovers_in_order
run_test 'it leaves running containers unchanged and stays silent' in_sandbox test_skips_running_containers
run_test 'it loads the missing TUN module before Docker access' in_sandbox test_loads_missing_module
for prerequisite in tun docker; do
    run_test "it waits for late $prerequisite readiness" in_sandbox test_waits_for_prerequisite "$prerequisite"
done
run_test 'it fails with no starts when TUN stays absent' in_sandbox test_times_out tun /dev/net/tun
run_test 'it fails with no starts when Docker stays unavailable' in_sandbox test_times_out docker Docker
run_test 'it reports module loader errors without starting containers' in_sandbox test_reports_module_failure
for problem in missing wrong-project wrong-service; do
    run_test "it preflights every container before starting ($problem)" in_sandbox test_preflights_all_containers "$problem"
done
run_test 'it does not start dependents after a parent start fails' in_sandbox test_stops_after_failed_start fail
run_test 'it verifies the parent actually runs before starting dependents' in_sandbox test_stops_after_failed_start stays-stopped
for status in paused restarting removing dead; do
    run_test "it refuses a container in $status state" in_sandbox test_refuses_unsafe_state "$status"
done
run_test 'it recovers on a later run without restarting the running parent' in_sandbox test_retries_on_next_run
run_test 'it can start an existing created container' in_sandbox test_accepts_created_container
run_test 'it makes no host calls while deployment holds the lock' in_sandbox test_skips_when_locked

finish_tests
