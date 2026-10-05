#!/usr/bin/env bash
set -euo pipefail

# move PROXY_DOMAIN from the proxy env to the common env
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# The dashboard's links now use the proxy addresses, so every stack reads PROXY_DOMAIN, not only
# the proxy one: the key moves to stacks/common.env. Left in stacks/proxy/.env as well, that copy
# would silently win over the common one for the proxy stack.

# shellcheck source=scripts/lib.sh
source scripts/lib.sh

common_env=stacks/common.env
proxy_env=stacks/proxy/.env

if [ ! -f "$common_env" ]; then
    echo "No $common_env on this server: nothing to move."
    exit 0
fi

if grep -q '^PROXY_DOMAIN=' "$common_env"; then
    echo "PROXY_DOMAIN is already in $common_env."
else
    proxy_domain=""
    if [ -f "$proxy_env" ]; then
        proxy_domain=$(env_value "$proxy_env" PROXY_DOMAIN)
    fi
    if [ -z "$proxy_domain" ]; then
        echo "PROXY_DOMAIN is set in neither $common_env nor $proxy_env. Add it with scripts/edit_env.sh common" >&2
        exit 1
    fi
    cp -p "$common_env" "$common_env.previous"
    chmod 600 "$common_env.previous"
    # Appended in place, so the file keeps its owner and its 600 permissions.
    printf '\n# Domain the proxy serves the apps under (https://<app>.<domain>)\nPROXY_DOMAIN=%s\n' "$proxy_domain" >> "$common_env"
    echo "Added PROXY_DOMAIN to $common_env (previous version kept in $common_env.previous)."
fi

if [ -f "$proxy_env" ] && grep -q '^PROXY_DOMAIN=' "$proxy_env"; then
    cp -p "$proxy_env" "$proxy_env.previous"
    chmod 600 "$proxy_env.previous"
    # Also drops the comment line the old .env.example put above the key.
    without_proxy_domain=$(awk '!/^PROXY_DOMAIN=/ && !/^# Domain the routes are served under/' "$proxy_env")
    printf '%s\n' "$without_proxy_domain" > "$proxy_env"
    echo "Removed PROXY_DOMAIN from $proxy_env (previous version kept in $proxy_env.previous)."
fi

