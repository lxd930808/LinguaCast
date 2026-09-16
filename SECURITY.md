# Security

LinguaCast is published as a source reference. There is no guaranteed support or response SLA.

## Reporting a vulnerability

Do not disclose exploitable details in a public issue. Use GitHub's private vulnerability reporting feature for this repository when available. Include affected files, reproduction steps, impact, and a suggested mitigation.

## Secret handling

- Never commit API keys, CloudKit credentials, signing identities, deployment tokens, bearer tokens, or `.env` files. `deploy/self-host/.gitignore` and `services/*/.gitignore` already exclude `.env`, `secrets/*`, `pi-config/auth.json`, and local runtime data (`data/`, `tmp/`, `*.db`) — keep it that way in forks.
- Provider credentials (DashScope, translation, Cloudflare R2, research-assistant model access) live server-side, in the backend deployment's `.env` / `pi-config/auth.json`. They are never entered on-device and never sent to a self-hosted address other than your own.
- The account service issues per-account session tokens and (in `apple` identity mode) validates Sign in with Apple; the app stores its own session/service tokens through the Keychain-backed settings path, not the provider credentials themselves.
- The Apple TV QR setup page intentionally rejects all secret configuration keys — server address, mode, and subscription URLs only. Its random link token expires after 10 minutes and is invalidated after a successful submission.
- The optional media service requires an `AUTH_TOKEN`; use a random value and TLS when traffic leaves a trusted LAN.
- In `deploy/self-host/`'s default `selfhost` mode, all backend services share one deployment token — rotate it everywhere if it leaks. `apple` mode gives each Apple ID its own signed account context instead.

## Deployment notes

The default Xcode scheme has no CloudKit entitlement and works with local storage. CloudKit requires your own container, App ID, signing team, and explicit opt-in configuration.

The `deploy/self-host/` stack only exposes Caddy (ports 80/443) to the host network; every other service talks over a private Docker network and rejects `/internal/*` routes from outside. Operators are responsible for their own TLS certificates, backups (`backup.sh`/`restore-verify.sh`), and keeping the stack patched.

The media service downloads and transforms third-party media. Operators are responsible for authorization, applicable law, platform terms, access control, retention, and network exposure.
