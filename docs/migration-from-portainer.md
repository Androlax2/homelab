# Migrating the NAS from Portainer to this repo

A one-time runbook. Follow it from top to bottom. Every command block is meant to be pasted as is into the NAS's
root shell, except the few values written `<like this>`, which you replace with your own.

**What changes.** Today each stack is pasted into Portainer's web editor and its variables live in Portainer.
Afterwards the NAS runs a clone of this repo, the variables live in `stacks/common.env` and `stacks/<stack>/.env`,
and `scripts/deploy.sh` applies every push to `main`.

**Why your data is safe.** Every stack keeps its data in host folders (bind mounts). Removing a Portainer stack or a
container never deletes a host folder. The real risks, and the step that handles each:

| Risk | Handled by |
|---|---|
| API keys pushed to GitHub in the first commits | step 0 replaces them before anything else |
| Variables that only exist in Portainer (removing a stack deletes them) | step 3 backs up Portainer's files; step 4 copies every value into the new env files before anything is removed |
| A wrong folder makes an app start empty | step 5 compares the running containers with the new ones; step 6 checks each database reused its data |
| Config files on the NAS newer than the repo's | step 6 compares them, stack by stack |
| Watchtower or the Deluge cleanup acting in the middle | step 3 pauses both |
| A database killed while writing | step 6 stops each database with a long timeout, then takes a snapshot |

Steps 1 to 5 only read and write new files: nothing stops until step 6. Each stack is down for a minute or two.

**Stack order**: infrastructure, media, opusline, photos, security, then portainer last (you need Portainer's UI to
remove the others).

> **Never remove a stack in Portainer after starting it from the repo.** Both use the same Compose project name,
> so Portainer's "Remove" would stop the new containers.

## 0. Close the key leak

The first commits pushed to GitHub (`63259e9`) contained the Sonarr API key, the Radarr API key and the Notifiarr API
key, in a public repo. Treat all three as known to anyone. New keys make the old ones useless, and that is the actual
fix; rewriting the history afterwards only stops displaying them.

Do this before the rest: step 4 copies the keys from Portainer, so Portainer must hold the new ones by then. The
commands of this step run on your computer, in the repo; they work in fish and bash.

### 0.1 Hide the repo while you fix it

```sh
gh repo edit Androlax2/homelab --visibility private --accept-visibility-change-consequences
```

### 0.2 Disable the Deluge cleanup task

In DSM: Control Panel → Task Scheduler → select the Deluge cleanup task → untick its "Enabled" box → OK.

The copy of the script the NAS runs today ignores failed Sonarr/Radarr calls: with new keys, it would delete
torrents without checking the import queues. It stays disabled until step 7.3.

### 0.3 New Sonarr and Radarr API keys

1. In Sonarr: Settings → General → Security → API Key → click the regenerate icon next to the key → Save Changes.
   Do the same in Radarr. Keep both new keys at hand for the next point.
2. Give the new keys to everything that calls Sonarr or Radarr:
   - Prowlarr: Settings → Apps → Sonarr, then Radarr → API Key → Test → Save.
   - Seerr: Settings → Services → the Sonarr server, then the Radarr server → API Key → Test → Save.
   - Maintainerr: Settings → Sonarr, then Radarr → API key → Save.
   - Notifiarr client (`http://<NAS IP>:5454`): its Sonarr and Radarr entries → API key → Save.
   - The dashboard: Portainer → Stacks → the stack that runs `glance` → Editor → Environment variables →
     `SONARR_API_KEY` and `RADARR_API_KEY` → Update the stack.
   - Any phone or desktop app you use with Sonarr or Radarr.

### 0.4 New Notifiarr API key

The ID at the end of the old Watchtower notification URL was your Notifiarr API key.

1. On notifiarr.com, in your profile's API keys, create a new key and delete the old one.
2. Put the new key wherever the old one was:
   - the Notifiarr client: its web UI (`http://<NAS IP>:5454`), or `api_key` in the `notifiarr.conf` of its config
     folder; then restart it from the NAS: `docker restart notifiarr`;
   - Sonarr, Radarr and Prowlarr, if they have a Notifiarr connection (Settings → Connect; Settings → Notifications
     in Prowlarr);
   - not Watchtower: it is removed during the migration.

