#!/usr/bin/env bash
set -euo pipefail

# Checks, with the real `docker compose config`, that the stacks refuse an empty value for the
# keys that would break a service silently (${KEY:?...} in the compose files): an empty
# OPUSLINE_PORT sends Opusline's route, or Gatus's check of it, to DSM's page, an empty SMTP
# value stops Vaultwarden from starting or leaves Gatus unable to send an alert, an empty
# SYNAPSE_DB_PASSWORD stops Postgres from creating Synapse's database, an empty Paperless key
# leaves it with a secret key everyone knows, no database or no inbox. Nothing is pulled or started.
#
# Usage: bash scripts/tests/required_env_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(dirname "$SCRIPTS_DIR")"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"
# shellcheck source=scripts/lib.sh
source "$SCRIPTS_DIR/lib.sh"

# Prints the keys of <example_file> with a value compose accepts anywhere, a folder included,
# except <empty_key>, left empty.
# $1 = example file, $2 = key to leave empty (none when empty)
filled_env() {
    local example_file="$1" empty_key="$2" key
    for key in $(env_keys "$example_file"); do
        if [ "$key" = "$empty_key" ]; then
            printf '%s=\n' "$key"
        else
            printf '%s=/check\n' "$key"
        fi
    done
}

# $1 = stack, $2 = key left empty (none when empty), $3 = expected result: accepted | refused
check_stack_config() {
    local stack="$1" empty_key="$2" expected_result="$3"
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    filled_env "$REPO_DIR/stacks/common.env.example" "" > "$sandbox/common.env"
    filled_env "$REPO_DIR/stacks/$stack/.env.example" "$empty_key" > "$sandbox/stack.env"

    local exit_status=0
    stack_config_json "$REPO_DIR" "$stack" "$sandbox/common.env" "$sandbox/stack.env" \
        > /dev/null 2> "$sandbox/errors" || exit_status=$?

    local failure=""
    if [ "$expected_result" = "accepted" ] && [ "$exit_status" -ne 0 ]; then
        failure="expected docker compose to accept stacks/$stack"
    elif [ "$expected_result" = "refused" ] && [ "$exit_status" -eq 0 ]; then
        failure="expected docker compose to refuse stacks/$stack with an empty $empty_key"
    elif [ "$expected_result" = "refused" ] && ! grep -qF "$empty_key" "$sandbox/errors"; then
        failure="expected the refusal to name $empty_key"
    fi
    if [ -n "$failure" ]; then
        echo "      $failure"
        sed 's/^/      docker compose | /' "$sandbox/errors"
        return 1
    fi
}

REQUIRED_KEYS="
proxy OPUSLINE_PORT
proxy CLOUDFLARE_DNS_API_TOKEN
proxy CLOUDFLARE_ZONE_ID
security VAULTWARDEN_SMTP_HOST
security VAULTWARDEN_SMTP_PORT
security VAULTWARDEN_SMTP_SECURITY
security VAULTWARDEN_SMTP_USERNAME
security VAULTWARDEN_SMTP_PASSWORD
security VAULTWARDEN_SMTP_FROM
infrastructure OPUSLINE_PORT
infrastructure GATUS_SMTP_HOST
infrastructure GATUS_SMTP_PORT
infrastructure GATUS_SMTP_FROM
infrastructure GATUS_ALERT_TO
matrix SYNAPSE_DB_PASSWORD
paperless PAPERLESS_SECRET_KEY
paperless PAPERLESS_DB_PASSWORD
paperless PAPERLESS_CONSUME_DIR
"

for stack in proxy security infrastructure matrix paperless; do
    run_test "the $stack stack is accepted when every key has a value" check_stack_config "$stack" "" accepted
done
while read -r stack key; do
    [ -n "$stack" ] || continue
    run_test "the $stack stack is refused with an empty $key" check_stack_config "$stack" "$key" refused
done <<<"$REQUIRED_KEYS"

finish_tests
