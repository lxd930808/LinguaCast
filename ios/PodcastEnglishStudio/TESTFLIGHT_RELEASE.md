# LinguaCast TestFlight 发布操作手册

本文记录 LinguaCast 从 Xcode 归档到 App Store Connect / TestFlight 可用的完整流程。默认以 Xcode 图形界面操作为主，同时保留命令行验证与上传方式，便于排障和自动化。

> 本文适用于当前工程 `PodcastEnglishStudio.xcodeproj`。iOS 与 tvOS 是两个独立的 TestFlight 平台构建，必须分别选择目标、归档和上传。
>
> **注意（XcodeGen）**：`PodcastEnglishStudio.xcodeproj` 由 `project.yml` 经 `xcodegen generate` 生成、不入库。归档/上传前请先执行 `cd ios/PodcastEnglishStudio && xcodegen generate`。build 设置（签名、版本、tvOS 条件项）以 `project.yml` 为准，不要直接改 `.xcodeproj`。

## 1. 当前项目发布参数

| 参数 | 当前值 |
| --- | --- |
| App Store Connect App | LinguaCast 双语听译 |
| Bundle ID | `com.local.PodcastEnglishStudio` |
| Apple Developer Team ID | `YOUR_TEAM_ID`(实际值维护在 `ios/PodcastEnglishStudio/Config/Local.xcconfig`,不入库,模板见 `Config/Local.xcconfig.example`) |
| Xcode Scheme | `PodcastEnglishStudio` |
| iCloud Container | `iCloud.com.local.PodcastEnglishStudio` |
| 工程文件 | `PodcastEnglishStudio.xcodeproj`（由 `project.yml` + `xcodegen generate` 生成，不入库） |
| iOS Info.plist | `PodcastEnglishStudio/Support/Info.plist` |
| tvOS Info.plist | `PodcastEnglishStudio/Support/Info-tvOS.plist` |
| TestFlight 页面 | App Store Connect → Apps → 对应 App → TestFlight(具体链接因团队而异,不在此列出) |

这些标识不是密码，但如果 Apple Developer 团队、App Store Connect App 或 Bundle ID 发生变化，必须同步更新工程、签名和导出配置。

## 2. 每次发布前检查

### 2.1 检查代码和构建

在仓库根目录执行（先重新生成工程）：

```bash
cd ios/PodcastEnglishStudio
xcodegen generate
swift test

xcodebuild \
  -project PodcastEnglishStudio.xcodeproj \
  -scheme PodcastEnglishStudio \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project PodcastEnglishStudio.xcodeproj \
  -scheme PodcastEnglishStudio \
  -configuration Release \
  -destination 'generic/platform=tvOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

如果本次只发布 iOS，可以暂时不执行 tvOS 构建；反之亦然。无签名构建只能验证编译，不能替代正式归档。

### 2.2 更新版本号和构建号

在 Xcode 中选中：

1. 左侧项目 `PodcastEnglishStudio`。
2. `TARGETS` → `PodcastEnglishStudio` → `General`。
3. 更新 `Version`，例如 `0.1` → `0.2`。
4. 将 `Build` 递增，例如 `1` → `2`。

规则：

- `Version` 是用户看到的版本号，对应 `MARKETING_VERSION`。
- `Build` 是上传构建号，对应 `CURRENT_PROJECT_VERSION`。
- 同一平台、同一 Version 下，App Store Connect 不接受重复的 Build。
- iOS 与 tvOS 虽然可使用相同版本号，但每个平台仍需分别归档、上传和检查。

提交前可以确认工程值：

```bash
xcodebuild \
  -project PodcastEnglishStudio.xcodeproj \
  -scheme PodcastEnglishStudio \
  -showBuildSettings \
  | rg 'MARKETING_VERSION|CURRENT_PROJECT_VERSION|PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM'