### 0.5 Check the old keys are refused

These read the old keys from the leaked commit, which is still in your local copy, and never print them:

```sh
git show 63259e9:scripts/cleanup_deluge.sh | sed -n 's/^SONARR_API_KEY="\(.*\)"$/X-Api-Key: \1/p' | curl -s -o /dev/null -w 'Sonarr, old key: %{http_code}\n' -H @- http://<NAS IP>:8989/api/v3/system/status
git show 63259e9:scripts/cleanup_deluge.sh | sed -n 's/^RADARR_API_KEY="\(.*\)"$/X-Api-Key: \1/p' | curl -s -o /dev/null -w 'Radarr, old key: %{http_code}\n' -H @- http://<NAS IP>:7878/api/v3/system/status
```

Both must print `401`. `200` means that app still accepts the old key: redo its part of 0.3. `000` means the NAS
didn't answer: check the IP. For Notifiarr, the old key must be gone from your key list on notifiarr.com.

### 0.6 Replace GitHub's history with the clean commit

```sh
git status --short
```

If it lists files (this runbook update, for example), commit them first:
`git add -A && git commit -m "Document the key rotation"`. Then:

```sh
git push --force-with-lease=main:e07458481ef6c4d2008a14fe902b38a004c78317 origin main
git merge-base --is-ancestor 63259e99c9daf36225cc7ab83924bcfcf325f9c5 origin/main && echo "LEAKED COMMIT STILL ON main" || echo "history clean"
```

- The push only replaces GitHub's `main` if it is still the commit that was checked (`e074584`). If it refuses,
  something pushed in the meantime: look at `git log origin/main` before trying again.
- The last command must print `history clean`.
- GitHub may keep serving the old commit to anyone who has its link for a while. Its guide "Removing sensitive data
  from a repository" explains how to ask GitHub Support to purge it; with the keys replaced, that's optional.

### 0.7 Make the repo public again

```sh
gh repo edit Androlax2/homelab --visibility public --accept-visibility-change-consequences
```

### 0.8 Email

Make sure DSM can email you (Control Panel → Notification → Email → send a test message). The deploy job reports
failures by email.

## 1. Open a root shell on the NAS

In DSM: Control Panel → Terminal & SNMP → tick "Enable SSH service" → Apply. Then, from your computer:

```sh
ssh <your DSM admin user>@<NAS IP>
```

On the NAS:

```sh
sudo -i
bash
```

Every command below runs in this root `bash`. If you get disconnected, open it again and re-run step 2.3.

## 2. Tools, repo and session

### 2.1 Install and check the tools

Package Center → search "Git" → install **Git Server** (by Synology). Then:

```sh
git --version
docker compose version
jq --version
command -v flock
uname -m
mount | grep ' /volume1 '
```

- Each of the first four lines must print a version or a path.
- The `mount` line must mention `btrfs`: snapshots need it. If it says `ext4`, skip the snapshot steps and rely on
  the backups of step 3.
- If `jq` is missing, and `uname -m` printed `x86_64`:
  ```sh
  curl -fsSL -o /usr/local/bin/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
  chmod +x /usr/local/bin/jq
  jq --version
  ```
- If `docker compose version` fails but `docker-compose version` works:
  ```sh
  mkdir -p /usr/local/lib/docker/cli-plugins
  ln -s "$(command -v docker-compose)" /usr/local/lib/docker/cli-plugins/docker-compose
  docker compose version
  ```
- If `flock` is missing, stop and tell me: `deploy.sh` and `edit_env.sh` rely on it.

### 2.2 Clone the repo

As root: LinuxServer images only run custom init scripts owned by root (`config/prowlarr/mods`).

```sh
git clone https://github.com/Androlax2/homelab.git /volume1/docker/homelab
```

