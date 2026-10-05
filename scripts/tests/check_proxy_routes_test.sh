#!/usr/bin/env bash
set -euo pipefail

# Runs scripts/check_proxy_routes.sh on a fixture repo holding only config/traefik/routes.yml.
#
# Usage: bash scripts/tests/check_proxy_routes_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    repo_dir="$sandbox/repo"
    mkdir -p "$repo_dir/scripts" "$repo_dir/config/traefik"
    cp "$SCRIPTS_DIR/check_proxy_routes.sh" "$repo_dir/scripts/"
}

# $1 = routes.yml content (\n escapes are expanded), or "no-file" to leave the file out,
# $2 = expected result: passes | fails, $3 = text the output must contain
check_routes() {
    local routes="$1" expected_result="$2" expected_text="$3"
    create_sandbox
    if [ "$routes" != "no-file" ]; then
        printf '%b' "$routes" > "$repo_dir/config/traefik/routes.yml"
    fi

    local exit_status=0
    bash "$repo_dir/scripts/check_proxy_routes.sh" > "$sandbox/output" 2>&1 || exit_status=$?

    local failure=""
    if [ "$expected_result" = "passes" ] && [ "$exit_status" -ne 0 ]; then
        failure="expected check_proxy_routes.sh to pass"
    elif [ "$expected_result" = "fails" ] && [ "$exit_status" -eq 0 ]; then
        failure="expected check_proxy_routes.sh to fail"
    elif ! grep -qF "$expected_text" "$sandbox/output"; then
        failure="expected the output to contain: $expected_text"
    fi
    if [ -n "$failure" ]; then
        echo "      $failure"
        sed 's/^/      check_proxy_routes.sh | /' "$sandbox/output"
        return 1
    fi
}

# $1 = router name, $2 = its entryPoints line, without indentation (empty: no such line)
router() {
    local name="$1" entrypoints_line="$2"
    printf '    %s:\\n' "$name"
    if [ -n "$entrypoints_line" ]; then
        printf '      %s\\n' "$entrypoints_line"
    fi
    printf '      rule: Host(`%s.example.com`)\\n      service: %s\\n' "$name" "$name"
}

PUBLIC_REFUSED="on the public entrypoint (allowed only for: plex)"

run_test "it passes private routers on tailnet and plex on public" \
    check_routes "http:\n  routers:\n$(router vault 'entryPoints: [tailnet]')$(router plex 'entryPoints: [public]')" \
    passes "OK    config/traefik/routes.yml"
run_test "it ignores entrypoint names outside the routers" \
    check_routes "http:\n  routers:\n$(router vault 'entryPoints: [tailnet]')  services:\n    public:\n      loadBalancer: {}\n" \
    passes "OK    config/traefik/routes.yml"
run_test "it fails a router on public that is not allowed there" \
    check_routes "http:\n  routers:\n$(router vault 'entryPoints: [public]')" \
    fails "vault: $PUBLIC_REFUSED"
run_test "it fails a router on both entrypoints that is not allowed on public" \
    check_routes "http:\n  routers:\n$(router vault 'entryPoints: [tailnet, public]')" \
    fails "vault: $PUBLIC_REFUSED"
run_test "it fails a TCP router on public that is not allowed there" \
    check_routes "tcp:\n  routers:\n$(router vault 'entryPoints: [public]')" \
    fails "vault: $PUBLIC_REFUSED"
run_test "it fails a public router after an allowed one" \
    check_routes "http:\n  routers:\n$(router plex 'entryPoints: [public]')$(router vault 'entryPoints: [public]')" \
    fails "vault: $PUBLIC_REFUSED"
run_test "it fails a router without an entryPoints line" \
    check_routes "http:\n  routers:\n$(router vault '')" \
    fails "vault: no entryPoints line"
run_test "it fails entryPoints written as a block list, which it cannot read" \
    check_routes "http:\n  routers:\n    vault:\n      entryPoints:\n        - public\n      service: vault\n" \
    fails "vault: entryPoints must be an inline list"
run_test "it fails a file without any router" \
    check_routes "http:\n  services:\n    vault:\n      loadBalancer: {}\n" \
    fails "no router found under a routers: key"
run_test "it fails when the routes file is missing" \
    check_routes no-file \
    fails "the file is missing"

finish_tests
