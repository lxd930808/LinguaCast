# LinguaCast

LinguaCast is a source-reference iOS and tvOS app for bilingual podcast and YouTube-assisted language learning. It combines subscription browsing, playback, subtitle processing, translation, local persistence, optional CloudKit synchronization, and an optional self-hosted media service.

[简体中文完整指南](docs/README.zh-CN.md)

> This repository is provided as a source reference. It is not a hosted service, supported product, or public roadmap. You must supply your own service credentials, Apple signing identity, and—if enabled—CloudKit container.

## What is included

- A SwiftUI app targeting iOS 17+ and tvOS 17+
- Shared Swift packages for domain models, playback, and optional CloudKit sync
- Podcast and YouTube subscription, catalog, playback, subtitle, and learning flows
- On-device Chinese speech synthesis (optional, with separately provisioned model assets)
- Optional content-generation and research-assistant clients using your own endpoints
- On-device Keychain-backed API configuration
- A short-lived local-network QR setup flow for non-secret Apple TV settings
- An optional Node.js 24 + yt-dlp media service with MP4/HLS preparation and Docker support

The snapshot intentionally excludes private server infrastructure, deployment credentials, signing identities, personal CloudKit identifiers, and the original repository history.

## Requirements

- macOS 26
- Xcode 26.6
- XcodeGen 2.46 or later
- Node.js 24 for the optional media service
- Docker for containerized media-service use

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
  project.yml                  XcodeGen source of truth
tools/local-youtube-media-service/
  Optional self-hosted media preparation service
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

## Configure app services

Enter provider credentials in the app's Settings UI. Secret values such as YouTube, DashScope, translation, OSS, and Minimax credentials use the Keychain-backed configuration path and should never be placed in source files or Xcode schemes.

The Apple TV QR page is deliberately limited to non-secret provider metadata, OSS location metadata, media-service address/mode, and subscription URLs. It does not render or accept API keys, OSS access keys, or media bearer tokens. The random setup link expires after 10 minutes and becomes invalid after a successful submission.

Some processing features require third-party APIs and will remain unavailable until their corresponding credentials are configured. Browsing and local data do not require CloudKit.

## Optional CloudKit sync

CloudKit is disabled when `LinguaCastCloudKitContainerIdentifier` is empty. To opt in:

1. Create your own iCloud container and App ID in the Apple Developer portal.
2. Change the sample bundle identifier and select your development team.
3. Use the `PodcastEnglishStudio-CloudKit` scheme.
4. Set `ICLOUD_CONTAINER_IDENTIFIER` to your container identifier, for example `iCloud.com.example.LinguaCast`, in your private `.xcconfig`, Xcode user settings, or build command.
5. Enable iCloud/CloudKit and remote-notification capabilities for your App ID and deploy the required CloudKit schema.

Do not commit your team ID, provisioning profile, or production container identifier. The included entitlement file references the build setting rather than a personal container.

## Optional local media service

The media service is not required for the app's default playback paths.

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

## Tests

```bash
(cd ios/PodcastEnglishStudio && swift test)
(cd Packages/CloudSyncKit && swift test)
(cd Packages/DomainModels && swift test)
(cd Packages/PlayerKit && swift test)
(cd tools/local-youtube-media-service && npm ci && npm test && npm run typecheck && npm run build)
```

GitHub Actions repeats package tests, unsigned iOS/tvOS builds on macOS 26 with Xcode 26.6, Node.js 24 checks, and a Docker health-check smoke test.

## Security and legal notice

Read [SECURITY.md](SECURITY.md) before deployment. Keep all credentials out of Git and rotate any value that may have been exposed.

YouTube, Apple, CloudKit, and third-party provider names are trademarks of their respective owners. This project is unaffiliated with them. You are responsible for complying with platform terms, copyright, privacy, export, and local law. The optional yt-dlp service must only be used for media you are authorized to access and process.

## License

MIT © 2026 lxd930808. See [LICENSE](LICENSE).

## Snapshot update

This snapshot includes the V17 interface refresh, cloud playback and translation recovery updates, research-assistant client flows, and optional Chinese speech synthesis from the local source revision `6fc2bab`. Private deployment infrastructure, original development history, and model weights are excluded. Content and assistant endpoints use `example.com` placeholders; configure your own services before enabling these features. See [ChineseTTS](Packages/ChineseTTS/README.md) for model provisioning details.