```

### 2.3 检查签名与 Capabilities

在 `TARGETS` → `PodcastEnglishStudio` → `Signing & Capabilities` 中确认：

- Team 为正确的开发者团队。
- Bundle Identifier 为 `com.local.PodcastEnglishStudio`。
- `Automatically manage signing` 正常情况下保持开启。
- iCloud / CloudKit 容器为 `iCloud.com.local.PodcastEnglishStudio`。
- Push Notifications 已启用。
- Release 使用 Apple Distribution 签名。

首次发布或证书过期时：

1. Xcode → `Settings` → `Accounts`。
2. 选中 Apple ID 和 Team。
3. 点击 `Manage Certificates`。
4. 新建 `Apple Distribution` 证书。

不要把私钥、`.p12`、API Key、App Store Connect 密钥或登录凭据提交到 Git。

### 2.4 检查 CloudKit Production

LinguaCast 使用 CloudKit。首次正式分发前必须在 CloudKit Console 中确认：

- `LCConfiguration`
- `LCPodcastSubscription`
- `LCYouTubeSubscription`
- `LCSubtitleArtifact`

这些 Development Schema 已部署到 Production。API Key/Secret 对应字段应保持加密字段类型。

如果只在开发环境创建过记录类型、未部署到 Production，TestFlight 安装包可能能启动，但云同步会失败。

### 2.5 出口合规设置

当前 App 只使用 Apple 操作系统提供的加密能力：

- `URLSession` / HTTPS
- CloudKit
- CryptoKit 的 SHA-256 哈希
- CryptoKit 的 HMAC-SHA1 请求签名

没有使用自带 OpenSSL、VPN、专有算法或替代 Apple 系统实现的加密库。按 Apple 当前规则，不需要上传出口合规文稿。建议在 iOS 和 tvOS 的 Info.plist 中都设置：

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

这样后续上传通常不会再次出现“缺少出口合规证明”。如果以后引入非 Apple 系统提供的加密库、自定义加密、VPN 或安全通信实现，必须重新评估，不能继续机械沿用 `false`。

Apple 官方说明：

- [Complying with Encryption Export Regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
- [Export compliance documentation for encryption](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)

## 3. 使用 Xcode 发布 iOS TestFlight

### 3.1 选择正确目标

1. 用 Xcode 打开 `PodcastEnglishStudio.xcodeproj`。
2. Scheme 选择 `PodcastEnglishStudio`。
3. 运行目标选择 `Any iOS Device (arm64)` 或已连接的真机。
4. 确认当前不是 iOS Simulator。

选择模拟器时，`Product` → `Archive` 通常不可用。

### 3.2 创建 Archive

1. 菜单选择 `Product` → `Archive`。
2. 等待 Release 构建和签名完成。
3. Xcode 会自动打开 Organizer。
4. 在 `Archives` 中选中刚生成的 iOS Archive。

Archive 生成后先检查右侧信息：

- App 名称正确。
- Version / Build 正确。
- Archive 类型为 iOS App Archive。
- Team 和 Bundle ID 正确。
- 归档时间是本次操作时间。

### 3.3 验证并上传

在 Organizer 中：

1. 点击 `Distribute App`。
2. 选择 `App Store Connect`。
3. 选择 `Upload`。
4. 保持上传符号文件选中。
5. 选择自动签名；如果自动签名失败，再参考本文“手动描述文件兜底”。
6. 点击 `Validate App` 或继续到 Xcode 的验证步骤。
7. 仔细检查警告和签名摘要。
8. 点击 `Upload`。
9. 看到 `Upload Successful` 后再关闭 Organizer。

“Upload Successful”只代表二进制已传到 Apple，不代表已经可以测试。

## 4. 使用 Xcode 发布 tvOS TestFlight

tvOS 必须重新归档，不能复用 iOS Archive：

1. Scheme 仍选择 `PodcastEnglishStudio`。
2. 运行目标改为 `Any tvOS Device (arm64)` 或已连接 Apple TV。
3. 选择 `Product` → `Archive`。
4. 在 Organizer 确认归档类型为 tvOS App Archive。
5. 依次选择 `Distribute App` → `App Store Connect` → `Upload`。
6. 上传完成后，在 App Store Connect 的 TestFlight 页面切换到 tvOS 平台检查处理状态。

tvOS 需要对应平台的 App Store provisioning profile。iOS 描述文件不能用于 tvOS。

归档前还应在 `Assets.xcassets` → `AppIconTV` 中确认：

- `App Icon - Small` 的 Background 和 Foreground 均包含 400×240（1x）与 800×480（2x）。
- `Top Shelf Image` 包含 1920×720（1x）与 3840×1440（2x）。
- `Top Shelf Image Wide` 包含 2320×720（1x）与 4640×1440（2x）。
- 每个 `.imageset` 都有有效的 `Contents.json`，没有空文件或被异常改名的元数据文件。

这些资源有效时，Xcode 的资产编译器会自动向最终 App 的 Info.plist 注入 `TVTopShelfImage`、`TVTopShelfPrimaryImage` 和 `TVTopShelfPrimaryImageWide`，不需要在源 Info.plist 中手写。

可以在归档前运行项目内的回归校验：

```bash
cd ios/PodcastEnglishStudio
./scripts/validate-tvos-assets.sh
```

## 5. App Store Connect 上传后处理

打开 App Store Connect → Apps → 对应 App → TestFlight(具体链接因团队而异,不在此列出)。

### 5.1 等待 Apple 处理

常见状态顺序：

1. 上传中
2. 正在处理
3. 完成 / 构建版本出现
4. 可供内部测试，或出现需要处理的合规/元数据状态

通常需要几分钟，偶尔更久。页面没有立即出现构建时，不要立刻重复上传相同 Build；先刷新页面并等待处理。

### 5.2 处理“缺少出口合规证明”

如果构建行显示“缺少出口合规证明”：

1. 点击构建旁的 `管理`。
2. 问题“你的 App 采用了哪种类型的加密算法？”选择：
   `不属于上述的任意一种算法`。
3. 点击 `保存`。
4. 在确认页再次点击 `保存`。
5. 等待页面跳转到构建详情，并确认缺失合规状态消失。

上述选择仅适用于本文“出口合规设置”所描述的当前代码。如果加密实现发生变化，应重新核对 Apple 官方规则。

### 5.3 添加内部测试员

内部测试通常不需要 TestFlight Beta App Review：

1. TestFlight 左侧 `内部测试` → 点击 `+` 新建群组。
2. 输入群组名称，例如 `Internal QA`。
3. 将刚上传的构建加入群组。
4. 添加 App Store Connect 团队成员作为测试员。
5. 测试员在设备上安装 TestFlight，并接受邀请。

### 5.4 外部测试

外部测试需要补充测试信息，并通常需要 Beta App Review：

- Beta App Description
- Feedback Email
- 联系信息
- 登录说明或测试账号（如需要）
- 审核备注

然后创建外部测试群组、添加构建并提交 Beta App Review。Apple 通过后才能邀请外部测试员或启用公开链接。

## 6. 手动描述文件兜底

仅当 Xcode 自动签名无法创建或下载 App Store 描述文件时使用。

### 6.1 创建 App Store provisioning profile

1. 打开 Apple Developer → Certificates, Identifiers & Profiles。
2. Profiles → `+`。
3. iOS 发布选择 `App Store Connect` 类型。
4. 选择 App ID `com.local.PodcastEnglishStudio`。
5. 选择有效的 Apple Distribution 证书。
6. 输入清晰的名称，例如 `LinguaCast 双语听译`。
7. 生成并下载 `.mobileprovision`。
8. 双击下载文件安装，或拖入 Xcode。
9. 返回 Xcode 刷新 Signing & Capabilities。

tvOS 发布时需要创建 tvOS 对应类型的 profile。

### 6.2 验证 profile 已安装

```bash
security find-identity -v -p codesigning