### 2.3 Session setup

Run this now, and again after any reconnection:

```sh
cd /volume1/docker/homelab
export PATH="$PATH:/usr/local/bin"
set -o pipefail
source scripts/migration_helpers.sh
BACKUP_DIR=/volume1/backup/pre-migration
if [ -f stacks/common.env ]; then set -a; . stacks/common.env; set +a; fi
portainer_data_dir
```

The last command must print Portainer's data folder (something like `/volume1/docker/appdata/portainer`). The
`if` line loads `DOCKERCONFDIR` and the other shared values into the shell, once step 4.1 has created them.

## 3. Safety net

### 3.1 Pause what changes things on its own

```sh
docker stop watchtower
```

The Deluge cleanup task has been disabled since step 0.2: check in DSM (Control Panel → Task Scheduler) that its
"Enabled" box is still unticked.

### 3.2 Back up Portainer's stack files and the current container settings

Both contain secrets: the folder is readable by root only.

```sh
mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
cp -a "$(portainer_data_dir)/compose" "$BACKUP_DIR/portainer-compose"
docker inspect $(docker ps -aq) > "$BACKUP_DIR/containers-inspect.json"
ls -la "$BACKUP_DIR/portainer-compose"/*
```

Expect one numbered folder per Portainer stack, each holding a compose file and a `stack.env`.

### 3.3 Dump the databases

```sh
docker exec immich_postgres sh -c 'pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' | gzip > "$BACKUP_DIR/immich.sql.gz"
docker exec opusline-db sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' | gzip > "$BACKUP_DIR/opusline.sql.gz"
docker exec prowlarr-postgres sh -c 'pg_dumpall -U "$POSTGRES_USER" -p 5433' | gzip > "$BACKUP_DIR/prowlarr.sql.gz"
for dump in "$BACKUP_DIR"/*.sql.gz; do echo "$dump: $(zcat "$dump" | grep -c 'CREATE TABLE') tables"; done
```

Each dump must report more than 0 tables.

### 3.4 Export the password vault

Open the Vaultwarden web vault → Tools → Export vault → file format ".json (Encrypted)" → save the file on your
computer, not on the NAS.

### 3.5 Snapshot the docker shared folder

The shared folder is the first folder after `/volume1/` in the path printed by `portainer_data_dir` (usually
`docker`). In DSM: Package Center → install **Snapshot Replication** → open it → Snapshots → select that shared
folder → Snapshot → Take a Snapshot → description "before homelab migration" → OK.

Later steps say "take a snapshot": it's the same three clicks.

## 4. Write every env file

Everything still runs under Portainer, which is what this step needs: the helpers read each stack's variables from
the `stack.env` Portainer used to start it. `fill_env` never overwrites a file. To redo one, delete it first
(`rm stacks/<stack>/.env`).

### 4.1 Shared values (taken from the media stack)

```sh
fill_env stacks/common.env.example stacks/common.env "$(portainer_env_of sonarr)"
cat stacks/common.env
set -a; . stacks/common.env; set +a
```

Check the values: folders, time zone, user and group IDs, LAN IP. No "Left empty" line should appear. If one does,
set the key by hand: `set_env_value stacks/common.env <KEY> '<value>'`.

### 4.2 infrastructure

```sh
fill_env stacks/infrastructure/.env.example stacks/infrastructure/.env "$(portainer_env_of glance)"
```

It reports four keys as left empty. They are new: the dashboard login and Filebrowser's folder. Generate the login
with the Glance container that runs now:

```sh
set_env_value stacks/infrastructure/.env GLANCE_SECRET_KEY "$(docker exec glance /app/glance secret:make)"
set_env_value stacks/infrastructure/.env GLANCE_USERNAME '<dashboard username, 3+ characters>'
read -rsp 'Dashboard password (6+ characters): ' dashboard_password; echo
set_env_value stacks/infrastructure/.env GLANCE_PASSWORD_HASH "$(docker exec glance /app/glance password:hash "$dashboard_password")"
unset dashboard_password
```

