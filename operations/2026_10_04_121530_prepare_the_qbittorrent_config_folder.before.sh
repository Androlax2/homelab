#!/usr/bin/env bash
set -euo pipefail

# prepare the qbittorrent config folder
#
# Runs once on each server, as root, from the repo root, right after the pull, before any container changes.
# Exit non-zero to stop the deploy: this operation then runs again on the next deploy.
# Once it has succeeded it never runs again, even if this file changes.
#
# Synology's Docker refuses to start a container whose bind-mounted folder doesn't exist, and
# the qbittorrent container needs an OpenVPN profile in its config folder to connect: it starts
# with a copy of deluge's, so on the same VPN endpoint.

set -a
# shellcheck source=/dev/null
. stacks/common.env
set +a

deluge_openvpn_dir="$DOCKERCONFDIR/deluge/openvpn"
qbittorrent_openvpn_dir="$DOCKERCONFDIR/qbittorrent/openvpn"

if ! ls "$deluge_openvpn_dir"/*.ovpn > /dev/null 2>&1; then
    echo "No .ovpn file in $deluge_openvpn_dir: nothing to give qbittorrent to connect with." >&2
    exit 1
fi

mkdir -p "$qbittorrent_openvpn_dir"
cp -a "$deluge_openvpn_dir/." "$qbittorrent_openvpn_dir/"
chown -R "$PUID:$PGID" "$DOCKERCONFDIR/qbittorrent"
echo "$DOCKERCONFDIR/qbittorrent is ready, with deluge's OpenVPN profile."