find "$HOME/Library/MobileDevice/Provisioning Profiles" \
  -type f \
  -name '*.mobileprovision' \
  -print
```

查看某个 profile 内容：

```bash
security cms -D -i '/path/to/profile.mobileprovision' \
  | plutil -p -
```

重点确认：

- `TeamIdentifier` 正确。
- `application-identifier` 与 Bundle ID 匹配。
- CloudKit、Push Notifications 等 entitlement 与 App 一致。
- profile 未过期。
- profile 包含当前 Apple Distribution 证书。

## 7. 命令行归档与上传（兜底）

仓库已提供：

- `ExportOptions-TestFlight.plist`：自动签名导出配置。
- `ExportOptions-TestFlight-Upload.plist`：当前 iOS 手动签名上传配置。
- `ExportOptions-TestFlight-tvOS-Upload.plist`：tvOS 自动签名上传配置。

### 7.1 自动签名归档

```bash
cd ios/PodcastEnglishStudio
xcodegen generate   # 生成/刷新工程（不入库）

xcodebuild \
  -project PodcastEnglishStudio.xcodeproj \
  -scheme PodcastEnglishStudio \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /private/tmp/LinguaCast-iOS-TestFlight.xcarchive \
  -allowProvisioningUpdates \
  archive
```

### 7.2 手动签名归档

自动签名失败且已安装正确 profile 时：

```bash
xcodebuild \
  -project PodcastEnglishStudio.xcodeproj \
  -scheme PodcastEnglishStudio \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /private/tmp/LinguaCast-iOS-TestFlight.xcarchive \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Apple Distribution' \
  PROVISIONING_PROFILE_SPECIFIER='YOUR_PROVISIONING_PROFILE_NAME' \
  archive
