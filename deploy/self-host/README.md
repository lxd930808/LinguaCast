# LinguaCast self-hosted server

This directory runs the complete LinguaCast back end on one Docker host:

| Service | Role | Public? |
| --- | --- | --- |
| `account-service` | Sign in, sessions, per-account configuration, daily quota ledger, account deletion | via Caddy (`ACCOUNT_DOMAIN`) |
| `content-pipeline` | Podcast and video transcription, translation and subtitle packaging | via Caddy (`CONTENT_DOMAIN`) |
| `research-assistant` | Research assistant (V2 workspace API) | via Caddy (`ASSISTANT_DOMAIN`) |
| `media-service` | YouTube media download (yt-dlp) and signed playback URLs | via Caddy (`MEDIA_DOMAIN`) |
| `pot-provider` | bgutil PO Token provider used by yt-dlp | internal only |
| `caddy` | HTTPS entry point; blocks every `/internal/*` route | ports 80/443 |

Services talk to each other by name on a private Docker network. None of them publishes
a host port; only Caddy does. Nothing here depends on the LinguaCast official servers.

## 1. Requirements

- A Linux host with Docker Engine 24+ and Docker Compose v2, 2 vCPU / 4 GiB RAM or more,
  and enough disk for temporary media (default free-space floor 5 GiB).
- Four DNS names pointing at the host, for example `account.example.com`,
  `content.example.com`, `assistant.example.com`, `media.example.com`.
- Your own provider accounts:
  - DashScope API key (speech recognition);
  - a translation provider key: DeepSeek, OpenRouter or DashScope;
  - a Cloudflare R2 bucket and an API token limited to that bucket (subtitle artifacts);
  - model credentials for the research assistant (Pi `models.json` and `auth.json`);
  - Apple mode only: an Apple Developer team with Sign in with Apple enabled.
- `openssl` on the host (for `init-env.sh`).

## 2. Choose a mode

| | `selfhost` (default) | `apple` |
| --- | --- | --- |
| Accounts | One fixed account | One account per Apple ID |
| App sign-in | Settings → Server: enter your server address and `SELFHOST_ACCESS_TOKEN` | Sign in with Apple against your own team |
| Quota | Not enforced | Daily limits from `.env` |
| Service identity | Every service accepts the one deployment token | Services validate tokens at the account service and pass a signed account context |

Official-service credentials are never sent to a self-hosted address, and your server's
back-end secrets (provider keys, R2, internal tokens) never leave the server.

## 3. Configure

```bash
cd deploy/self-host
./init-env.sh selfhost          # or: ./init-env.sh apple
```

`init-env.sh` writes `.env` (mode 600) with fresh random internal secrets. Then edit `.env`:

1. Set the four `*_DOMAIN` values and `CADDY_TLS` (an e-mail address for Let's Encrypt,
   or `internal` on an isolated test server).
2. Replace every value that starts with `replace-` (DashScope, translation, R2).
3. Apple mode: set `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_CLIENT_IDS` (your app's bundle
   IDs) and copy the private key to `secrets/apple-sign-in-key.p8` (mode 600).
4. Adjust quota and concurrency values if needed.

Model credentials for the assistant:

```bash
# Edit pi-config/models.json to choose providers and models.
# Log in with the Pi coding agent on a trusted machine, then copy its auth.json here.
install -m 600 -o 1000 -g 1000 /path/to/auth.json pi-config/auth.json
```

`auth.json` must be writable by uid 1000 because Pi refreshes OAuth credentials in place.

Validate before starting:

```bash
docker compose -f docker-compose.yml --env-file .env config --quiet
```

Missing required values fail here with the variable name.

## 4. Start and verify

```bash
docker compose -f docker-compose.yml --env-file .env up -d --build
./verify.sh
```

`verify.sh` checks that every container is healthy, that only Caddy publishes ports (the
PO Token provider stays internal), that services resolve each other by name, that public
health endpoints answer while `/internal/*` returns 404, that removed assistant V1 routes
return 404, that the configuration/challenge responses contain no back-end secrets, and
that `pi-config/auth.json` has mode 600 and owner uid 1000.

## 5. Connect the app

- `selfhost` mode: Settings → Server → enter `https://<ACCOUNT_DOMAIN>` and the value of
  `SELFHOST_ACCESS_TOKEN`, then Connect. The app receives the other service addresses from
  your account service.
- `apple` mode: build the app with your own bundle ID and set its official account URL
  (`LinguaCastOfficialAccountURL` in the Info.plist files) to `https://<ACCOUNT_DOMAIN>`,
  or use Settings → Server with the same address.

## 6. Back up and restore

```bash
./backup.sh                                   # writes backups/linguacast-selfhost-<stamp>.tar
./restore-verify.sh backups/linguacast-selfhost-<stamp>.tar
./restore.sh backups/linguacast-selfhost-<stamp>.tar /var/tmp/linguacast-restore
```

The archive contains the account, content and assistant SQLite databases (consistent
`VACUUM INTO` snapshots), the assistant workspace, global-memory and shared-version trees,
and the account deletion tombstones. Subtitle artifacts stay in R2 and are not copied: the
backup records the bucket and prefix it expects. The media download cache is not included.

Restoring an older backup could bring back data of accounts deleted afterwards. Give
`restore.sh` the newer account database so those deletions are replayed:

```bash
TOMBSTONES_FROM_LIVE=1 LOAD_VOLUMES=1 VOLUME_PREFIX=linguacast-selfhost-restore \
  ./restore.sh backups/linguacast-selfhost-<stamp>.tar
```

Restores go to a scratch directory or to new volumes; the live `linguacast-selfhost_*`
volumes are refused unless `RESTORE_CLOBBER_LIVE=1` is set after a verified scratch restore.
Replayed accounts return to `deleting` and the account service purges them again on start.

## 7. Upgrade and roll back

```bash
./backup.sh
git pull
docker compose -f docker-compose.yml --env-file .env up -d --build
./verify.sh
```

Database migrations are forward-only. To roll back, stop the project, restore the
pre-upgrade backup into new volumes and start the previous version against them. Never run
`docker system prune` or delete volumes as part of an upgrade.

## 8. Notes

- Existing research assistant V1 data is kept in its original tables but is no longer
  served; see `docs/contracts/assistant-v1-ARCHIVED.md`.
- `yt-dlp` is pinned by `YTDLP_VERSION`. Pin `BGUTIL_POT_PROVIDER_VERSION` to the same
  release for the media image plugin and the `pot-provider` image once you have verified it.
- Do not put the media domain behind a caching CDN.
