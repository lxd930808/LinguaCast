# LinguaCast

LinguaCast is a source-reference iOS and tvOS app for bilingual podcast and YouTube-assisted language learning, plus the self-hostable backend it depends on. It combines subscription browsing, playback, subtitle processing, translation, account sign-in, and optional CloudKit synchronization.

[简体中文完整指南](docs/README.zh-CN.md)

> This repository is provided as a source reference. It is not a hosted service, supported product, or public roadmap. You must supply your own Apple signing identity, provider API keys, and a backend deployment (self-hosted, using the included `deploy/self-host/` stack, or your own compatible implementation of the wire contracts in `docs/contracts/`).

## What is included

- A SwiftUI app targeting iOS 17+ and tvOS 17+, plus shared Swift packages for domain models, playback, and optional CloudKit sync
- Podcast and YouTube subscription, catalog, playback, subtitle, translation, and learning flows
- On-device Chinese speech synthesis (optional, with separately provisioned model assets)
- Three Node.js backend services: `account-service` (sign-in, sessions, per-account config, daily quota), `content-pipeline` (transcription, translation, subtitle packaging), `research-assistant` (research assistant workspace API)
- An optional Node.js media service (`tools/local-youtube-media-service`) for YouTube download preparation, with Docker support
- A complete `deploy/self-host/` Docker Compose stack that wires all four services plus Caddy (HTTPS) and a PO Token provider sidecar on one host
- A short-lived local-network QR setup flow for non-secret Apple TV settings
- Wire-level API contracts (`docs/contracts/`) if you want to implement your own compatible backend instead of using `deploy/self-host/`

The app requires a backend to do anything beyond local playback of already-downloaded content — there is no on-device fallback for transcription, translation, or the research assistant. The snapshot excludes the maintainer's own production deployment (infrastructure, credentials, signing identities, personal CloudKit identifiers) and the original repository history.

## Requirements

- macOS 26, Xcode 26.6, XcodeGen 2.46+ for the app
- Node.js 22+ for the backend services and media tool
- Docker Engine 24+ and Docker Compose v2 if you self-host

## Repository layout

```text
Packages/
  CloudSyncKit/       Optional CloudKit synchronization and app settings
  ChineseTTS/         Chinese speech planning, synthesis, and local audio storage
  DomainModels/       Shared SwiftData models
  PlayerKit/          Audio playback layer
ios/PodcastEnglishStudio/
  PodcastEnglishStudio/       iOS/tvOS application
  PodcastEnglishStudioCore/   Testable shared app policies and utilities
  Config/                     Public build placeholders + local override template (see below)
  project.yml                 XcodeGen source of truth
services/
  account-service/            Sign-in, sessions, per-account config, quota
  content-pipeline/           Transcription, translation, subtitle packaging
  research-assistant/         Research assistant workspace API
tools/local-youtube-media-service/
  Self-hostable media preparation service (also usable standalone)
deploy/
  self-host/                  Docker Compose stack for the full backend
  research-assistant/lib/     Shared backup/restore library used by the self-host stack
docs/contracts/
  OpenAPI + JSON Schema wire contracts for the services above
THIRD_PARTY_LICENSES.md       Third-party dependency and tool license inventory
```

## Build the app

```bash
brew install xcodegen
cd ios/PodcastEnglishStudio
xcodegen generate
open PodcastEnglishStudio.xcodeproj
```

Select the `PodcastEnglishStudio` scheme. It is the local-only default: it does not attach CloudKit entitlements, and SwiftData/Keychain-backed local functionality remains available.

For unsigned command-line verification:

```bash
xcodebuild -project PodcastEnglishStudio.xcodeproj \
  -scheme PodcastEnglishStudio \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project PodcastEnglishStudio.xcodeproj \
  -scheme PodcastEnglishStudio \
  -sdk appletvsimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

The sample bundle identifier is `com.example.LinguaCast`. Change it and choose your own development team before installing on physical devices.

### App-side service configuration

`ios/PodcastEnglishStudio/Config/Public.xcconfig` ships public placeholder values (`YOUR_TEAM_ID`, `https://example.com`) for the Apple Developer Team ID and the three backend service URLs (`LINGUACAST_ACCOUNT_URL`, `LINGUACAST_CONTENT_SERVICE_URL`, `LINGUACAST_ASSISTANT_SERVICE_URL`), read from Info.plist at build time. To point the app at your own backend, copy `ios/PodcastEnglishStudio/Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored) and fill in your Team ID and service URLs — `Public.xcconfig` includes it automatically when present. Similarly, `ExportOptions-TestFlight*.plist.example` are templates for your own TestFlight export configuration; copy them without the `.example` suffix and fill in your Team ID and provisioning profile name.