```

### 7.3 验证 Archive 签名

```bash
codesign --verify --deep --strict --verbose=2 \
  /private/tmp/LinguaCast-iOS-TestFlight.xcarchive/Products/Applications/PodcastEnglishStudio.app

codesign -d --entitlements :- \
  /private/tmp/LinguaCast-iOS-TestFlight.xcarchive/Products/Applications/PodcastEnglishStudio.app
```

重点检查：

- `get-task-allow` 为 `false`。
- `application-identifier` 正确。
- `aps-environment` 为 `production`。
- CloudKit environment 为 `Production`。
- iCloud container 正确。

### 7.4 上传 Archive

```bash
xcodebuild \
  -exportArchive \
  -archivePath /private/tmp/LinguaCast-iOS-TestFlight.xcarchive \
  -exportPath /private/tmp/LinguaCast-iOS-TestFlight-upload \
  -exportOptionsPlist ExportOptions-TestFlight-Upload.plist \
  -allowProvisioningUpdates
```

成功标志：

```text
Upload succeeded.
Uploaded PodcastEnglishStudio
** EXPORT SUCCEEDED **
```

如果 App Store profile 改名，必须同步修改 `ExportOptions-TestFlight-Upload.plist` 的 `provisioningProfiles` 值。

tvOS 上传命令：

```bash
xcodebuild \
  -exportArchive \
  -archivePath /private/tmp/LinguaCast-tvOS-TestFlight.xcarchive \
  -exportPath /private/tmp/LinguaCast-tvOS-TestFlight-upload \
  -exportOptionsPlist ExportOptions-TestFlight-tvOS-Upload.plist \
  -allowProvisioningUpdates
