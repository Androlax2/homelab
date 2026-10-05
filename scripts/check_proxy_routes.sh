#!/usr/bin/env bash
set -euo pipefail

# Validates config/traefik/routes.yml: Traefik's `public` entrypoint is reachable from the
# internet, `tailnet` from the tailnet only.
#   - only the routers in PUBLIC_ROUTERS may be on `public`
#   - every router names its entrypoints, as an inline list, so this check can read them
#
# Usage: bash scripts/check_proxy_routes.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTES_FILE="config/traefik/routes.yml"

PUBLIC_ROUTERS="plex jellyfin"

# Prints one line per router that breaks the rules above. Reads the file by indentation:
# `routers:` under a top-level key (http, tcp, udp), router names below it, their keys below those.
route_violations() {
    awk -v allowed="$PUBLIC_ROUTERS" '
        function close_router() {
            if (router != "" && !has_entrypoints) {
                print router ": no entryPoints line"
            }
            router = ""
        }
        BEGIN {
            split(allowed, allowed_names, " ")
            for (i in allowed_names) is_allowed[allowed_names[i]] = 1
        }
        /^[[:space:]]*(#|$)/ { next }
        /^  routers:[[:space:]]*$/ { close_router(); in_routers = 1; next }
        in_routers && /^ ? ? ?[^ ]/ { close_router(); in_routers = 0 }
        !in_routers { next }
        /^    [^ ]/ {
            close_router()
            router_count++
            if ($0 !~ /^    [A-Za-z0-9_-]+:[[:space:]]*$/) {
                print "unreadable router line: " $0
                next
            }
            router = $1
            sub(/:$/, "", router)
            has_entrypoints = 0
            next
        }
        router != "" && /^      entryPoints:/ {
            has_entrypoints = 1
            if ($0 !~ /^      entryPoints: \[[A-Za-z0-9_, -]+\][[:space:]]*$/) {
                print router ": entryPoints must be an inline list, like entryPoints: [tailnet]"
                next
            }
            entrypoints = $0
            sub(/^[^[]*\[/, "", entrypoints)
            sub(/\].*$/, "", entrypoints)
            entrypoint_count = split(entrypoints, entrypoint_names, /[, ]+/)
            for (i = 1; i <= entrypoint_count; i++) {
                if (entrypoint_names[i] == "public" && !(router in is_allowed)) {
                    print router ": on the public entrypoint (allowed only for: " allowed ")"
                }
            }
        }
        END {
            close_router()
            if (router_count == 0) print "no router found under a routers: key"
        }
    ' "$1"
}

if [ ! -f "$REPO_DIR/$ROUTES_FILE" ]; then
    echo "FAIL  $ROUTES_FILE"
    echo "      the file is missing"
    exit 1
fi

problems=$(route_violations "$REPO_DIR/$ROUTES_FILE")
if [ -n "$problems" ]; then
    echo "FAIL  $ROUTES_FILE"
    sed 's/^/      /' <<<"$problems"
    exit 1
fi
echo "OK    $ROUTES_FILE"