If Glance answers "unknown command" (an older version), use the pinned image instead: replace
`docker exec glance /app/glance` with `docker run --rm --entrypoint /app/glance glanceapp/glance:v0.8.6`.

Filebrowser used to show the whole appdata folder, meaning every app's database and secrets. Give it the narrowest
folder you actually browse (use DSM's File Station for the rest):

```sh
set_env_value stacks/infrastructure/.env FILEBROWSER_ROOT '<folder, e.g. /volume1/data/media>'
grep -cE "^(GLANCE_SECRET_KEY|GLANCE_USERNAME|GLANCE_PASSWORD_HASH|FILEBROWSER_ROOT)='.+'" stacks/infrastructure/.env
```

The last command must print `4`.

### 4.3 media

The two API keys for the cleanup script come from the infrastructure stack's variables (the new keys you set there in
step 0.3), the rest from media's.

```sh
fill_env stacks/media/.env.example stacks/media/.env "$(portainer_env_of sonarr)" "$(portainer_env_of glance)"
```

No "Left empty" line expected.

### 4.4 opusline

```sh
fill_env stacks/opusline/.env.example stacks/opusline/.env "$(portainer_env_of opusline-api)"
docker inspect opusline --format '{{index .Config.Labels "org.opencontainers.image.version"}}'
```

`fill_env` reports `OPUSLINE_VERSION` (and maybe `HTTP_PORT`) as left empty. The second command prints the
Opusline version running today. Pin it:

```sh
set_env_value stacks/opusline/.env OPUSLINE_VERSION '<the version printed above>'
```

If it printed nothing, the image has no version label: pick the tag to run from `ghcr.io/opusline/opusline-web`.
An empty `HTTP_PORT` is fine: it defaults to 8790.

### 4.5 photos

```sh
fill_env stacks/photos/.env.example stacks/photos/.env "$(portainer_env_of immich_server)"
```

### 4.6 security

```sh
fill_env stacks/security/.env.example stacks/security/.env "$(portainer_env_of vaultwarden)"
set_env_value stacks/security/.env VAULTWARDEN_DOMAIN 'https://jeancloud:8443'
docker exec -it vaultwarden /vaultwarden hash
```

`fill_env` reports `VAULTWARDEN_DOMAIN` as left empty; the next line sets it to the address clients use today.
The last command asks twice for a password for the `/admin` page and prints an Argon2 string starting with
`$argon2id$`. Paste that string between the single quotes (they keep the `$` signs literal):

```sh
set_env_value stacks/security/.env VAULTWARDEN_ADMIN_TOKEN '<paste the $argon2id$… string>'
```

From now on, `/admin` takes the password you just typed, not the old token.

### 4.7 Validate every stack

This also proves the NAS's Compose accepts two `--env-file` flags.

```sh
for stack in infrastructure media opusline photos security portainer; do
    if scripts/compose.sh "$stack" config -q; then echo "OK    $stack"; else echo "FAIL  $stack"; fi
done
```

Every stack must say `OK`, with no warning above it.
- A warning like `The "X" variable is not set` means a value copied from Portainer contains a `$`: rewrite it with
  `set_env_value` so it is single-quoted.
- An error about `--env-file` means the NAS's Compose is too old: update Container Manager in Package Center.

## 5. Review the differences

Read-only: this compares what runs now with what the repo would start. It prints variable names, never their values.

```sh
for stack in infrastructure media opusline photos security portainer; do
    scripts/premigration_check.sh "$stack"
done 2>&1 | tee "$BACKUP_DIR/premigration-check.txt"
```

How to read it:
- `(expected)`: a mount moving into the repo's `config/` folder. Fine.
- `(check) image: <old> (running version: X) -> <new>`: the new tag must not be older than X. If it is, stop and
  tell me: starting an older version on a migrated database can break the app.
- Every other line is a difference. The ones below are intended; anything else means an env file is wrong (fix it in
  step 4) or needs a look before going on.

