#!/usr/bin/env bash
set -euo pipefail

# Tests scripts/migration_helpers.sh. `docker inspect` is stubbed for the Portainer lookups;
# the quoting test runs the real `docker compose config` (nothing is pulled or started).
#
# Usage: bash scripts/tests/migration_helpers_test.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
source "$SCRIPTS_DIR/tests/lib.sh"

create_sandbox() {
    sandbox=$(mktemp -d)
    trap 'rm -rf "$sandbox"' EXIT
    # shellcheck source=scripts/migration_helpers.sh
    source "$SCRIPTS_DIR/migration_helpers.sh"
}

in_sandbox() {
    create_sandbox
    "$@"
}

# $1 = Portainer's data folder on the host, $2 = the container's working_dir label
stub_docker_inspect() {
    mkdir -p "$sandbox/bin"
    export STUB_DATA_DIR="$1" STUB_WORKING_DIR="$2"
    cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *".Destination"*) echo "$STUB_DATA_DIR" ;;
    *"project.working_dir"*) echo "$STUB_WORKING_DIR" ;;
esac
STUB
    chmod +x "$sandbox/bin/docker"
    export PATH="$sandbox/bin:$PATH"
}

# $1 = expected content (\n escapes expanded), $2 = file
assert_file_content() {
    local expected actual
    expected=$(printf '%b' "$1")
    actual=$(cat "$2")
    if [ "$actual" != "$expected" ]; then
        printf '      expected %s:\n%s\n      actual:\n%s\n' "$2" "$expected" "$actual"
        return 1
    fi
}

test_fill_env_takes_values_in_source_order() {
    printf '# comment\nA=\nB=\n# other\nC=\n' > "$sandbox/example"
    printf 'A=one\nX=ignored\n' > "$sandbox/first.env"
    printf 'A=two\nB=from-second\n' > "$sandbox/second.env"
    fill_env "$sandbox/example" "$sandbox/.env" "$sandbox/first.env" "$sandbox/second.env" 2> "$sandbox/stderr"
    assert_file_content '# comment\nA=one\nB=from-second\n# other\nC=' "$sandbox/.env"
    grep -q 'Left empty (not in the sources): C$' "$sandbox/stderr" || { echo "      expected C to be reported"; return 1; }
}

test_fill_env_writes_an_owner_only_file() {
    printf 'A=\n' > "$sandbox/example"
    printf 'A=secret\n' > "$sandbox/source.env"
    fill_env "$sandbox/example" "$sandbox/.env" "$sandbox/source.env"
    [ "$(stat -c %a "$sandbox/.env")" = "600" ] || { echo "      expected mode 600, got $(stat -c %a "$sandbox/.env")"; return 1; }
}

test_fill_env_never_overwrites() {
    printf 'A=\n' > "$sandbox/example"
    printf 'A=new\n' > "$sandbox/source.env"
    printf 'A=edited by hand\n' > "$sandbox/.env"
    if fill_env "$sandbox/example" "$sandbox/.env" "$sandbox/source.env" 2>/dev/null; then
        echo "      expected a failure"
        return 1
    fi
    assert_file_content 'A=edited by hand' "$sandbox/.env"
}

test_fill_env_fails_on_an_empty_source_path() {
    printf 'A=\n' > "$sandbox/example"
    if fill_env "$sandbox/example" "$sandbox/.env" "" 2>/dev/null; then
        echo "      expected a failure"
        return 1
    fi
    [ ! -e "$sandbox/.env" ] || { echo "      no file should have been written"; return 1; }
}

test_set_env_value_replaces_a_key_single_quoted() {
    printf 'A=old\nB=keep\n' > "$sandbox/.env"
    set_env_value "$sandbox/.env" A '$2a$10$abc/def.ghi'
    assert_file_content "A='\$2a\$10\$abc/def.ghi'\nB=keep" "$sandbox/.env"
}

test_set_env_value_adds_a_missing_key() {
    printf 'A=one\n' > "$sandbox/.env"
    set_env_value "$sandbox/.env" B two
    assert_file_content "A=one\nB='two'" "$sandbox/.env"
}

