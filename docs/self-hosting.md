# Self-hosting Pendenz

This guide sets up the Pendenz server on a Linux host with Docker, pairs the first device and connects an agent. [design.md](design.md) explains how the parts work together.

## What runs where

| Part | Where | What it is |
|---|---|---|
| API and hosted MCP | Container `api` | The Rust server with one SQLite database in `./data`. It also serves `/mcp`, a stateless MCP endpoint that works with the caller's own token |
| Backup | Container `backup`, run by `update.sh` and a nightly timer | SQLite snapshot, integrity check, optional upload with restic |
| HTTPS | Your reverse proxy, or the optional Cloudflare Tunnel | The app only talks to a server over HTTPS |
| CLI and stdio MCP | On the machine of each agent | The same `pendenz` binary: `pendenz mcp` and commands such as `pendenz list` |

The API has no login page. Every `/api` route and `/mcp` need a bearer token, apart from `POST /api/pair`, which takes a one-time code.

## Requirements

- A Linux host with Docker and the Compose plugin.
- A hostname with HTTPS, reached through a reverse proxy on the host or a Cloudflare Tunnel.
- The published image is for `linux/amd64`. On another architecture, build the image yourself (see "Images").

## Install

Make a folder for the server. This guide uses `/srv/pendenz`; the systemd units in `deploy/` expect it there, so change their paths if you pick another one.

```sh
mkdir -p /srv/pendenz/data /srv/pendenz/backups
chown 10001:10001 /srv/pendenz/data /srv/pendenz/backups
chmod 700 /srv/pendenz
```

The containers run as the user 10001, which needs to write `data` and `backups`. Put `data` on a disk you trust, since it holds everything.

Copy these files from the repo into `/srv/pendenz`:

- `deploy/compose.yaml`
- `deploy/update.sh`
- `.env.example`, renamed to `.env`
- `deploy/backup.env.example`, renamed to `backup.env`
- `deploy/compose.tunnel.yaml`, only if you use a Cloudflare Tunnel

Then `chmod 600 /srv/pendenz/.env /srv/pendenz/backup.env` and fill in `.env`:

| Variable | Value |
|---|---|
| `PENDENZ_ORIGIN` | The public origin, `https://<hostname>`, exactly as clients call it. The hosted MCP rejects requests for any other host |
| `PENDENZ_TIMEZONE` | Your IANA zone, such as `Europe/Zurich`. Due dates that name no zone are in this one |
| `PENDENZ_API_IMAGE` | Leave empty. `update.sh` writes it |
| `PENDENZ_API_PORT` | The loopback port for your reverse proxy, `8080` by default |
| `PENDENZ_PUSH_RELAY`, `PENDENZ_PUSH_RELAY_KEY` | Leave empty for now, see "Push" below |

The CLI settings at the end of `.env.example` are for agents and can be deleted on the server.

### HTTPS with a reverse proxy

`compose.yaml` publishes the API on `127.0.0.1:8080`. Route the whole hostname there; `/mcp` is a path of the same server. [`deploy/Caddyfile.example`](../deploy/Caddyfile.example) does that with Caddy, which also gets the certificate. Any other proxy works the same way.

### HTTPS with a Cloudflare Tunnel

For a host without an open port, add the tunnel. In `.env`:

```sh
COMPOSE_FILE=compose.yaml:compose.tunnel.yaml
CLOUDFLARED_IMAGE=cloudflare/cloudflared@sha256:<digest>
CLOUDFLARE_TUNNEL_TOKEN=<token of a tunnel made for Pendenz>
```

In the Cloudflare dashboard, give the tunnel one public hostname that goes to `http://api:8080`. Do not put Cloudflare Access in front of it: the apps and the agents authenticate with their Pendenz token only.

The paths in `COMPOSE_FILE` start from the working directory, so run `docker compose` from `/srv/pendenz`. `update.sh` does that by itself.

To take the loopback ports away again when the tunnel is the only way in, add a `compose.override.yaml` with `ports: !reset []` for `api`, and add it to `COMPOSE_FILE`.

### Start

Pick a commit on `main` whose CI run passed, and run:

```sh
/srv/pendenz/update.sh <full commit sha>
```

The first run finds no database and skips the backup. Then check that the server answers through your hostname:

```sh
curl https://<hostname>/healthz                        # {"status":"ok"}
curl -s -o /dev/null -w '%{http_code}\n' https://<hostname>/api/items   # 401
```

Give the owner your name. Agents see it in `workspace` and the activity log shows it:

```sh
cd /srv/pendenz
docker compose exec api pendenz set-owner-name --name "Ada"
```

## Pair a device

Every iPhone, iPad and Mac gets a token of its own by pairing. A device token can do everything, approving included, so it only ever lives in the Keychain of that device.

The first device needs a code from the server:

```sh
docker compose exec api pendenz pairing-code
```

