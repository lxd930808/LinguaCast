# LinguaCast Apple client

This directory contains the shared iOS/tvOS application and its testable core package.

The Xcode project is generated and intentionally not committed:

```bash
xcodegen generate
open PodcastEnglishStudio.xcodeproj
```

`project.yml` is the source of truth. The default `PodcastEnglishStudio` scheme uses local storage without CloudKit entitlements. See the repository root [README](../../README.md) for complete build, credential, CloudKit, testing, and security instructions.

Useful checks:

```bash
swift test
xcodegen generate
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

Do not commit a development team, provisioning data, provider credentials, media bearer tokens, or a production CloudKit container.