| Stack | Intended differences |
|---|---|
| infrastructure | `glance`: `mount dropped: /var/run/docker.sock` (it now goes through the proxy); `env dropped:` for `STACK_ENV_FILE`, `WATCHTOWER_NOTIFICATION_URL`, `SERVER_ID`, `TAILSCALE_AUTHKEY`, `SYNOLOGY_NAS_PASSWORD`, `ADGUARD_HOME_PASSWORD`, `LAN_NETWORK` (whichever it had); `env new:` `GLANCE_SECRET_KEY`, `GLANCE_USERNAME`, `GLANCE_PASSWORD_HASH`, `FILEBROWSER_ROOT`. `docker-socket-proxy`: `no container named docker-socket-proxy` (new). `filebrowser`: `mount source changes: /srv` (the narrower folder). |
| media | `seerr` and `prowlarr-postgres`: `env dropped: PUID`, `env dropped: PGID` (those images ignored them). |
| opusline | `opusline-api`, `opusline-scheduler`, `opusline-queue`: `env dropped:` for the shared keys (`DOCKERCONFDIR`, `DOCKERSTORAGEDIR`, `DOCKERLOGGING_MAXFILE`, `DOCKERLOGGING_MAXSIZE`, `STACK_ENV_FILE`, `LAN_IP`, whichever they had), `env new: OPUSLINE_VERSION`. |
| photos | `immich_server`, `immich_redis`, `immich_postgres`: `env dropped: PUID`, `env dropped: PGID`. |
| security | `vaultwarden`: `env dropped: WEBSOCKET_ENABLED`, `env changed: ADMIN_TOKEN` (the new hash). |
| portainer | only `(check)` image lines. |

## 6. Migrate the stacks

Each stack follows the same pattern: compare its config files, stop its database, take a snapshot, remove it in
Portainer, start it from the repo, check it.

To remove a stack in Portainer: open Portainer → your environment → Stacks → tick the stack → Remove → confirm. The
first command of each section prints which stack that is.

### 6.1 infrastructure

```sh
portainer_stack_of glance
diff -rq "$DOCKERCONFDIR/glance/config" config/glance/config
diff -rq "$DOCKERCONFDIR/glance/assets" config/glance/assets
diff "$DOCKERCONFDIR/filebrowser/config/settings.json" config/filebrowser/config/settings.json
```

In `glance/config`, these differences are the repo's changes: `glance.yml`, `pages/medias.yml`,
`widgets/arr-releases.yml`, `widgets/monitors.yml` and `widgets/prowlarr-indexers.yml` differ, and
`widgets/arr-releases-sonarr.yml` only exists on the NAS. Any other file listed was edited on the NAS after you
copied it into the repo: bring that edit into the repo (on your computer: edit, commit, push; here: `git pull`)
before going on. The other two commands should print nothing.

Take a snapshot, remove the stack in Portainer, then:

```sh
scripts/compose.sh infrastructure up -d
scripts/compose.sh infrastructure ps
docker ps -a --filter name=watchtower --format '{{.Names}}'
```

Checks:
- `glance`, `docker-socket-proxy` and `filebrowser` are running; the watchtower line prints nothing (it left with
  the Portainer stack).
- `http://<LAN IP>:8090` shows a login page. Log in: the Containers widget lists your containers (read through
  the proxy now).
- `http://<LAN IP>:8095` (Filebrowser) shows the new folder.

If Glance keeps restarting, `scripts/compose.sh infrastructure logs --tail 30 glance` names the missing or invalid
value.

### 6.2 media

```sh
portainer_stack_of sonarr
diff -rq "$DOCKERCONFDIR/prowlarr/mods" config/prowlarr/mods
grep -o '<PostgresHost>[^<]*' "$DOCKERCONFDIR/prowlarr/config.xml"
```

- The diff lists only `10-update-custom-definitions.sh`: that's the repo's change (pinned gist revision).
- Prowlarr's database now only listens on localhost, so `PostgresHost` must be `localhost` or `127.0.0.1`. If it
  shows something else, you'll fix it below. If it prints nothing, Prowlarr doesn't use Postgres: nothing to do.