test_set_env_value_keeps_permissions() {
    printf 'A=one\n' > "$sandbox/.env"
    chmod 600 "$sandbox/.env"
    set_env_value "$sandbox/.env" A two
    [ "$(stat -c %a "$sandbox/.env")" = "600" ] || { echo "      expected mode 600, got $(stat -c %a "$sandbox/.env")"; return 1; }
}

test_set_env_value_reaches_the_container_literally() {
    local project_dir="$sandbox/project" hash='$argon2id$v=19$m=65540,t=3,p=4$c2FsdA$aGFzaA'
    mkdir -p "$project_dir"
    printf 'services:\n  app:\n    image: example/app:1.0\n    env_file: [.env]\n    environment:\n      - INTERPOLATED=${TOKEN}\n' > "$project_dir/compose.yml"
    printf 'TOKEN=\n' > "$project_dir/.env"
    set_env_value "$project_dir/.env" TOKEN "$hash"

    local config_json
    config_json=$(docker compose --project-directory "$project_dir" -f "$project_dir/compose.yml" config --format json 2> "$sandbox/warnings")
    if grep -q 'variable is not set' "$sandbox/warnings"; then
        echo "      compose tried to interpolate part of the value:"
        sed 's/^/        /' "$sandbox/warnings"
        return 1
    fi
    for variable in TOKEN INTERPOLATED; do
        local actual
        # `config` prints a literal $ as $$ (compose-file syntax for a literal $): undo that before comparing.
        actual=$(jq -r --arg v "$variable" '.services.app.environment[$v] | gsub("\\$\\$"; "$")' <<<"$config_json")
        if [ "$actual" != "$hash" ]; then
            printf '      %s reached the container as: %s\n' "$variable" "$actual"
            return 1
        fi
    done
}

test_portainer_env_of_maps_the_stack_folder_to_the_host() {
    stub_docker_inspect "$sandbox/portainer-data" /data/compose/12
    mkdir -p "$sandbox/portainer-data/compose/12"
    touch "$sandbox/portainer-data/compose/12/stack.env"
    [ "$(portainer_env_of sonarr)" = "$sandbox/portainer-data/compose/12/stack.env" ] \
        || { echo "      got: $(portainer_env_of sonarr)"; return 1; }
}

test_portainer_env_of_fails_without_a_stack_env() {
    stub_docker_inspect "$sandbox/portainer-data" /data/compose/12
    if portainer_env_of sonarr 2> "$sandbox/stderr"; then
        echo "      expected a failure"
        return 1
    fi
    grep -q "No stack.env at $sandbox/portainer-data/compose/12/stack.env" "$sandbox/stderr" \
        || { echo "      expected the missing path in the error"; return 1; }
}

run_test "fill_env takes each value from the first source that has it, keeping comments and order" in_sandbox test_fill_env_takes_values_in_source_order
run_test "fill_env writes a file readable by its owner only" in_sandbox test_fill_env_writes_an_owner_only_file
run_test "fill_env never overwrites an existing file" in_sandbox test_fill_env_never_overwrites
run_test "fill_env fails when a source lookup returned nothing" in_sandbox test_fill_env_fails_on_an_empty_source_path
run_test "set_env_value replaces a key with a single-quoted value" in_sandbox test_set_env_value_replaces_a_key_single_quoted
run_test "set_env_value adds a key the file lacks" in_sandbox test_set_env_value_adds_a_missing_key
run_test "set_env_value keeps the file's permissions" in_sandbox test_set_env_value_keeps_permissions
run_test "a value written by set_env_value reaches the container literally, \$ signs included" in_sandbox test_set_env_value_reaches_the_container_literally
run_test "portainer_env_of finds the stack.env Portainer used, on the host" in_sandbox test_portainer_env_of_maps_the_stack_folder_to_the_host
run_test "portainer_env_of fails loudly when the stack.env is missing" in_sandbox test_portainer_env_of_fails_without_a_stack_env

finish_tests
