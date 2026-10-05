# homelab

Docker Compose setup for my Synology NAS. `main` is what runs: the NAS pulls it every 5 minutes.

## How a push reaches the NAS

`scripts/deploy.sh` (root, every 5 minutes) fast-forwards the NAS checkout to `origin/main`, then, for what changed
since the last deployed commit (`.last-deployed`):

- first the `*.before.sh` [one-time operations](#one-time-operations) not run yet
- `stacks/<stack>/…` → `scripts/compose.sh <stack> up -d --remove-orphans`, skipped for a stack whose services all sit behind a
  profile (`backup`: nothing to run until asked)
- `config/<name>/…` → `docker restart <name>`
- then the other one-time operations not run yet

A failure leaves the commit unmarked, so the next run retries it and DSM emails the output. A deleted stack is never
torn down automatically: the run prints the `docker compose -p <stack> down` to run. Every run also checks that the
nightly database backup still succeeds (see [Backups](#backups)), and one that ends without an error pings
healthchecks.io (see [Monitoring](#monitoring)).

## Layout

```
stacks/<stack>/compose.yml     one Compose project per folder
stacks/<stack>/.env.example    the stack's variables (absent when it only uses common ones)
stacks/common.env.example      variables shared by every stack
config/<name>/                 files mounted into the container named <name>
operations/                    one-time scripts, see below
scripts/                       deploy and maintenance scripts, tests in scripts/tests/
```

The real `stacks/common.env` and `stacks/<stack>/.env` exist only on the NAS (gitignored, mode 600).

## Rules the scripts rely on

- Run Compose through `scripts/compose.sh <stack> …`: plain `docker compose` doesn't load the env files.
- Every service has a `container_name`, and `config/<name>/` is named after it.
- App data lives in host folders (`${DOCKERCONFDIR}`, `${DOCKERSTORAGEDIR}`), never in the repo or a Docker volume.
- Every `${VAR}` used in a compose file is listed in an `.env.example` (CI checks it; the deploy refuses a stack whose
  `.env` lacks a listed key).
- Images are pinned to exact versions.
- Only `docker-socket-proxy` may mount the Docker socket, and nothing runs privileged (CI checks it; allowlist in
  `scripts/check_stacks.sh`). What needs Docker reads it through that proxy.
- Every service with a writable volume has a `homelab.backup` label saying how its data is backed up (CI checks it;
  see [Backups](#backups)).

## Settings and secrets

Edit them on the NAS, never in git:

```sh
sudo scripts/edit_env.sh <stack>    # or: common
```

It validates the file, keeps the old one as `.previous`, and redeploys what it affects. Single-quote values
containing `$` (password hashes).

## Updates

Renovate opens a pull request per image or GitHub Action update and merges it once CI passes; the NAS deploys it
within 5 minutes. Both Opusline images update together. The Dependency Dashboard issue shows what's pending.

- Never proposed, on purpose: Postgres major versions and Immich's database/cache images (see `renovate.json`).
- CI checks the configuration, not the app: a broken release still deploys.
- To roll back, `git revert`, and in the same commit block the version in `renovate.json`
  (`{"matchPackageNames": ["<image>"], "allowedVersions": "<x.y.z"}`), or Renovate merges it again.

## One-time operations

For commands that must run once on the NAS (fix a database, move a folder), like Laravel's one-time operations:

```sh
scripts/new_operation.sh "reset immich password"             # runs after the stacks are updated
scripts/new_operation.sh --before "create the foo folder"    # runs right after the pull, before any container changes
```

Write the commands (container commands through `scripts/compose.sh <stack> exec -T …`), push. The next deploy runs
it once, as root from the repo root, in file name order: `*.before.sh` operations before the env files are checked
and before any container changes (to prepare a folder or a missing `.env` key), the others after the stacks are
updated. It is then recorded in `.operations-done` and never runs again, even if edited. A failing one blocks the
deploy and is retried. `sudo scripts/run_operations.sh --list` shows what ran.

## Remote access

The `proxy` stack replaces DSM's reverse proxy and DDNS. Traefik serves `<name>.${PROXY_DOMAIN}` over HTTPS with
one wildcard certificate, obtained through OVH's DNS (no port to open for it), on two entrypoints:

| Entrypoint | Reachable from | Routes |
|---|---|---|
| `tailnet` (443) | devices on the tailnet only | `vault` (Vaultwarden), `opusline`, and every other app under its own name: `glance`, `filebrowser`, `dozzle`, `beszel`, `gatus`, `immich`, `seerr`, `sonarr`, `radarr`, `prowlarr`, `qbittorrent`, `tautulli`, `maintainerr`, `notifiarr` |
| `public` (8444, published on the NAS) | the internet, once the router forwards WAN 443 to NAS 8444 | `plex`, `jellyfin` |

Traefik runs in the network namespace of the `tailscale` container, a tailnet node of its own
(`jeancloud-proxy`): its port 443 is not the NAS's, so DSM keeps its own and nothing outside the tailnet reaches it.
Which entrypoint a request came in on decides what it can reach, not the name it asks for: `vault.<domain>` on
the public port is a 404.

DNS records at OVH: a wildcard `*` points to the tailnet address of `jeancloud-proxy` (100.x, from the Tailscale
admin console), so a new `tailnet` route needs no record of its own. `plex` is a DynHost record, which wins over
the wildcard: the `ddns-updater` container keeps it on the home's public address, which the internet provider can
change. `jellyfin`, the other public route, is a CNAME to `plex`, so it follows that address without an updater of
its own.

The dashboard opens every app on its proxy address, and loads covers and thumbnails from there, so it is meant
for a device on the tailnet. Glance itself is not on it: what it fetches (statuses, API data) stays on the LAN
addresses, as do the apps' links to each other. Those addresses (`http://<LAN_IP>:<port>`) keep working, for a
device that is off the tailnet and when the proxy is down. Through the proxy every request
reaches an app from a local address, so an app set to skip its login for local addresses (Sonarr, Radarr,
Prowlarr) asks no password from any device on the tailnet.

`jeancloud-proxy` belongs to one Tailscale account. A device logged in with another account only reaches it once
the node is shared with that account (admin console, the machine's Share menu): the address stays the same.

To add a route: a router and a service in [`config/traefik/routes.yml`](config/traefik/routes.yml), plus a DNS
record for a public one. A router goes on `public` only if `PUBLIC_ROUTERS` in `scripts/check_proxy_routes.sh`
lists it (CI checks it).

Apps bound to their URL need it on the NAS too: `VAULTWARDEN_DOMAIN` (`security`, and `infrastructure` for the
dashboard's link), `APP_URL`, `SESSION_DOMAIN`, `SANCTUM_STATEFUL_DOMAINS` and `TRUSTED_PROXIES` (`opusline`), and
in Plex, Settings > Network > Custom server access URLs (`https://plex.<domain>:443`).

## Sonarr and Radarr settings

Quality profiles and custom formats come from the [TRaSH Guides](https://trash-guides.info), applied by
[Configarr](https://configarr.de). `config/configarr/config.yml` only lists which of the guides' quality profiles
to keep in Sonarr and Radarr; their custom formats and scores are the guides' own.

The `configarr` container runs once and exits:

- when the `media` stack is deployed, and when the deploy restarts it after a change to `config/configarr/`;
- every day from DSM Task Scheduler (`docker start -a configarr`), which brings in the guides' updates. A failed
  run exits non-zero, so DSM emails its output.

What it does to the apps:

- a listed profile and its custom formats are created or brought back to the guides' values: a change made by
  hand in the apps on those is overwritten by the next run;
- every other custom format and quality profile is deleted, the apps' built-in profiles included: the apps only
  hold what the file lists;
- a profile still used by a series or a movie can't be deleted. The run then fails, and stops there: Radarr,
  which comes after Sonarr, is not synced until Sonarr's run passes. Move the series or movies to a listed
  profile and run `sudo docker start -a configarr`;
- naming and quality sizes are left alone.

To see what a change would do before pushing it, on the NAS: put the edited file in a folder and run
`sudo docker run --rm --network host --env-file stacks/media/.env -e DRY_RUN=true -v <folder>:/app/config:ro
ghcr.io/raydak-labs/configarr:<version in stacks/media/compose.yml>`.

## Backups

`scripts/backup_nas.sh` runs every night as root and takes the NAS's own data off the NAS, to the Hetzner Storage Box:

1. `scripts/backup_databases.sh` dumps every database into `${BACKUPDIR}/<date>/` (14 days kept), by label, see below.
2. restic, from `stacks/backup`, backs up the photos, the app data, those dumps, the home folders and this checkout
   (its `.env` files included), minus [`stacks/backup/excludes.txt`](stacks/backup/excludes.txt): live database
   folders, caches and what the apps regenerate. Encrypted with `RESTIC_PASSWORD`.
3. On Sundays, restic forgets old snapshots (7 daily, 4 weekly, 12 monthly), prunes, and reads back a 5% sample.

Movies, TV and torrents are left out: they are re-downloadable and don't fit the Storage Box.

### Database labels

Every service with a writable volume has a `homelab.backup` label. CI fails until a new one has it.

| Label | What `backup_databases.sh` does | Used by |
|---|---|---|
| `postgres` | `pg_dumpall` into `<container>.sql.gz`, kept only if the dump is complete | Immich, Opusline, Prowlarr databases |
| `sqlite` | copies every SQLite file in the container's `${DOCKERCONFDIR}` folders with SQLite's online backup, as the file's owner, under the same relative path, and checks each copy with `PRAGMA quick_check`; skips an app's own dated copies (`name-YYYY-MM-DD`) | Vaultwarden, Sonarr, Radarr, Tautulli, Seerr, Maintainerr, Jellyfin, Beszel |
| `sqlite-unchecked` | like `sqlite`, without the check: for databases only the app's own SQLite build can open fully; the log marks each copy `(not checked)` | Plex |
| `bolt` | stops the container, archives its `${DOCKERCONFDIR}` folders into `<container>.tar.gz`, starts it again (seconds of downtime) | Filebrowser |
| `none` | nothing: plain files restic copies as they are, or data not worth keeping; a comment beside the label says which | everything else with a writable volume |

The job fails if a `sqlite` container holds no SQLite file.

### Noticing a broken backup

Every deploy run checks that both backups succeeded in the last 26 hours: `${BACKUPDIR}/last-success` for the dumps,
`${BACKUPDIR}/offsite-last-success` for restic. When one didn't, or never did, the deploy run fails once, so DSM
emails you, then stays quiet until backups succeed again. It never holds a deploy back.

### Dashboard

Glance's Home page shows the backups under the NAS stats:

- **Backups**: for PC → NAS and PC → Storage Box (the PC backs itself up, from its dotfiles) and NAS → Storage Box,
  the number of snapshots, the age of the last one and the space taken, plus the NAS's snapshots of the PC's share.
  `scripts/backup_status.sh` reads them every hour from the repositories' files, without their passwords (restic
  writes each snapshot as one file when the backup ends), into `${DOCKERCONFDIR}/backup-status/backups.json`, which
  the `backup-status` container serves to Glance. A repository it can't read shows its error in red, and so does
  "Updated" when the hourly task stops.
- **Storage Box**: space used out of the quota, split into data and snapshots, and the Storage Box snapshots, live
  from the Hetzner API.

### Setup

Once, on the NAS, as root:

1. The folders the backup stack mounts (Synology's Docker refuses to start a container whose bind-mounted folder
   doesn't exist, so create `BACKUPDIR` too), then the SSH key for the Storage Box, readable by root only:
   ```sh
   sudo mkdir -p /volume1/docker/appdata/restic/ssh /volume1/docker/appdata/restic/cache /volume1/backup/databases
   sudo chmod 700 /volume1/docker/appdata/restic/ssh /volume1/backup/databases
   sudo ssh-keygen -t ed25519 -N '' -C jeancloud-restic -f /volume1/docker/appdata/restic/ssh/id_ed25519
   ```
2. Add the public key to the Storage Box's `.ssh/authorized_keys` (with SFTP, from a machine that can already log in),
   as the usual one-line OpenSSH key, and in Hetzner Console keep "SSH Support" and "External Reachability" on.
3. `/volume1/docker/appdata/restic/ssh/config` (mode 600; `IdentityFile` is the path inside the container). Port 23:
   the Storage Box only accepts one-line OpenSSH keys there, port 22 wants them in RFC4716 format:
   ```
   Host storagebox
       HostName u000000.your-storagebox.de
       Port 23
       User u000000
       IdentityFile /root/.ssh/id_ed25519
   ```
   Then connect once, which records the host key (DSM has no `ssh-keyscan`) and checks the key login:
   ```sh
   echo 'ls -la' | sudo sftp -b - \
     -F /volume1/docker/appdata/restic/ssh/config \
     -i /volume1/docker/appdata/restic/ssh/id_ed25519 \
     -o StrictHostKeyChecking=accept-new \
     -o UserKnownHostsFile=/volume1/docker/appdata/restic/ssh/known_hosts \
     storagebox
   ```
4. `sudo scripts/edit_env.sh common` (`BACKUPDIR`), then `sudo scripts/edit_env.sh backup` (`RESTIC_REPOSITORY`,
   `RESTIC_PASSWORD`, `HOMESDIR`). Keep `RESTIC_PASSWORD` outside the NAS: Vaultwarden runs on it.
5. Create the repository: `sudo scripts/compose.sh backup run --rm -T restic init`.
6. Task Scheduler: `bash /volume1/docker/homelab/scripts/backup_nas.sh` as root daily at 02:30, email on failure.
   Run it once by hand: the first upload takes hours, and a run still going the next night is skipped.
7. Dashboard: in Hetzner Console, create a Read-only API token in the project holding the Storage Box, then
   `sudo scripts/edit_env.sh infrastructure` (`HETZNER_API_TOKEN`, `HETZNER_STORAGE_BOX_ID`) and
   `sudo scripts/edit_env.sh backup` (the `PC_RESTIC_*` paths). Task Scheduler:
   `bash /volume1/docker/homelab/scripts/backup_status.sh` as root every hour, email on failure.

### Restore

Every restic command runs through the stack, e.g. `sudo scripts/compose.sh backup run --rm -T restic snapshots`.

- Files: mount a folder to restore into, e.g.
  `sudo scripts/compose.sh backup run --rm -T -v /volume1/restore:/restore restic restore latest --target /restore --include /source/appdata/sonarr`.
  Snapshot paths start with `/source/photos`, `/source/appdata`, `/source/databases`, `/source/homes` and
  `/source/homelab`.
- Postgres: restore the dump from `/source/databases/<date>/`, then
  `gunzip -c <file>.sql.gz | sudo docker exec -i <container> psql -U <user> -d postgres`.
- SQLite: stop the container, replace the database file with its copy from `/source/databases/<date>/`, delete its
  `-wal` and `-shm` files, start it. The copies under `/source/appdata` were taken live and may be inconsistent.
- Bolt: stop the container, `sudo tar -xzf <container>.tar.gz -C ${DOCKERCONFDIR}` (it overwrites the folder's
  files), start it.
- Whole NAS lost: on any machine with Docker, run `restic/restic` with the same `.ssh` folder and `RESTIC_PASSWORD`
  (from outside the NAS) and restore `/source` first; this checkout and its `.env` files come back with it.

## Monitoring

Four tools, each for a different question. The first three run in the `infrastructure` stack and are served on the
`tailnet` entrypoint.

| Tool | Answers | How you find out |
|---|---|---|
| Dozzle (`dozzle`) | what is a container logging? | you look |
| Beszel (`beszel`) | how loaded is the NAS, and because of which container? CPU, memory, disk, with history | its own alerts, set in its interface |
| Gatus (`gatus`) | is each app answering? | an email after 3 failed checks, a minute apart, and another when it answers again |
| healthchecks.io | did the deploy and the nightly backup run? | its email when a ping is late |

Dozzle and Beszel read Docker through `docker-socket-proxy`, which only answers reads: no container can be
started, stopped or entered from either. To restart one, `sudo docker restart <name>` on the NAS.

Gatus checks the apps on their LAN addresses, from the NAS. It sees neither the proxy and its certificate nor the
public routes (`plex`, `jellyfin`), and when the NAS is off, so is Gatus. That last case is what healthchecks.io is for:
`deploy.sh` and `backup_nas.sh` ping it when they succeed, and it alerts when the pings stop, whatever the reason.
A ping that can't be sent is logged, and never fails the job.

A new app gets its check in [`config/gatus/config.yaml`](config/gatus/config.yaml).

Glance's Home page shows two things from them: how many of Gatus's checks are up and down, with the failing ones
named, and the containers using the most CPU and memory according to Beszel. Glance reads Beszel as a read-only
Beszel user of its own, which `SHARE_ALL_SYSTEMS` lets see the NAS.

### Monitoring setup

Once, on the NAS:

1. healthchecks.io: create two checks and put their ping URLs in `sudo scripts/edit_env.sh common`.
   - `DEPLOY_HEARTBEAT_URL`: period 5 minutes, grace 15 minutes. The deploy refuses to run without it.
   - `BACKUP_HEARTBEAT_URL`: a cron schedule, the one of the `backup_nas.sh` task (`30 2 * * *`), with a grace above
     the time a backup takes. Without it the backup still runs, then fails.
2. Dozzle's login, a users file only root reads:
   ```sh
   image=$(awk '$1 == "image:" && $2 ~ /^amir20\/dozzle:/ { print $2 }' stacks/infrastructure/compose.yml)
   sudo mkdir -p /volume1/docker/appdata/dozzle
   read -rs password    # type the password, then Enter
   echo "$password" | sudo docker run -i --rm "$image" generate <user> --email <email> --name "<name>" \
     | sudo tee /volume1/docker/appdata/dozzle/users.yml > /dev/null
   sudo chmod 600 /volume1/docker/appdata/dozzle/users.yml
   ```
3. `sudo scripts/edit_env.sh infrastructure`: the mail server Gatus sends through (`GATUS_SMTP_*`, `GATUS_ALERT_TO`)
   and `OPUSLINE_PORT`. Leave `BESZEL_AGENT_KEY` and `BESZEL_AGENT_TOKEN` empty for now.
4. Once the stack runs, open `https://beszel.<domain>` and create the admin account. In the Add System dialog,
   give the NAS a name and `beszel-agent` as Host / IP, keep the port, and copy the public key and the token it
   shows into `sudo scripts/edit_env.sh infrastructure` (`BESZEL_AGENT_KEY`, `BESZEL_AGENT_TOKEN`): the agent
   restarts and the NAS turns green in the hub. Until then the agent can't connect.
5. The dashboard's user in Beszel: open `https://beszel.<domain>/_/` (PocketBase's admin, same login as the
   account of step 4), and in the `users` collection create a record with an email, a password, the role
   `readonly` and Verified turned on. Put both in `sudo scripts/edit_env.sh infrastructure`
   (`BESZEL_GLANCE_EMAIL`, `BESZEL_GLANCE_PASSWORD`).

## Scripts

| Script | Purpose |
|---|---|
| `deploy.sh` | the 5-minute deploy (DSM Task Scheduler, root) |
| `compose.sh <stack> …` | `docker compose` with the stack's env files |
| `edit_env.sh <stack>\|common` | edit settings and secrets on the NAS |
| `new_operation.sh`, `run_operations.sh` | one-time operations (`--before`/`--after`, `--list`, `--mark-all-done`) |
| `premigration_check.sh <stack>` | compare running containers with the compose file before replacing them |
| `cleanup_qbittorrent.sh` | remove orphaned torrents (scheduled; reads its API keys and qBittorrent login from `stacks/media/.env`, `DRY_RUN=1` to simulate) |
| `backup_nas.sh` | nightly: database dumps, then the restic backup to the Storage Box (see Backups) |
| `backup_databases.sh` | the database dumps, by `homelab.backup` label (run by `backup_nas.sh`) |
| `backup_status.sh` | hourly: the backup numbers the dashboard shows (see Backups, Dashboard) |
| `check_backups.sh` | fails once when a backup is over 26 hours old (run by `deploy.sh`) |
| `check_stacks.sh`, `check_proxy_routes.sh`, `check_glance_config.sh` | CI checks, runnable locally |
| `migration_helpers.sh` | helpers used once, for the migration from Portainer |

Tests: `for test_file in scripts/tests/*_test.sh; do bash "$test_file"; done` (needs bash, git, jq, flock, Docker
Compose). CI runs them, the three checks and gitleaks on every push and pull request.

## New server

1. Install Git (Package Center), clone the repo as root (LinuxServer images only run root-owned init scripts).
2. Generate the dashboard login:
   ```sh
   image=$(awk '$1 == "image:" && $2 ~ /^glanceapp\/glance:/ { print $2 }' stacks/infrastructure/compose.yml)
   docker run --rm --entrypoint /app/glance "$image" secret:make                     # GLANCE_SECRET_KEY
   docker run --rm --entrypoint /app/glance "$image" password:hash '<your password>'  # GLANCE_PASSWORD_HASH
   ```
3. `sudo scripts/edit_env.sh common`, then `sudo scripts/edit_env.sh <stack>` for each stack with an `.env.example`.
   The two heartbeat URLs, Dozzle's users file and the mail settings of Gatus come from
   [Monitoring setup](#monitoring-setup), steps 1 to 3.
4. `sudo scripts/deploy.sh` once. It runs every one-time operation: on a rebuilt server whose data already went
   through them, run `sudo scripts/run_operations.sh --mark-all-done` first.
5. Task Scheduler: `bash /volume1/docker/homelab/scripts/deploy.sh` as root every 5 minutes, email on failure.
6. Backups: follow [Backups, Setup](#setup). Until a backup succeeds, the deploy reports it.
7. Sonarr and Radarr settings: Task Scheduler, `docker start -a configarr` as root every day, email on failure.
8. Remote access: see [Remote access](#remote-access). A restored `${DOCKERCONFDIR}/tailscale` keeps the node and
   its address; without it, set a new `TS_AUTHKEY` and point the `vault` and `opusline` DNS records to the new
   address.
9. Beszel: [Monitoring setup](#monitoring-setup), step 4. A restored `${DOCKERCONFDIR}/beszel` keeps the account,
   the key and the token.

## Security

Pushing to `main` (or publishing an image Renovate picks up) deploys as root on the NAS. Keep 2FA on, and protect
`main`:

```sh
gh api -X PUT repos/Androlax2/homelab/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": {"strict": true, "contexts": ["stacks", "glance-config", "scripts", "secrets"]},
  "enforce_admins": true,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

The repo is public: secrets only in the NAS `.env` files, and security reviews are not committed.

## Troubleshooting

- **Deploy says `.env is missing` / `lacks keys`**: `sudo scripts/edit_env.sh <stack>` (or `common`).
- **Deploy says `DEPLOY_HEARTBEAT_URL is not set`**: [Monitoring setup](#monitoring-setup), step 1.
- **Variables empty / "variable is not set"**: Compose was run directly; use `scripts/compose.sh`.
- **`git merge --ff-only` fails**: local edits or a force push. `git status`, then `git reset --hard origin/main`
  (`.env` files are gitignored, so they survive).
- **Glance won't start**: `sudo scripts/compose.sh infrastructure logs glance` names the missing value.
- **`required variable … is missing a value`**: the key must not be empty, the service would break silently
  without it. `sudo scripts/edit_env.sh <stack>`.
- **A route on `tailnet` hangs from one device**: that device is off Tailscale, or logged in with an account the
  proxy node is not shared with (`tailscale status` must list `jeancloud-proxy`).
- **A route answers with DSM's page**: its backend port in `stacks/proxy/.env` is wrong.
- **Vaultwarden sends no mail**: `sudo scripts/compose.sh security logs vaultwarden` shows the mail server's
  answer; the `VAULTWARDEN_SMTP_*` values are in `stacks/security/.env`.
- **Deploy says `Backups: …`**: the nightly `backup_nas.sh` task didn't succeed. Open its last output in Task
  Scheduler, or run `sudo bash scripts/backup_nas.sh` to see which step fails.