```sh
docker stop -t 120 prowlarr-postgres
```

Take a snapshot, remove the stack in Portainer. Only if `PostgresHost` was something else:

```sh
sed -i 's|<PostgresHost>[^<]*<|<PostgresHost>localhost<|' "$DOCKERCONFDIR/prowlarr/config.xml"
grep -o '<PostgresHost>[^<]*' "$DOCKERCONFDIR/prowlarr/config.xml"
```

Then:

```sh
scripts/compose.sh media up -d
scripts/compose.sh media ps
scripts/compose.sh media logs prowlarr-postgres | grep -iE 'initdb|files belonging' || echo "Postgres reused its data: good"
scripts/compose.sh media logs prowlarr | grep CustomDefs
```

Checks:
- 10 containers are running.
- The Postgres line says `Postgres reused its data: good`. If it prints log lines instead, the database started
  empty: run `scripts/compose.sh media down`, check `DOCKERCONFDIR` in `stacks/common.env`, and ask me before going
  on. The real data is untouched.
- The CustomDefs lines end with "Terminé avec succès".
- Sonarr, Radarr, Prowlarr, Plex, Seerr, Tautulli and Maintainerr show their data. Deluge shows its torrents (the
  VPN may take a minute to connect).

### 6.3 opusline

```sh
portainer_stack_of opusline
docker stop -t 120 opusline-db
```

Take a snapshot, remove the stack in Portainer, then:

```sh
scripts/compose.sh opusline up -d
sleep 60
scripts/compose.sh opusline ps
scripts/compose.sh opusline logs opusline-db | grep -iE 'initdb|files belonging' || echo "Postgres reused its data: good"
```

Checks: six containers running, the database, Redis and API `healthy`, `Postgres reused its data: good`, and you
can log in at Opusline's public URL.

### 6.4 photos

```sh
portainer_stack_of immich_server
docker stop -t 120 immich_postgres
```

Take a snapshot, remove the stack in Portainer, then:

```sh
scripts/compose.sh photos up -d
scripts/compose.sh photos ps
scripts/compose.sh photos logs immich-database | grep -iE 'initdb|files belonging' || echo "Postgres reused its data: good"
```

Checks: three containers running, `Postgres reused its data: good`, and `http://<LAN IP>:2283` shows your library.

### 6.5 security

```sh
portainer_stack_of vaultwarden
docker stop -t 60 vaultwarden
tar czf "$BACKUP_DIR/vaultwarden-data.tgz" -C "$DOCKERCONFDIR" vaultwarden
```

Take a snapshot. Then update the DSM reverse proxy, since port 3012 is gone: Control Panel → Login Portal →
Advanced → Reverse Proxy.
- Delete any rule whose destination port is 3012.
- Edit the rule whose destination port is 8580 → Custom Header → Create → WebSocket → Save. Live sync goes through
  this rule now.

Remove the stack in Portainer, then:

```sh
scripts/compose.sh security up -d
curl -s http://127.0.0.1:8580/alive; echo
```

Checks: `/alive` prints a date; a Bitwarden client logs in through `https://jeancloud:8443`; `/admin` accepts the
password from step 4.6.

Optional hardening: if the reverse proxy rule's destination is `localhost`, change the port line of
`stacks/security/compose.yml` to `"127.0.0.1:8580:80"`. Vaultwarden then stops answering in plain HTTP on the LAN.
Also point the Glance monitor (`config/glance/config/widgets/services-monitor.yml`) at `https://jeancloud:8443/alive`.

### 6.6 portainer (last)

Portainer can't remove its own stack, so replace its container directly:

```sh
docker rm -f portainer
scripts/compose.sh portainer up -d
scripts/compose.sh portainer ps
```

Checks: `https://<LAN IP>:9443` works and you log in as before (its data folder is unchanged). Port 9000 no longer
answers. The stacks started from the repo appear in Portainer with "Limited" control: look, but don't edit or
remove them there.

