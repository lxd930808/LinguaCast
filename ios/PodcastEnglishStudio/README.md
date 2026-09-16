# LinguaCast iOS

Native SwiftUI iOS/tvOS client for local-first Podcast + YouTube bilingual subtitle playback.

TestFlight 归档、签名、上传、出口合规和测试员配置流程见 [TESTFLIGHT_RELEASE.md](TESTFLIGHT_RELEASE.md)。

## What Is Included

- SwiftUI app with four tabs: Home, Programs, Subscriptions, Settings.
- SwiftData local storage for Podcast subscriptions, YouTube channels, episodes, videos, and bilingual subtitle segments.
- Keychain-backed settings for user-owned API keys.
- Private CloudKit synchronization for settings, API keys, Podcast subscriptions, and YouTube channels across iOS and tvOS.
- Local pipeline runner:
  - resolves Apple Podcasts/RSS feeds,
  - downloads direct audio enclosures with `URLSession`,
  - uploads source audio to Aliyun OSS with signed requests,
  - submits DashScope ASR jobs,
  - translates segments through an OpenAI-compatible chat API,
  - builds local bilingual subtitle segment packs,
  - caches JSON artifacts and `source.mp3` under Application Support.
- AVPlayer-based bilingual episode reader with transcript sync, segment jump, progress seeking, 15-second skips, and playback speed.
- YouTube channel/video flow with playback progress, subtitle fetching, and bilingual overlay.
- SwiftPM-compatible core tests for parser, subtitle pack generation, and playback policies.

## Open

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) and is **not** committed. After cloning or pulling, regenerate it first:

```bash
cd ios/PodcastEnglishStudio
brew install xcodegen   # once
xcodegen generate
```

Then open the generated `PodcastEnglishStudio.xcodeproj` in Xcode 16 or later and run the `PodcastEnglishStudio` scheme on an iOS 17+ simulator or device. Any change to targets, sources, or build settings is made in `project.yml` (not in the `.xcodeproj`), followed by `xcodegen generate`.

The shipped app name is localized:

- Default / English display name: `LinguaCast`
- Simplified Chinese display name: `LinguaCast 双语听译`
- Recommended English App Store subtitle: `Bilingual YouTube & Podcast Player`
- Recommended Simplified Chinese App Store subtitle: `YouTube 与播客双语翻译播放器`

The same shared scheme is generated for both iOS and tvOS builds. Pick an iOS simulator/device or an Apple TV simulator/device in Xcode, or build from the command line (run `xcodegen generate` first):

```bash
cd ios/PodcastEnglishStudio
xcodebuild -project PodcastEnglishStudio.xcodeproj -scheme PodcastEnglishStudio -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project PodcastEnglishStudio.xcodeproj -scheme PodcastEnglishStudio -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build
```

The current machine only has Command Line Tools selected, so `xcodebuild` cannot validate the iOS target until full Xcode is selected:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## CI Gate

Before merging, run the gate (regenerates the project, runs `swift test`, and builds iOS + tvOS unsigned):

```bash
./scripts/ci-gate.sh          # full: swift test + iOS build + tvOS build
./scripts/ci-gate.sh --fast   # swift test only
```

## Layout (modular, agent-parallel)

```
ios/PodcastEnglishStudio/
├── project.yml                 # XcodeGen spec (single source of truth for the project)
├── PodcastEnglishStudioCore/   # pure logic: RSS/YT parsing, CloudSyncCore, LearningCore
├── PodcastEnglishStudio/
│   ├── Features/               # UI, grouped by feature
│   │   ├── Podcast/            #   Today / Episodes / EpisodeDetail(+iOS/+tvOS/ViewModel)
│   │   ├── Player/             #   YTPlayer / YTVideoPlayerScreen(+iOS/+tvOS/ViewModel), DualSubtitleOverlay
│   │   ├── Subscription/       #   Subscriptions / YTSubscriptions / YTChannelDetail / YTAccount
│   │   ├── Settings/  Setup/  Root/
│   └── Services/               # app services (pipeline, cloud clients, stores)
└── Packages (../../Packages)
    ├── DomainModels/           # SwiftData @Model entities + shared DTO
    ├── PlayerKit/              # audio playback controller
    └── CloudSyncKit/           # iCloud sync coordinator + settings cluster
```

UI files with large platform differences are split into `XxxView+iOS.swift` / `XxxView+tvOS.swift`
with shared logic in `XxxViewModel.swift` (no `#if`). Ownership & parallel-dev rules:
`docs/OWNERSHIP_MAP.md` and `docs/AGENT_CONTRACT.md`.

## Test Core Logic

The pure Swift core can be tested without building the iOS app:

```bash
cd ios/PodcastEnglishStudio
swift test
```

## First-Run Setup

In the app Settings tab, fill:

