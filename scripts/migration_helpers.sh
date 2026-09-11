# Helpers for docs/migration-from-portainer.md. Source it from the repo root, in a root bash shell:
#   source scripts/migration_helpers.sh
# None of them touches a container: they read Portainer's files and write env files.

# Host folder mounted as Portainer's /data, read from the running portainer container.
portainer_data_dir() {
    docker inspect portainer --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}'
}

# Name of the Portainer stack (Compose project) that started <container>.
portainer_stack_of() {
    docker inspect "$1" --format '{{index .Config.Labels "com.docker.compose.project"}}'
}

# Host path of the stack.env Portainer used when it started <container>.
portainer_env_of() {
    local container="$1" working_dir data_dir env_file
    working_dir=$(docker inspect "$container" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}') || return 1
    data_dir=$(portainer_data_dir) || return 1
    if [ -z "$working_dir" ] || [ -z "$data_dir" ]; then
        echo "Cannot tell which Portainer stack started $container" >&2
        return 1
    fi
    # Portainer runs Compose inside its own container, where its data folder is /data.
    env_file="$data_dir${working_dir#/data}/stack.env"
    if [ ! -f "$env_file" ]; then
        echo "No stack.env at $env_file" >&2
        return 1
    fi
    echo "$env_file"
}

# Writes <env_file> from <example_file>, keeping its comments and order. Each key takes its
# value from the first <source_file> that defines it; keys no source defines stay empty and
# are listed on stderr. The new file is readable by its owner only. Never overwrites a file.
# Usage: fill_env <example_file> <env_file> <source_file>...
fill_env() {
    local example_file="$1" env_file="$2"
    shift 2
    if [ -e "$env_file" ]; then
        echo "$env_file already exists; delete it first to regenerate it" >&2
        return 1
    fi
    if [ $# -eq 0 ]; then
        echo "Usage: fill_env <example_file> <env_file> <source_file>..." >&2
        return 1
    fi
    local source_file
    for source_file in "$@"; do
        if [ ! -f "$source_file" ]; then
            echo "No such source file: '$source_file'" >&2
            return 1
        fi
    done
    (
        umask 077
        awk -v example="$example_file" '
            function key_of(line) { return substr(line, 1, index(line, "=") - 1) }
            FILENAME != example {
                if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/ && !(key_of($0) in values)) {
                    values[key_of($0)] = substr($0, index($0, "=") + 1)
                }
                next
            }
            /^[A-Za-z_][A-Za-z0-9_]*=/ {
                key = key_of($0)
                if (key in values) {
                    print key "=" values[key]
                } else {
                    print
                    missing = missing " " key
                }
                next
            }
            { print }
            END { if (missing != "") print "Left empty (not in the sources):" missing > "/dev/stderr" }
        ' "$@" "$example_file" > "$env_file"
    )
}

# Sets <key> to <value> in <env_file>, single-quoted so Compose reads it literally, $ signs
# included. Adds the key if the file lacks it. Keeps the file's permissions.
# Usage: set_env_value <env_file> <key> <value>
set_env_value() {
    local env_file="$1" key="$2" value="$3" updated
    if [ ! -f "$env_file" ]; then
        echo "No such file: $env_file" >&2
        return 1
    fi
    case "$value" in
        *"'"*)
            echo "The value contains a single quote, which can't be written single-quoted: edit $env_file by hand" >&2
            return 1
            ;;
    esac
    updated=$(KEY="$key" VALUE="$value" awk '
        BEGIN { key = ENVIRON["KEY"]; line = key "='\''" ENVIRON["VALUE"] "'\''" }
        index($0, key "=") == 1 { print line; is_set = 1; next }
        { print }
        END { if (!is_set) print line }
    ' "$env_file") || return 1
    printf '%s\n' "$updated" > "$env_file"
}