## 7. Turn on automatic deploys

### 7.1 First deploy, by hand

```sh
bash scripts/deploy.sh; echo "exit: $?"
cat .last-deployed
```

Expect `exit: 0` and a commit hash. This first run treats every file as changed: Compose leaves the running
containers alone, and Glance, Filebrowser and Prowlarr restart once (their config folders count as changed).

### 7.2 Schedule it

DSM: Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script.
- General: Task "homelab deploy", User `root`, Enabled.
- Schedule: Run on the following days: Daily; First run time 00:00; Frequency: Every 5 minutes; Last run time 23:55.
- Task Settings: tick "Send run details by email", your address, tick "Send run details only when the script
  terminates abnormally". User-defined script: `bash /volume1/docker/homelab/scripts/deploy.sh`
- OK, then select the task → Run once, and check the result with `cat .last-deployed` (same hash as before: nothing
  new to deploy).

### 7.3 Point the Deluge cleanup at the checkout

Simulate it first:

```sh
(set -a; . stacks/media/.env; set +a; DRY_RUN=1 bash scripts/cleanup_deluge.sh); echo "exit: $?"
```

Expect `exit: 0` and a final `Termine.` line (with `[DRY-RUN]` lines if it found orphans). Then in Task Scheduler,
edit the cleanup task: its user-defined script becomes

```sh
set -a; . /volume1/docker/homelab/stacks/media/.env; set +a; bash /volume1/docker/homelab/scripts/cleanup_deluge.sh
```

and tick "Enabled" again.

### 7.4 Try the whole loop

On your computer, change the dashboard title (`logo-text` in `config/glance/config/glance.yml`), commit and push.
Within 5 minutes, on the NAS, `cat .last-deployed` shows the new commit and the dashboard shows the new title.

### 7.5 Protect `main`

On your computer, run the `gh api` command from the README's Security section. From then on, every change goes
through a pull request whose checks pass.

### 7.6 Clean up

Now:

```sh
rm "$BACKUP_DIR/containers-inspect.json"
```

After a few weeks without problems, the database dumps, Portainer's old stack files, the old config copies and the
snapshots can go:

```sh
rm -r "$BACKUP_DIR"
rm -r "$DOCKERCONFDIR/glance/config" "$DOCKERCONFDIR/glance/assets" "$DOCKERCONFDIR/filebrowser/config" "$DOCKERCONFDIR/prowlarr/mods"
```

Delete the snapshots in Snapshot Replication.

## Rollback (one stack)

```sh
scripts/compose.sh <stack> down
grep -rl 'container_name: <one container of the stack>' "$BACKUP_DIR/portainer-compose"
```

Then in Portainer: Stacks → Add stack → the same name as before → Web editor: paste the compose file found above →
Environment variables → Advanced mode: paste the `stack.env` from the same folder → Deploy the stack. Restore the
snapshot only if an app wrote bad data (Snapshot Replication → Snapshots → select it → Restore).

## When something doesn't go as described

| Symptom | What to do |
|---|---|
| `No such source file: ''` from `fill_env` | `portainer_env_of` failed; its message is just above. Copy the variables from Portainer instead (Stacks → the stack → Environment variables → Advanced mode), save them with `cat > /root/<stack>.env` (paste, then Ctrl-D), use `/root/<stack>.env` as the source file, and delete it afterwards. |
| `already exists` from `fill_env` | The file is there from a previous try: `rm` it and run the command again. |
| A `Left empty` key that should have a value | `set_env_value stacks/<stack>/.env <KEY> '<value>'`. |
| Glance keeps restarting | `scripts/compose.sh infrastructure logs --tail 30 glance` names the missing or invalid value. |
| A Postgres log shows `initdb` | Stop the stack (`scripts/compose.sh <stack> down`), check the folders in `stacks/common.env`, and ask me. Nothing was lost: the old data folder is untouched. |
| The deploy reports a missing key | `scripts/edit_env.sh <stack>` (or `common`) adds it and redeploys. |