## Run the backend

The fastest path is the included self-host stack:

```bash
cd deploy/self-host
cp .env.example .env
./init-env.sh selfhost   # or: apple, if you have Sign in with Apple configured
docker compose config --quiet
docker compose up -d --build
./verify.sh
```

See [`deploy/self-host/README.md`](deploy/self-host/README.md) for the full walkthrough, including the `apple` identity mode, backup/restore, and required provider credentials (DashScope, a translation provider, Cloudflare R2, and research-assistant model credentials).

Point the app at your server from Settings → Server, using the address and token `verify.sh` prints. If you'd rather implement your own backend instead of running `deploy/self-host/`, the OpenAPI and JSON Schema contracts in `docs/contracts/` describe the wire format each service expects.

## Optional local media service

Only needed for YouTube playback modes that require server-side media preparation; not required for the app's default playback paths.

```bash
cd tools/local-youtube-media-service
cp .env.example .env
# Set AUTH_TOKEN and PUBLIC_BASE_URL in .env
docker compose up --build
curl http://127.0.0.1:3210/health
```

For local Node development:

```bash
npm ci
npm test
npm run typecheck
npm run build
AUTH_TOKEN=replace-with-a-random-token npm start
```

Configure the app with the service base URL and bearer token on-device. Prefer HTTPS outside a trusted LAN. Do not expose the service without authentication, resource limits, monitoring, and an authorization review for the media being processed.

## Optional CloudKit sync

CloudKit is disabled when `LinguaCastCloudKitContainerIdentifier` is empty. To opt in:

1. Create your own iCloud container and App ID in the Apple Developer portal.
2. Change the sample bundle identifier and select your development team.
3. Use the `PodcastEnglishStudio-CloudKit` scheme.
4. Set `ICLOUD_CONTAINER_IDENTIFIER` to your container identifier, for example `iCloud.com.example.LinguaCast`, in your private `.xcconfig`, Xcode user settings, or build command.
5. Enable iCloud/CloudKit and remote-notification capabilities for your App ID and deploy the required CloudKit schema.

Do not commit your team ID, provisioning profile, or production container identifier. The included entitlement file references the build setting rather than a personal container.

## Tests

```bash
# Swift
(cd ios/PodcastEnglishStudio && swift test)
(cd Packages/CloudSyncKit && swift test)
(cd Packages/DomainModels && swift test)
(cd Packages/PlayerKit && swift test)
(cd Packages/ChineseTTS && swift test)

# Node services and media tool
for svc in services/account-service services/content-pipeline services/research-assistant tools/local-youtube-media-service; do
  (cd "$svc" && npm ci && npm run typecheck && npm test && npm run build)
done

# Self-host compose validation
(cd deploy/self-host && for mode in selfhost apple; do ./init-env.sh "$mode" "/tmp/$mode.env" && docker compose -f docker-compose.yml --env-file "/tmp/$mode.env" config --quiet; done)
```

GitHub Actions runs the Swift package tests and unsigned iOS/tvOS builds (`ci.yml`) plus the Node service tests and self-host compose validation (`services.yml`) on every push and pull request.

## Security and legal notice

Read [SECURITY.md](SECURITY.md) before deployment. Keep all credentials out of Git and rotate any value that may have been exposed.

YouTube, Apple, CloudKit, and third-party provider names are trademarks of their respective owners. This project is unaffiliated with them. You are responsible for complying with platform terms, copyright, privacy, export, and local law. The optional yt-dlp service must only be used for media you are authorized to access and process.

## License

MIT © 2026 lxd930808. See [LICENSE](LICENSE) for the app and packages, and [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for third-party dependencies and tools (yt-dlp, the bgutil PO Token provider, Caddy, ffmpeg, ripgrep, and npm dependencies).

## Snapshot update

This snapshot replaces the pre-backend architecture (on-device provider API keys) with the current server-backed design: account sign-in, and `account-service` / `content-pipeline` / `research-assistant` behind `deploy/self-host/`. It includes the V17 interface refresh, cloud playback and translation recovery, research-assistant client flows, and optional Chinese speech synthesis. Private deployment infrastructure, original development history, and model weights are excluded. Content and assistant endpoints use `example.com` placeholders by default (see "App-side service configuration" above); configure your own services before enabling these features. See [ChineseTTS](Packages/ChineseTTS/README.md) for model provisioning details.
