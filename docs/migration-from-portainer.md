# Migrating the NAS from Portainer to this repo

One-time procedure for the Synology NAS. Before: each stack was pasted into Portainer's web editor, with its
environment variables stored in Portainer. After: the NAS runs a clone of this repo and `scripts/deploy.sh`
keeps it in sync with `main`.

Nothing here deletes data. Every stack uses bind mounts, and removing a container never removes a host folder.
The real risks are:

- environment values that only exist in Portainer (deleting a stack there deletes them),
- a wrong path in the new env files (the app starts on an empty folder and looks empty),
- config files on the NAS that are newer than the repo's,
- apps being updated or files deleted by scheduled jobs in the middle of the migration,
- a database stopped too abruptly.

Each step below covers one of them.

## 0. Prerequisites

- Package Center: install Git (Synology "Git Server" or SynoCommunity "Git").
- Over SSH, as root (`sudo -i`), check: `git --version`, `docker compose version`, `jq --version`,
  `command -v flock`.

## 1. Safety net

Do all of this before changing anything.

1. Pause what changes things on its own:
   - `docker stop watchtower`. Watchtower is no longer in the repo and disappears with the infrastructure stack.
   - Disable the Deluge cleanup task in Task Scheduler.
2. Snapshot the shared folder that holds `DOCKERCONFDIR` (Snapshot Replication, Btrfs volumes only). Snapshots
   protect against mistakes, not against a disk failure.
3. Record what runs now. The file contains secrets: keep it root-only and delete it at the end.
   ```sh
   docker inspect $(docker ps -aq) > /root/pre-migration-inspect.json && chmod 600 /root/pre-migration-inspect.json
   ```
4. Copy Portainer's stack files (compose file and env for each stack), which should be under
   `${DOCKERCONFDIR}/portainer/compose/<id>/`, to a safe place. They are the rollback path.
5. Dump the databases that matter, to a folder outside the docker share:
   ```sh
   docker exec immich_postgres pg_dumpall --clean --if-exists -U immich | gzip > /volume1/backup/immich.sql.gz
   docker exec opusline-db pg_dump -U opusline opusline | gzip > /volume1/backup/opusline.sql.gz
   ```
6. Export the Vaultwarden vault from its web UI.

## 2. Clone the repo and write the shared values

As root, so the prowlarr init script in `config/prowlarr/mods` is root-owned (LinuxServer images skip it
otherwise):

```sh
git clone https://github.com/Androlax2/homelab.git /volume1/docker/homelab
cd /volume1/docker/homelab
cp stacks/common.env.example stacks/common.env && chmod 600 stacks/common.env
vi stacks/common.env    # the same folders, time zone, user and LAN IP as in any Portainer stack today
```

Don't use `edit_env.sh` during the migration: it redeploys right away, while Portainer still owns the containers.

## 3. Migrate one stack at a time

Order: infrastructure, portainer, media, opusline, photos, security.

