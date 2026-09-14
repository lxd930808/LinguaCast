# LinguaCast 简体中文指南

LinguaCast 是一个面向 iOS 与 tvOS 的双语播客、视频辅助语言学习项目。本仓库以“源码参考”的形式发布，包含客户端、共享 Swift Package，以及可选的本地 YouTube 媒体处理服务。

> 这不是托管服务、正式发行产品或公开路线图。仓库不承诺技术支持、问题响应时间或后续维护。编译和运行需要你自己的 Apple 开发者身份、第三方服务凭据；启用 iCloud 时还需要你自己的 CloudKit 容器。

## 仓库包含什么

- iOS 17+ 与 tvOS 17+ 的 SwiftUI 客户端
- 播客和 YouTube 订阅、目录、播放、字幕与学习流程
- SwiftData 本地数据与 Keychain 凭据保存
- 可选 CloudKit 同步层
- Apple TV 局域网二维码配置页
- 基于 Node.js 24、yt-dlp、FFmpeg 的可选媒体服务
- 单元测试、双平台无签名构建和容器健康检查 CI

本次发布是从固定源码状态生成的干净快照，不带原项目 Git 历史，也不包含私有后端、部署凭据、签名身份、个人 Team ID 或个人 CloudKit 容器。

## 环境要求

- macOS 26
- Xcode 26.6
- XcodeGen 2.46 或更高版本
- 可选媒体服务需要 Node.js 24
- 使用容器时需要 Docker / Docker Compose

## 快速开始

```bash
brew install xcodegen
cd ios/PodcastEnglishStudio
xcodegen generate
open PodcastEnglishStudio.xcodeproj
```

选择 `PodcastEnglishStudio` scheme。它是默认的本地模式，不附加 CloudKit entitlement。即使未配置 iCloud，SwiftData、Keychain、订阅和本地播放相关能力仍可工作。

在模拟器上验证：

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

示例 Bundle ID 是 `com.example.LinguaCast`。安装到真机前，请改成你控制的标识并在 Xcode 中选择自己的开发者 Team。不要把 Team ID 或描述文件提交到仓库。

## 第三方服务和密钥

翻译、语音识别、对象存储等功能可能需要第三方服务。请在 App 的“设置”页面中录入凭据；敏感配置通过 Keychain 路径保存。

不要把以下内容写进源码、scheme 环境变量、README、截图或提交记录：

- YouTube / DashScope / 翻译 / Minimax API Key
- OSS Access Key ID 与 Secret
- 媒体服务 Bearer Token
- Apple Team ID、签名证书、描述文件
- 生产 CloudKit 容器、数据库或部署凭据

Apple TV 二维码配置页只允许传递非敏感信息：翻译服务名称、Base URL、模型与 reasoning 级别、OSS endpoint/bucket/region、媒体服务地址与模式，以及订阅 URL。页面不会显示或接收任何 API Key、OSS Access Key 或媒体 Token。二维码中的随机访问令牌每次启动都会重新生成，10 分钟过期，成功提交后立即失效。

## 可选 CloudKit

默认 `ICLOUD_CONTAINER_IDENTIFIER` 为空，`CloudSyncCoordinator` 会进入“未配置”状态，不初始化 `CKContainer`，也不会注册远程通知。

启用步骤：

1. 在 Apple Developer 后台创建自己的 App ID 与 iCloud Container。
2. 修改示例 Bundle ID，并选择自己的 Team。
3. 在 Xcode 中选择 `PodcastEnglishStudio-CloudKit` scheme。
4. 在不提交到 Git 的私有 `.xcconfig`、Xcode 用户级设置或构建命令中设置：

   ```text
   ICLOUD_CONTAINER_IDENTIFIER=iCloud.com.example.LinguaCast
   ```

5. 为 App ID 开启 iCloud / CloudKit 和远程通知能力。
6. 根据 `CloudSyncKit` 使用的 zone、record type 与字段，在你自己的开发环境验证并部署 CloudKit schema。

entitlements 文件使用构建变量，不含作者个人容器。若变量为空，请继续使用默认 scheme；不要用带空容器标识的 CloudKit scheme 做归档。

## Apple TV 局域网配置安全

二维码页面通过 Apple TV 临时启动的 HTTP 服务工作，只应在可信局域网使用。实现包含以下约束：

- 随机高熵令牌，URL 与表单均需验证
- 10 分钟有效期
- 成功提交后一次性作废
- `Cache-Control: no-store`
- `Referrer-Policy: no-referrer`
- 限制内容类型嗅探和页面内容来源
- 服务端白名单再次过滤，即使手工构造 POST 也不能提交秘密字段

局域网 HTTP 仅用于设备发现和临时配置。不要把该端口映射到公网。

## 可选媒体服务

默认播放路径不依赖此服务。启用前请确认你有权访问、下载和处理目标媒体，并遵守平台条款和当地法律。

```bash
cd tools/local-youtube-media-service
cp .env.example .env
```

至少设置：

```dotenv
PUBLIC_BASE_URL=http://192.168.x.x:3210
AUTH_TOKEN=请替换为随机长字符串
```

启动：

```bash
docker compose up --build
curl http://127.0.0.1:3210/health
```

本地 Node 模式：

```bash
npm ci
npm test
npm run typecheck
npm run build
AUTH_TOKEN=请替换为随机长字符串 npm start
```

在 App 设备端填写 Base URL 和 Token。离开可信局域网时应使用 HTTPS，并配置防火墙、访问日志、磁盘配额、任务并发、数据保留和令牌轮换。不要在未鉴权状态下暴露服务。

## 测试与验证

```bash
(cd ios/PodcastEnglishStudio && swift test)
(cd Packages/CloudSyncKit && swift test)
(cd Packages/DomainModels && swift test)
(cd Packages/PlayerKit && swift test)
(cd tools/local-youtube-media-service && npm ci && npm test && npm run typecheck && npm run build)
```

修改 Xcode 工程配置后先运行 `xcodegen generate`，再执行 iOS 与 tvOS 两个无签名构建。提交前还应搜索真实域名、IP、Team ID、CloudKit 标识和密钥格式。

## 许可证与责任

代码以 MIT 许可证发布，版权归 `lxd930808`。软件按原样提供，不含任何担保。

YouTube、Apple、CloudKit 及第三方服务名称归各自权利人所有，本项目与它们没有隶属或授权关系。仓库使用者和部署者自行承担账号、内容授权、版权、隐私、安全、出口与合规责任。

## 本次快照更新

本次同步本地版本 `6fc2bab` 的 V17 界面、云端播放与翻译恢复、研究助手客户端及可选中文语音合成功能。保留开源版的本地模式、签名占位配置和设置接口安全限制；不包含私有部署目录、原始开发历史和模型权重。内容服务及研究助手地址使用 `example.com` 占位，启用前需配置自己的服务。中文语音模型要求见 [ChineseTTS](../Packages/ChineseTTS/README.md)。