- YouTube Data API Key
- DashScope API Key
- Translation Provider and API Key. Supported providers: DashScope (qwen), DeepSeek, Cerebras, and OpenRouter (default `https://openrouter.ai/api/v1`, model `~openai/gpt-latest`). You supply your own API key for the chosen provider; no keys are embedded in the app.
- Aliyun OSS Access Key ID, Access Key Secret, Endpoint, Bucket, Region
- Optional Minimax API Key, reserved for future TTS

No developer API keys are embedded in the app.

Reasoning effort (provider-dependent) trades quality for latency and cost: higher efforts generally consume more output tokens and take longer, and each model may support only a subset of the effort levels. DashScope sends no reasoning field; OpenRouter accepts `none` through `max`, DeepSeek accepts `high`/`max`, and Cerebras accepts `low`/`medium`/`high`.

## iCloud Sync

The app uses the private CloudKit database in `iCloud.com.local.PodcastEnglishStudio`. Local Keychain and SwiftData remain the runtime stores, so playback and settings continue to work while offline or when iCloud is unavailable. Episodes, videos, subtitle files, pipeline state, and playback progress are intentionally device-local.

Before distributing a signed build:

1. Enable CloudKit and Push Notifications for the app identifier and provision both iOS and tvOS builds with the shared container.
2. Run a Development build while signed into iCloud to create the `LCConfiguration`, `LCPodcastSubscription`, `LCYouTubeSubscription`, and `LCSubtitleArtifact` record types.
3. Confirm that API-key/secret `LCConfiguration.value_*` fields are encrypted strings, while ordinary `value_*` fields and all `modifiedAt_*`/`deviceID_*` clocks are standard fields. Then deploy the Development schema to Production in CloudKit Console.

Do not create a secret `LCConfiguration.value_*` field as unencrypted; CloudKit cannot convert an existing unencrypted field to an encrypted field later.

YouTube channel and video metadata use the official YouTube Data API v3. Enable that API in Google Cloud and restrict the key to this app's bundle identifiers when distributing builds. The default YouTube Data API quota is finite, so large subscription sets or frequent refreshes may need quota review.

The iOS video view uses the official YouTube IFrame player by default. Its app-owned
landscape presentation keeps the iframe inline and reserves a separate lower region
for synchronized bilingual subtitles instead of covering the YouTube player. tvOS
has no official YouTube Data API or IFrame equivalent that exposes playable streams
to `AVPlayer`, so Apple TV playback keeps the existing compatibility resolver while
metadata comes from Data API. Public caption download is not fully migrated to
official `captions.download` because that endpoint requires OAuth authorization; the
existing caption fetch and translation pipeline remains in place.

### Debug: Mac local SABR media service

For AVPlayer high-quality verification only, a Debug build can opt into the Mac-local
media service under `tools/local-youtube-media-service/`. Start the service on the Mac,
then set these Scheme environment variables:

```text
YT_PLAYBACK_BACKEND=local-service
YT_LOCAL_MEDIA_BASE_URL=http://<mac-lan-ip>:3210
YT_LOCAL_MEDIA_TOKEN=<token printed at startup>
YT_LOCAL_MEDIA_MODE=hls
```

Use `mp4` for complete-then-play, or `hls` for stream-while-fetching (job becomes
ready after the first fMP4 init/segment). On failure, Debug builds show the error and
a button to fall back to the official iframe. Unset or misconfigured values keep the
iframe path. Release builds ignore this backend.

When an MP4 job is ready and native YouTube captions are unusable, the iPhone
audio-ASR action first downloads the job's independent `audio.m4a` from the local
service. It then uses the existing DashScope ASR and translation pipeline to build
the bilingual subtitle files. If that local audio is unavailable, the app retains
the YouTubeKit audio-only fallback. Apple TV remains display-only for this generation
path and consumes subtitle artifacts generated on iPhone.

## Git Maintenance

The repository tracks the iOS/tvOS source, `project.yml` (the XcodeGen spec), root and local `Package.swift` manifests, the `Packages/` modules, assets, plists, and entitlements. The `PodcastEnglishStudio.xcodeproj` is generated from `project.yml` by `xcodegen generate` and is **not** committed; the scheme is declared in `project.yml` rather than checked in.

Local build output and machine-specific Xcode state are ignored, including the generated `.xcodeproj`, `.build/`, `.swiftpm/`, `DerivedData/`, `xcuserdata/`, `*.xcuserstate`, and generated run artifacts. This keeps branch switches focused on source and project changes.

Suggested branch flow:

```bash
git switch -c codex/ios-feature-name
git status --short
git add .gitignore .gitattributes ios/PodcastEnglishStudio
git commit -m "Add iOS and tvOS Git support"
```

## Scope Notes

- The first version supports podcasts with direct RSS audio enclosures.
- It does not migrate `vget`, `yt-dlp`, `ffmpeg`, or the Python downloader fallback chain.
- It does not generate a Chinese TTS merged MP3 by default.
- New content reminders are in-app only; APNs is intentionally out of scope for the first version.