1. If the stack has an `.env.example` (all but portainer), create its `.env` with only the keys listed there;
   the server-wide ones are already in `stacks/common.env`. Copy the values from Portainer (Stacks → the stack →
   Environment variables → Advanced mode), fill in the new keys from [Stack notes](#stack-notes), and single-quote
   any value containing `$`.
   ```sh
   cp stacks/<stack>/.env.example stacks/<stack>/.env && chmod 600 stacks/<stack>/.env
   vi stacks/<stack>/.env
   scripts/compose.sh <stack> config -q
   ```
   The last command must print nothing. On the first stack it also proves the NAS's Compose accepts two
   `--env-file` flags; if it rejects the flag, update Container Manager before going further.
2. If the stack mounts files from `config/`, compare them with what the NAS uses now, and commit any NAS-side
   change to the repo first:
   ```sh
   diff -r "$DOCKERCONFDIR/glance/config" config/glance/config
   ```
3. Compare the running containers with what the repo would create:
   ```sh
   scripts/premigration_check.sh <stack>
   ```
   Expected output:
   - `(expected)` lines for mounts moving into `config/`;
   - `(check)` lines for image changes. The running version must not be newer than the pinned one: that would be
     a downgrade, so stop and bump the pin;
   - `env dropped:` for values that no longer reach the container on purpose: `STACK_ENV_FILE` everywhere,
     `PUID`/`PGID` on `immich_*`, `prowlarr-postgres` and `seerr` (those images ignored them), the server-wide keys
     on the opusline containers, and on `glance` every key that isn't in `stacks/common.env` or its own `.env`
     any more (`SYNOLOGY_NAS_PASSWORD`, `TAILSCALE_AUTHKEY`…);
   - `env new: GLANCE_…` on `glance`.

   Anything else is a real difference to understand before going further.
4. Stop the databases with a generous timeout, then the stack in Portainer:
   ```sh
   docker stop -t 120 immich_postgres prowlarr-postgres opusline-db vaultwarden   # the ones in this stack
   ```
5. Take a second snapshot (consistent now that nothing writes).
6. Delete the stack in Portainer, then start it from the repo:
   ```sh
   scripts/compose.sh <stack> up -d
   scripts/compose.sh <stack> logs -f
   ```
   If Postgres prints `initdb` or "The files belonging to this database system will be owned by…", it is on an
   empty folder: `scripts/compose.sh <stack> down` right away and fix the path. The real data was not touched.
7. Open the app and check that it has its data.

### Stack notes

- **infrastructure**
  - New keys `GLANCE_SECRET_KEY`, `GLANCE_USERNAME`, `GLANCE_PASSWORD_HASH`: generate them before starting the
    stack (README, "Dashboard login"). Glance refuses to start without them.
  - New key `FILEBROWSER_ROOT` (previously hardcoded to `/volume1/docker/appdata`, which exposed every app's
    database and secrets). Pick the narrowest folder you actually browse.
  - New container `docker-socket-proxy`: Glance reads the container list through it instead of holding the Docker
    socket.
  - Watchtower is gone.
- **portainer**
  - No `.env` any more: everything it needs is in `stacks/common.env`.
  - Port 9000 (plain HTTP) is gone: use `https://<LAN_IP>:9443`.
  - Portainer cannot delete its own stack. Run `docker rm -f portainer`, then start it from the repo.
- **media**
  - New keys `SONARR_API_KEY` and `RADARR_API_KEY`, read by `cleanup_deluge.sh`.
  - `prowlarr-postgres` now only listens on localhost. Before starting, check that `PostgresHost` in
    `${DOCKERCONFDIR}/prowlarr/config.xml` is `localhost` or `127.0.0.1`; change it while Prowlarr is stopped
    otherwise.
  - Sonarr and Radarr now come from `lscr.io` (the same images as on Docker Hub).
  - After the start, the prowlarr log should show `[CustomDefs]`.
- **security**
  - New key `VAULTWARDEN_DOMAIN` (previously `https://jeancloud:8443`).
  - Once Vaultwarden runs, replace the plain admin token with an Argon2 hash: `docker exec -it vaultwarden
    /vaultwarden hash`, then put the result, single-quoted, in `stacks/security/.env` (`scripts/edit_env.sh
    security` once the migration is over).
  - Port 3012 is gone: if the DSM reverse proxy has a rule sending `/notifications/hub` to 3012, delete it. The main
    rule to 8580, with the WebSocket headers enabled, carries live sync.
  - Optional hardening, depending on the reverse proxy: if it forwards to `localhost:8580`, change the port line in
    `stacks/security/compose.yml` to `"127.0.0.1:8580:80"` so Vaultwarden is no longer reachable in plain HTTP from
    the LAN, and point the Glance monitor (`config/glance/config/widgets/services-monitor.yml`) at the public URL.
- **opusline**
  - `OPUSLINE_VERSION` is now required: set it to the version running today (the `(check)` line of the
    premigration check shows it).
- **photos**: no new key.

## 4. Turn on automatic deploys

Only once every stack is migrated.

1. `bash /volume1/docker/homelab/scripts/deploy.sh`. The first run treats everything as changed (a no-op for
   what already runs) and writes `.last-deployed`.
2. Task Scheduler → Create → Scheduled Task → User-defined script: user `root`, every 5 minutes, command
   `bash /volume1/docker/homelab/scripts/deploy.sh`. In Settings, send run details by email only when the script
   terminates abnormally.
3. Point the Deluge cleanup task at the checkout and re-enable it:
   ```sh
   set -a; . /volume1/docker/homelab/stacks/media/.env; set +a; bash /volume1/docker/homelab/scripts/cleanup_deluge.sh
   ```
4. Protect `main` on GitHub (README, "Security").
5. Delete `/root/pre-migration-inspect.json`. Later, once everything has run for a while, delete the old copies
   under `${DOCKERCONFDIR}`: `glance/config`, `glance/assets`, `filebrowser/config`, `prowlarr/mods`.

## Rollback (one stack)

`scripts/compose.sh <stack> down`, re-create the stack in Portainer from the files saved in step 1.4, and restore
the snapshot only if an app wrote bad data.
