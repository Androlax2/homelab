# Helpers shared by the scripts in this folder. Source it, don't run it.

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

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
    docker compose \
        --env-file "$mirror_dir/stacks/common.env" \
        --env-file "$mirror_dir/stacks/$stack/.env" \
        -f "$repo_dir/stacks/$stack/compose.yml" \
        --project-directory "$mirror_dir/stacks/$stack" \
        -p "$stack" \
        config --format json || status=$?
    rm -rf "$mirror_dir"
    return "$status"
}
