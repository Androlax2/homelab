#!/usr/bin/env bash
set -euo pipefail

# DSM runs this as root at boot and every five minutes, independently of Git/DNS.
PATH="$PATH:/usr/local/bin"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

# Share the deploy lock so a scheduled recovery cannot race container recreation.
exec 9>"$REPO_DIR/.deploy.lock"
if ! flock -n 9; then
    log "Deployment or proxy recovery is still running, skipping."
    exit 0
fi

if [ ! -c /dev/net/tun ] && [ ! -d /sys/module/tun ]; then
    log "Proxy recovery: loading DSM's TUN module."
    if ! insmod /lib/modules/tun.ko; then
        log "ERROR: Could not load /lib/modules/tun.ko; check DSM's TUN setup."
        exit 1
    fi
fi

for ((attempt = 1; attempt <= 24; attempt++)); do
    if [ -c /dev/net/tun ] && docker info > /dev/null 2>&1; then
        break
    fi
    if [ "$attempt" -eq 24 ]; then
        if [ ! -c /dev/net/tun ]; then
            log "ERROR: /dev/net/tun is not a character device; check DSM's TUN setup."
        else
            log "ERROR: Docker is not ready; check Synology Container Manager."
            docker info > /dev/null
        fi
        exit 1
    fi
    sleep 5
done

# Check every identity before starting anything; a missing stack needs a deliberate deploy.
for container in tailscale adguardhome traefik; do
    if ! identity=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}} {{index .Config.Labels "com.docker.compose.service"}}' "$container"); then
        log "ERROR: Cannot inspect $container; restore the existing proxy stack before enabling recovery."
        exit 1
    fi
    if [ "$identity" != "proxy $container" ]; then
        log "ERROR: $container is not the expected proxy/$container Compose service; refusing to start it."
        exit 1
    fi
done

for container in tailscale adguardhome traefik; do
    if ! status=$(docker inspect --format '{{.State.Status}}' "$container"); then
        log "ERROR: Cannot inspect the state of $container."
        exit 1
    fi
    case "$status" in
        running) continue ;;
        exited|created) ;;
        *)
            log "ERROR: $container is in $status state; refusing to interfere."
            exit 1
            ;;
    esac

    log "Proxy recovery: starting $container."
    if ! docker start "$container" > /dev/null; then
        log "ERROR: Could not start $container; no further proxy containers were started."
        exit 1
    fi
    if ! status=$(docker inspect --format '{{.State.Status}}' "$container"); then
        log "ERROR: Cannot verify the state of $container after starting it."
        exit 1
    fi
    if [ "$status" != running ]; then
        log "ERROR: $container is $status after starting; no further proxy containers were started."
        exit 1
    fi
done