```

## 8. 常见问题

### `Product > Archive` 是灰色

原因通常是选中了 Simulator。改为 `Any iOS Device (arm64)` 或 `Any tvOS Device (arm64)`。

### No profiles for bundle identifier were found

- 检查 Team 和 Bundle ID。
- 开启自动签名并点击重试。
- Xcode Accounts 中刷新账号。
- 必要时按“手动描述文件兜底”创建并双击安装 profile。

### Provisioning profile doesn't include required entitlement

App ID 的 Capability、工程 entitlements 和 profile 不一致。修改 Capability 后必须重新生成 profile，旧 profile 不会自动获得新 entitlement。

### 上传成功但 TestFlight 没有构建

- 等待 Apple 处理并刷新页面。
- 确认进入了正确 Team、正确 App 和正确平台。
- 检查 Organizer 上传日志。
- 不要重复上传同一 Version + Build；需要重传时先递增 Build。

### 缺少出口合规证明

按“App Store Connect 上传后处理”完成问卷，并在下个版本的两个 Info.plist 中加入 `ITSAppUsesNonExemptEncryption = false`。

### 上传到错误的团队或 App

上传前核对：

- Team ID
- Bundle ID
- App Store Connect 登录账号
- Organizer 签名摘要

App Store Connect 根据 Bundle ID 匹配 App，上传后不能把构建移动到另一个 App。

### iOS 已上传，但 tvOS 页面没有构建

这是正常现象。iOS 与 tvOS 必须分别选择目标、创建 Archive 并上传。

### tvOS 上传报 90513 或 90709

- `90513 Missing Info.plist Key TVTopShelfImage...`：检查 Top Shelf 普通/宽幅图片和各自 `Contents.json`，不要先手写 plist 键掩盖资产问题。
- `90709 App Icon - Small ... missing ... scale value of 2`：为 Small Icon 的每个图层补齐 800×480 的 2x 图片，并在对应 `Contents.json` 的 2x 槽填写 filename。
- 修复后执行 `Product` → `Clean Build Folder`，重新创建 Archive；旧 Archive 不会自动包含新资源。

## 9. 发布完成检查清单

### 归档前

- [ ] 本次改动已完成必要测试。
- [ ] Release 的 iOS/tvOS 无签名构建通过。
- [ ] Version 正确。
- [ ] Build 已递增。
- [ ] Team、Bundle ID 正确。
- [ ] Apple Distribution 证书有效。
- [ ] Provisioning profile 有效并包含正确 entitlement。
- [ ] CloudKit Production 中已核对 `LCConfiguration`、`LCPodcastSubscription`、`LCYouTubeSubscription`、`LCSubtitleArtifact` 及其索引。
- [ ] 已重新评估出口合规状态。

### 上传后

- [ ] Xcode Organizer 显示 Upload Successful。
- [ ] App Store Connect 出现正确平台的 Version / Build。
- [ ] Apple 处理完成。
- [ ] 没有“缺少出口合规证明”。
- [ ] 构建已加入正确的内部或外部测试群组。
- [ ] 测试员可以在 TestFlight 中看到并安装构建。
- [ ] 在真机完成启动、登录/同步、音频播放、字幕、后台播放等关键冒烟测试。

## 10. 本次已验证记录

### iOS 记录

2026-07-18 已实际走通：

- 平台：iOS
- Version：`0.1`
- Build：`1`
- 上传结果：成功
- App Store Connect 处理：完成
- 出口合规：已按“仅使用 Apple 操作系统提供的加密能力”完成声明

2026-07-19 已修复 iOS `0.2 (1)` TestFlight 的 CloudKit 同步：Development Schema 已部署到 Production，四个 `LC*` 记录类型及索引均已在 Production 复核。

### tvOS 记录

2026-07-19 已实际走通：

- 平台：Apple tvOS
- Version：`0.2`
- Build：`1`
- 原始阻塞：`90513` 缺少 Top Shelf Wide plist 键、`90709` 缺少 Small Icon Background 2x
- 修复：补齐 Small Icon 前景/背景 2x、普通/宽幅 Top Shelf 1x/2x 和资产元数据
- 资产回归：`./scripts/validate-tvos-assets.sh` 通过
- 上传结果：成功
- App Store Connect 处理：完成，构建状态为“准备提交”
- 测试群组：已关联现有 `V1.0测试` 群组并显示 1 位受邀测试员
- 出口合规：Info-tvOS.plist 已声明不使用非豁免加密，未再次要求问卷

本记录证明 iOS `0.1 (1)` 与 tvOS `0.2 (1)` 的上传和处理流程已走通。真机安装及播放冒烟测试仍需在对应设备上执行。
