# homelab

Docker Compose setup for my Synology NAS. `main` is what runs: the NAS pulls it every 5 minutes.

## How a push reaches the NAS

`scripts/deploy.sh` (root, every 5 minutes) fast-forwards the NAS checkout to `origin/main`, then, for what changed
since the last deployed commit (`.last-deployed`):

- `stacks/<stack>/…` → `scripts/compose.sh <stack> up -d --remove-orphans`
- `config/<name>/…` → `docker restart <name>`
- then the [one-time operations](#one-time-operations) not run yet

A failure leaves the commit unmarked, so the next run retries it and DSM emails the output. A deleted stack is never
torn down automatically: the run prints the `docker compose -p <stack> down` to run.

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
- Only `portainer` and `docker-socket-proxy` may mount the Docker socket, and nothing runs privileged (CI checks it;
  allowlist in `scripts/check_stacks.sh`).

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
scripts/new_operation.sh "reset immich password"    # creates operations/<timestamp>_reset_immich_password.sh
```

Write the commands (container commands through `scripts/compose.sh <stack> exec -T …`), push. After the next deploy
has updated the stacks, the NAS runs it as root from the repo root, in file name order, and records it in
`.operations-done`. It never runs again, even if edited. A failing one blocks the deploy and is retried.
`sudo scripts/run_operations.sh --list` shows what ran.

## Sonarr and Radarr settings

Quality profiles and custom formats live in `config/recyclarr/`: profiles and scores in `configs/instances.yml`,
each custom format as a JSON file in `custom-formats/<service>/`. The `recyclarr` container (media stack) pushes them
into Sonarr and Radarr every night, overwriting UI changes to what it manages.

- `scripts/preview_recyclarr.sh` (your computer) shows what a sync of the repo's files would change. Run it before
  pushing a change, and push only when it shows what you expect.
- `scripts/export_arr_settings.sh` (your computer) copies the apps' current profiles and custom formats into those
  files, then runs the preview. Naming isn't copied: Recyclarr only accepts the TRaSH Guides' naming presets.

## Backups

- `scripts/backup_databases.sh <folder>`, nightly as root: consistent dumps of the Postgres databases (Immich,
  Opusline, Prowlarr) and of Vaultwarden into `<folder>/<date>/`, 14 days kept. The other apps write their own
  backups into their config folders.
- Hyper Backup then copies the docker share (app data, and this checkout with its `.env` files) and that folder off
  the NAS, with client-side encryption. Keep its encryption key outside the NAS: Vaultwarden runs on it.
- Restore a Postgres dump: `gunzip -c <file>.sql.gz | sudo docker exec -i <container> psql -U <user> -d postgres`.
  Vaultwarden: stop it, replace `db.sqlite3` in its data folder with the copy (delete `db.sqlite3-wal` and
  `db.sqlite3-shm`), start it.

## Scripts

| Script | Purpose |
|---|---|
| `deploy.sh` | the 5-minute deploy (DSM Task Scheduler, root) |
| `compose.sh <stack> …` | `docker compose` with the stack's env files |
| `edit_env.sh <stack>\|common` | edit settings and secrets on the NAS |
| `new_operation.sh`, `run_operations.sh` | one-time operations (`--list`, `--mark-all-done`) |
| `premigration_check.sh <stack>` | compare running containers with the compose file before replacing them |
| `cleanup_deluge.sh` | remove orphaned torrents (scheduled; reads its API keys from `stacks/media/.env`, `DRY_RUN=1` to simulate) |
| `backup_databases.sh <folder>` | nightly database dumps (see Backups) |
| `export_arr_settings.sh`, `preview_recyclarr.sh` | copy Sonarr/Radarr settings into the repo, preview a sync (your computer) |
| `check_stacks.sh`, `check_glance_config.sh` | CI checks, runnable locally |
| `migration_helpers.sh` | helpers used once, for the migration from Portainer |

Tests: `for test_file in scripts/tests/*_test.sh; do bash "$test_file"; done` (needs bash, git, jq, flock, Docker
Compose). CI runs them, the two checks and gitleaks on every push and pull request.

## New server

1. Install Git (Package Center), clone the repo as root (LinuxServer images only run root-owned init scripts).
2. Generate the dashboard login:
   ```sh
   image=$(awk '$1 == "image:" && $2 ~ /^glanceapp\/glance:/ { print $2 }' stacks/infrastructure/compose.yml)
   docker run --rm --entrypoint /app/glance "$image" secret:make                     # GLANCE_SECRET_KEY
   docker run --rm --entrypoint /app/glance "$image" password:hash '<your password>'  # GLANCE_PASSWORD_HASH
   ```
3. `sudo scripts/edit_env.sh common`, then `sudo scripts/edit_env.sh <stack>` for each stack with an `.env.example`.
4. `sudo scripts/deploy.sh` once. It runs every one-time operation: on a rebuilt server whose data already went
   through them, run `sudo scripts/run_operations.sh --mark-all-done` first.
5. Task Scheduler: `bash /volume1/docker/homelab/scripts/deploy.sh` as root every 5 minutes, email on failure.
6. Task Scheduler: `bash /volume1/docker/homelab/scripts/backup_databases.sh <folder>` as root nightly, email on
   failure; then a Hyper Backup task (see Backups) scheduled after it.

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
- **Variables empty / "variable is not set"**: Compose was run directly; use `scripts/compose.sh`.
- **`git merge --ff-only` fails**: local edits or a force push. `git status`, then `git reset --hard origin/main`
  (`.env` files are gitignored, so they survive).
- **Glance won't start**: `sudo scripts/compose.sh infrastructure logs glance` names the missing value.
