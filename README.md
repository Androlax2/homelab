# homelab

Docker Compose setup for my Synology NAS (`jeancloud`). `main` is what runs: the NAS pulls it every 5 minutes.

## Layout

```
stacks/<stack>/compose.yml   one Compose project per domain
stacks/<stack>/.env.example  every variable the stack needs; the real .env only exists on the NAS
config/<name>/               files mounted into the container named <name>
scripts/deploy.sh            pulls main and redeploys what changed (DSM Task Scheduler)
scripts/cleanup_deluge.sh    removes orphaned torrents (DSM Task Scheduler)
```

## How a push reaches the NAS

`scripts/deploy.sh` fast-forwards the NAS checkout to `origin/main`, diffs it against the last deployed commit
(`.last-deployed`), then:

- `stacks/<stack>/…` changed → `docker compose -f stacks/<stack>/compose.yml up -d --remove-orphans`
- `config/<name>/…` changed → `docker restart <name>`

So a folder under `config/` must be named after its container's `container_name`.

- A failed run does not advance `.last-deployed`; the next run retries it.
- A stack removed from the repo is never torn down automatically: the run exits non-zero once and prints the
  `docker compose -p <stack> down` to run.
- Never edit files in the NAS checkout. `git merge --ff-only` refuses to pull over local changes, and deploys stop
  until the checkout is clean again.

## Secrets

None in git. Each stack reads `stacks/<stack>/.env` (gitignored) from its own folder, both for `${VAR}`
interpolation and for `env_file:`. `.env.example` lists the keys.

## NAS setup (one time)

1. Package Center: install Git (Synology "Git Server" or SynoCommunity "Git"). Over SSH, check that
   `git --version`, `docker compose version` and `command -v flock` all work.
2. Clone as root. LinuxServer images only run `/custom-cont-init.d` scripts that are root-owned
   (`config/prowlarr/mods`).
   ```sh
   sudo -i
   git clone https://github.com/Androlax2/homelab.git /volume1/docker/homelab
   ```
3. For each stack, create `stacks/<stack>/.env` from its `.env.example`. Copy the current values from Portainer
   (Stack → Environment variables → Advanced mode). `STACK_ENV_FILE` is no longer used. New keys:
   `WATCHTOWER_NOTIFICATION_URL` (infrastructure), `SONARR_API_KEY` and `RADARR_API_KEY` (media, for
   `cleanup_deluge.sh`). Validate each stack:
   ```sh
   docker compose -f stacks/<stack>/compose.yml config -q
   ```
4. One stack at a time, starting with `infrastructure`: delete it in Portainer (this runs `down`; bind-mounted
   data is untouched), then run `docker compose -f stacks/<stack>/compose.yml up -d`. If you get a container
   name conflict (e.g. `portainer`), run `docker rm -f <name>` first.
5. Run `bash /volume1/docker/homelab/scripts/deploy.sh` once. It writes `.last-deployed`.
6. DSM Task Scheduler → Create → Scheduled Task → User-defined script: user `root`, every 5 minutes, command
   `bash /volume1/docker/homelab/scripts/deploy.sh`. Turn on "Send run details by email" → "only when the script
   terminates abnormally".
7. Point the Deluge cleanup task at the checkout:
   ```sh
   set -a; . /volume1/docker/homelab/stacks/media/.env; set +a; bash /volume1/docker/homelab/scripts/cleanup_deluge.sh
   ```
8. The old copies under `${DOCKERCONFDIR}` (`glance/config`, `glance/assets`, `filebrowser/config`,
   `prowlarr/mods`) are no longer mounted and can be deleted.

Portainer is still useful for looking around. Stacks started from the CLI show up as "Limited" there, which is expected.

## Tests

```sh
bash scripts/tests/deploy_test.sh
```

Runs `deploy.sh` against a throwaway git remote, with `docker` stubbed out.
