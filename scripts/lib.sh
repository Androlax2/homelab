# Helpers shared by the scripts in this folder. Source it, don't run it.

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Values the homelab.backup label accepts, i.e. how scripts/backup_databases.sh backs a service up.
# scripts/check_stacks.sh requires the label on every service with a writable volume.
BACKUP_KINDS="postgres sqlite sqlite-unchecked bolt none"

# Asks for an API key (hidden input) unless the variable already holds one, then exports it.
# $1 = variable name, $2 = what the key is for
ask_api_key() {
    if [ -z "${!1:-}" ]; then
        read -rsp "$2 API key: " "${1?}"
        echo
    fi
    export "${1?}"
}

# Prints the value of <key> in a dotenv file without its surrounding quotes, or nothing if absent.
# $1 = file, $2 = key
env_value() {
    sed -n "s/^$2=//p" "$1" | tail -n 1 | sed -E "s/^'(.*)'\$/\\1/; s/^\"(.*)\"\$/\\1/"
}

# Prints the value of <key> in <file>, or logs how to set it and fails when it is empty or absent.
# $1 = file, $2 = key, $3 = what to pass to scripts/edit_env.sh to set it
required_env_value() {
    local value=""
    if [ -f "$1" ]; then
        value=$(env_value "$1" "$2")
    fi
    if [ -z "$value" ]; then
        log "ERROR: $2 is not set in $1. Add it with scripts/edit_env.sh $3" >&2
        return 1
    fi
    printf '%s\n' "$value"
}

# Brings <stack> up with scripts/compose.sh, unless none of its services runs by default: when all
# of them are behind a profile (like the backup's restic, only run on demand), there is nothing to
# bring up, and `compose up` would fail with "no service selected".
# $1 = repo dir, $2 = stack
compose_up_stack() {
    local repo_dir="$1" stack="$2" services
    services=$("$repo_dir/scripts/compose.sh" "$stack" config --services)
    if [ -z "$services" ]; then
        log "Stack $stack: all its services are behind a profile, nothing to bring up"
        return 0
    fi
    "$repo_dir/scripts/compose.sh" "$stack" up -d --remove-orphans
}

# Prints the keys a dotenv file defines, one per line, sorted.
env_keys() {
    sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$1" | sort -u
}

# Prints the keys listed in <example_file> that <env_file> does not define.
missing_env_keys() {
    local example_file="$1" env_file="$2"
    comm -23 <(env_keys "$example_file") <(env_keys "$env_file")
}

# Prints the resolved config of <stack> as JSON, with <common_env> and <stack_env> standing
# in for stacks/common.env and stacks/<stack>/.env: the real files are never read.
# Compose's warnings ("variable is not set"...) go to stderr.
stack_config_json() {
    local repo_dir="$1" stack="$2" common_env="$3" stack_env="$4"
    local mirror_dir status=0
    mirror_dir=$(mktemp -d)
    mkdir -p "$mirror_dir/stacks/$stack"
    cp "$common_env" "$mirror_dir/stacks/common.env"
    cp "$stack_env" "$mirror_dir/stacks/$stack/.env"
    # The mirror keeps the repo layout, so relative env_file paths (.env, ../common.env) resolve inside it.
    # --profile '*': without it, services behind a profile (like the backup's restic) are left out of the output.
    docker compose \
        --env-file "$mirror_dir/stacks/common.env" \
        --env-file "$mirror_dir/stacks/$stack/.env" \
        -f "$repo_dir/stacks/$stack/compose.yml" \
        --project-directory "$mirror_dir/stacks/$stack" \
        -p "$stack" \
        --profile '*' \
        config --format json || status=$?
    rm -rf "$mirror_dir"
    return "$status"
}