It prints a code such as `48TQY-AA7ZA` that works once, for ten minutes. In the app, enter `https://<hostname>`, the code and a name for the device. Every later device gets its code from a paired one, in Settings under "Show a Pairing Code".

```sh
docker compose exec api pendenz list-devices
docker compose exec api pendenz revoke-device <device id>
```

A lost device is revoked from another device in Settings, or with `revoke-device`. Its token stops working at once, and the app on it shows the pairing screen the next time it reaches the server.

## Tokens for agents

Each agent gets an identity of its own, so the activity log shows who did what, and one or more tokens. A token is printed once and stored only as a hash.

```sh
docker compose exec api pendenz add-agent --id my-agent --name "My agent"
docker compose exec api pendenz issue-token --actor my-agent --label laptop --scopes read,write
docker compose exec api pendenz list-tokens
docker compose exec api pendenz revoke-token <token id>
```

`--days <n>` sets an expiry; without it a token does not expire.

| Scope | Allows |
|---|---|
| `read` | Reading items, notes, projects and the changes feed |
| `write` | Creating and changing items, comments, notes and projects |
| `propose` | Reserved; nothing uses it yet |
| `approve` | Only for the owner. No agent can get it |
| `telegram` | Only for the identity `telegram-bridge`, which gets no other scope |

A token with `write` but without `read` gets a receipt (the ID and the version) instead of the stored row, which makes it capture-only, for example for a Shortcut on a device without the app. Such a token belongs to the owner: `issue-token --actor owner --label shortcut --scopes write`.

Keep tokens out of chats, source control and agent memories. Store them in a secret store or the Keychain.

### Connect an MCP client

The hosted endpoint is `https://<hostname>/mcp`, a stateless POST endpoint that takes the Pendenz token as a bearer token. For Claude Code:

```sh
claude mcp add --transport http pendenz https://<hostname>/mcp --header "Authorization: Bearer pdz_..."
```

The stdio server is `pendenz mcp` with `PENDENZ_API_URL` and `PENDENZ_API_TOKEN` in its environment. It also offers `add_item_image`, which reads a file next to the agent. Both servers offer only the tools the token's scopes allow. Install the binary on the agent's machine from a checkout with `cargo install --path server`; it needs no database there. `pendenz --help` lists the CLI commands, which take the same environment.

## Updates

```sh
/srv/pendenz/update.sh <full commit sha>
```

The script:

1. Pulls the image for that commit and checks that its labels name this commit and the expected repo.
2. Runs the backup, unless there is no database yet. Without `backup.env` it stops.
3. Writes the image reference with its digest into `.env`.
4. Starts the services of the compose files, removes containers of services they no longer have, and waits until they are healthy. It then checks that `/readyz` answers and that `/api/items` without a token answers 401.
5. Writes the commit to `last-deployed-sha`.

If the new containers do not become healthy, it puts the previous `.env` back and starts the previous images. It never restores the database. A new version applies its migrations when it starts, and an older image refuses a database with a migration it does not know. To go back past a migration, restore the backup the script made before the update (see "A real restore").

Changes to `compose.yaml` or `update.sh` reach the host only when you copy the files again. The commit history of `deploy/` says when that is needed.

### From two containers to one

Before the MCP endpoint moved into the API, it ran in a container of its own, `mcp`, on port 8090. To update a server from that time:

1. Keep the old `compose.yaml`, `update.sh` and any `compose.tunnel.yaml` or `compose.override.yaml` in a folder of their own, such as `/srv/pendenz/before-one-container/`.
2. Copy the new `compose.yaml`, `update.sh` and, if you use it, `compose.tunnel.yaml`. Take `mcp` out of a `compose.override.yaml`.
3. Run `update.sh` with the new commit. It removes the `mcp` container. If it reports that the new container is not healthy, its rollback starts the previous API image with the new compose files, which have no `mcp` service: copy the old files back and run `docker compose up -d` to get both containers again.
4. Route `/mcp` to the API: drop the `/mcp` rule from the reverse proxy or the tunnel, so the whole hostname goes to `127.0.0.1:8080` or `http://api:8080`.
5. Delete `PENDENZ_MCP_IMAGE` and `PENDENZ_MCP_PORT` from `.env`. They do nothing anymore.

MCP clients keep their address, `https://<hostname>/mcp`, and their tokens.

### Images

CI publishes `ghcr.io/unveroleone/pendenz-api:<commit>` for every commit on `main`. The image carries the commit and the repo URL as labels, which `update.sh` checks.

A fork that publishes its own images sets the prefix and the repo in `.env`:

```sh
PENDENZ_IMAGE_PREFIX=ghcr.io/<you>/<repo>
PENDENZ_SOURCE_URL=https://github.com/<you>/<repo>
```

To build the image yourself, from the repo root:

```sh
docker build -f deploy/api.Dockerfile -t pendenz-api:local .
```

Then set `PENDENZ_API_IMAGE` in `.env` by hand and run `docker compose up -d --wait` from `/srv/pendenz`. `update.sh` only works with images from a registry.

## Backups

`backup.env` decides where the snapshots go. With an empty `RESTIC_REPOSITORY` the backup only writes local snapshots to `backups/` and keeps the newest seven. For an off-site copy, point restic at a bucket of its own, with a credential that reaches only that bucket:

```sh
RESTIC_REPOSITORY=s3:https://<endpoint>/<bucket>/pendenz
RESTIC_PASSWORD=<long random password>
AWS_ACCESS_KEY_ID=<bucket-scoped key>
AWS_SECRET_ACCESS_KEY=<bucket-scoped secret>
AWS_DEFAULT_REGION=auto
```

Initialize the repository once, then run a backup by hand:

```sh
cd /srv/pendenz
docker compose --profile backup run --rm -e RESTIC_CACHE_DIR=/tmp/restic-cache --entrypoint restic backup init
docker compose --profile backup run --rm backup
```

The backup uses SQLite's online backup and `PRAGMA integrity_check`, uploads the snapshot and keeps 30 days in restic. Images on items are rows in the same database, so they are in every snapshot, and they are what makes the database grow. Keep the restic password somewhere outside the server: the archive cannot supply its own password.

For a nightly run, copy `deploy/pendenz-backup.service` and `deploy/pendenz-backup.timer` to `/etc/systemd/system`, then:

```sh
systemctl daemon-reload
systemctl enable --now pendenz-backup.timer
```

It runs at 03:20 UTC with up to ten minutes of delay.

### Alert when a backup fails

`pendenz-backup.service` starts `pendenz-alert@.service` when it fails, which runs `alert.sh` and sends a Telegram message with the end of the failed unit's log. Copy `deploy/alert.sh` to `/srv/pendenz` (mode 700) and `deploy/alert.env.example` to `/srv/pendenz/alert.env` (mode 600), fill in the bot token and the chat ID, copy `deploy/pendenz-alert@.service` to `/etc/systemd/system`, and try it:

```sh
systemctl daemon-reload
systemctl start pendenz-alert@pendenz-backup.service.service
```

Without these files the failed backup only shows in `systemctl status pendenz-backup.service`.

### Try a restore

A backup counts once a restore from it worked. Do this once before real data goes in:

1. Restore the latest snapshot to a scratch folder: `docker compose --profile backup run --rm -e RESTIC_CACHE_DIR=/tmp/restic-cache --entrypoint restic backup restore latest --target /backups/drill`.
2. Check it: `sqlite3 -readonly <file> 'PRAGMA integrity_check; SELECT count(*) FROM items;'`.
3. Start the same API image against the restored file without a network, and read an item with a token.
4. Delete the scratch copy.

### A real restore

Stop the API, keep the old `data` folder aside, put the verified snapshot in place as `data/pendenz.db`, remove the old `pendenz.db-wal` and `pendenz.db-shm`, set the owner of the files back to 10001 and start the API. Apps that synced past the restored state get `reset: true` from the changes feed and sync from the start. A device paired after the snapshot is unknown to the restored database: its app shows the pairing screen and needs a new code, and the changes it had not sent go out after that.

## Push

After a change, the server can ask your other devices to sync with a silent push. It sends the device tokens to a relay, which holds the APNs keys and sends a fixed "sync now" push. The relay's code is in [`relay/`](../relay).

The public relay is not open to other servers yet ([ROADMAP.md](../ROADMAP.md)). Until then, leave `PENDENZ_PUSH_RELAY` empty. The app still syncs when it opens, when it comes to the front and on pull to refresh, and reminders are not affected, because they are local notifications on each device.

If you build the app under your own bundle ID with your own Apple team, you can run your own relay: deploy `relay/` as a Cloudflare Worker with your APNs keys and your bundle ID as `APNS_TOPIC`, and set its address and `RELAY_SECRET` in `.env`.

## Checks before real data goes in

- `PENDENZ_AUTH_MODE` is `token`, which the compose file sets. Local mode only starts on a loopback address and must never be reachable from outside.
- From outside: a request without a token answers 401, with a revoked token 401, and a `GET` with a write-only token 403.
- With an agent token, an item hidden from agents answers 404, exactly like an ID that does not exist.
- `POST /api/pair` with a wrong code answers 400, and `GET /api/devices` with an agent token 403.
- A backup ran, and a restore from it worked.

## Logs

```sh
cd /srv/pendenz
docker compose ps
docker compose logs --since 1h api
cat last-deployed-sha
```

`GET /healthz` says the process is up, `GET /readyz` that it reaches the database. Both work without a token. A 500 from the API always comes with a `Database operation failed` line in the API log.
