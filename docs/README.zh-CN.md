# LinguaCast 简体中文指南

LinguaCast 是一个面向 iOS 与 tvOS 的双语播客、视频辅助语言学习项目。本仓库以"源码参考"的形式发布,包含客户端、共享 Swift Package,以及它依赖的可自建后端。

> 这不是托管服务、正式发行产品或公开路线图。仓库不承诺技术支持、问题响应时间或后续维护。编译和运行需要你自己的 Apple 开发者身份、第三方服务凭据,以及一套后端部署(用仓库自带的 `deploy/self-host/` 自建,或者按 `docs/contracts/` 里的接口契约自己实现一套兼容后端);启用 iCloud 时还需要你自己的 CloudKit 容器。

## 仓库包含什么

- iOS 17+ 与 tvOS 17+ 的 SwiftUI 客户端,以及共享 Swift Package(领域模型、播放、可选 CloudKit 同步)
- 播客和 YouTube 订阅、目录、播放、字幕、翻译与学习流程
- 可选的设备端中文语音合成(需要单独准备模型资产)
- 三个 Node.js 后端服务:`account-service`(登录、会话、账户配置、每日额度)、`content-pipeline`(转写、翻译、字幕打包)、`research-assistant`(研究助手工作区 API)
- 可选的本地 YouTube 媒体准备服务(`tools/local-youtube-media-service`),支持 Docker
- 完整的 `deploy/self-host/` Docker Compose 部署栈,把上面四个服务加 Caddy(HTTPS)和一个 PO Token provider 旁路容器,一次性搭在同一台主机上
- Apple TV 局域网二维码配置页(只传递非敏感信息)
- 接口契约文档(`docs/contracts/`),如果你想自己实现一套兼容后端而不是用 `deploy/self-host/`

**App 离开后端什么都做不了**(除了播放已经下载好的本地内容)——设备端没有转写、翻译或研究助手的离线兜底路径。本次快照排除了作者自己生产环境的部署基础设施、凭据、签名身份、个人 CloudKit 标识,以及原始仓库的开发历史。

## 环境要求

- App:macOS 26、Xcode 26.6、XcodeGen 2.46 或更高版本
- 后端服务与媒体工具:Node.js 22+
- 自建部署:Docker Engine 24+、Docker Compose v2

## 仓库目录结构

```text
Packages/
  CloudSyncKit/       可选 CloudKit 同步与 App 设置
  ChineseTTS/         中文语音规划、合成与本地音频存储
  DomainModels/       共享 SwiftData 模型
  PlayerKit/          音频播放层
ios/PodcastEnglishStudio/
  PodcastEnglishStudio/       iOS/tvOS 客户端
  PodcastEnglishStudioCore/   可测试的共享策略与工具
  Config/                     公开占位配置 + 本地覆盖模板(见下文)
  project.yml                 XcodeGen 工程描述的唯一权威来源
services/
  account-service/            登录、会话、账户配置、额度
  content-pipeline/           转写、翻译、字幕打包
  research-assistant/         研究助手工作区 API
tools/local-youtube-media-service/
  可自建的媒体准备服务(也可独立使用)
deploy/
  self-host/                  完整后端的 Docker Compose 部署栈
  research-assistant/lib/     self-host 部署栈用到的备份/恢复共享库
docs/contracts/
  上述服务的 OpenAPI + JSON Schema 接口契约
THIRD_PARTY_LICENSES.md       第三方依赖与工具许可证清单
```

## 快速开始(App)

```bash
brew install xcodegen
cd ios/PodcastEnglishStudio
xcodegen generate
open PodcastEnglishStudio.xcodeproj
```

选择 `PodcastEnglishStudio` scheme。它是默认的本地模式,不附加 CloudKit entitlement。即使未配置 iCloud,SwiftData、Keychain、订阅和本地播放相关能力仍可工作。

在模拟器上验证:

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

示例 Bundle ID 是 `com.example.LinguaCast`。安装到真机前,请改成你控制的标识并在 Xcode 中选择自己的开发者 Team。不要把 Team ID 或描述文件提交到仓库。

### App 端的服务配置

`ios/PodcastEnglishStudio/Config/Public.xcconfig` 里是公开占位值(`YOUR_TEAM_ID`、`https://example.com`),对应 Apple Developer Team ID 和三个后端服务地址(`LINGUACAST_ACCOUNT_URL`、`LINGUACAST_CONTENT_SERVICE_URL`、`LINGUACAST_ASSISTANT_SERVICE_URL`),构建时通过 Info.plist 读取。要让 App 指向你自己的后端,把 `ios/PodcastEnglishStudio/Config/Local.xcconfig.example` 复制成 `Config/Local.xcconfig`(已加入 `.gitignore`),填入你的 Team ID 和服务地址——`Public.xcconfig` 会在该文件存在时自动引入它。`ExportOptions-TestFlight*.plist.example` 同理,是你自己 TestFlight 导出配置的模板,复制成去掉 `.example` 后缀的文件名并填入真实 Team ID 和描述文件名称。

## 部署后端

最快的方式是用仓库自带的自建部署栈:

```bash
cd deploy/self-host
cp .env.example .env
./init-env.sh selfhost   # 如果你已配置 Sign in with Apple,也可以用 apple 模式
docker compose config --quiet
docker compose up -d --build
./verify.sh
```

完整流程(含 `apple` 身份模式、备份恢复、所需第三方凭据:DashScope、翻译供应商、Cloudflare R2、研究助手模型凭据)见 [`deploy/self-host/README.md`](../deploy/self-host/README.md)。

部署完成后,在 App 的"设置 → 服务器"里填入 `verify.sh` 打印出的地址和 token。如果你想自己实现一套兼容后端而不用 `deploy/self-host/`,`docs/contracts/` 下的 OpenAPI 和 JSON Schema 文件描述了每个服务的接口格式。

## 可选媒体服务

只有需要服务端媒体准备的 YouTube 播放模式才用得到;默认播放路径不依赖它。启用前请确认你有权访问、下载和处理目标媒体,并遵守平台条款和当地法律。

```bash
cd tools/local-youtube-media-service
cp .env.example .env
```

至少设置:

```dotenv
PUBLIC_BASE_URL=http://192.168.x.x:3210
AUTH_TOKEN=请替换为随机长字符串
```

启动:

```bash
docker compose up --build
curl http://127.0.0.1:3210/health
```

本地 Node 模式:

```bash
npm ci
npm test
npm run typecheck
npm run build
AUTH_TOKEN=请替换为随机长字符串 npm start
```

在 App 设备端填写 Base URL 和 Token。离开可信局域网时应使用 HTTPS,并配置防火墙、访问日志、磁盘配额、任务并发、数据保留和令牌轮换。不要在未鉴权状态下暴露服务。

## 可选 CloudKit

默认 `ICLOUD_CONTAINER_IDENTIFIER` 为空,`CloudSyncCoordinator` 会进入"未配置"状态,不初始化 `CKContainer`,也不会注册远程通知。

启用步骤:

1. 在 Apple Developer 后台创建自己的 App ID 与 iCloud Container。
2. 修改示例 Bundle ID,并选择自己的 Team。
3. 在 Xcode 中选择 `PodcastEnglishStudio-CloudKit` scheme。
4. 在不提交到 Git 的私有 `.xcconfig`、Xcode 用户级设置或构建命令中设置:

   ```text
   ICLOUD_CONTAINER_IDENTIFIER=iCloud.com.example.LinguaCast
   ```

5. 为 App ID 开启 iCloud / CloudKit 和远程通知能力。
6. 根据 `CloudSyncKit` 使用的 zone、record type 与字段,在你自己的开发环境验证并部署 CloudKit schema。

entitlements 文件使用构建变量,不含作者个人容器。若变量为空,请继续使用默认 scheme;不要用带空容器标识的 CloudKit scheme 做归档。

## Apple TV 局域网配置安全

二维码页面通过 Apple TV 临时启动的 HTTP 服务工作,只应在可信局域网使用。实现包含以下约束:

- 随机高熵令牌,URL 与表单均需验证
- 10 分钟有效期
- 成功提交后一次性作废
- `Cache-Control: no-store`
- `Referrer-Policy: no-referrer`
- 限制内容类型嗅探和页面内容来源
- 服务端白名单再次过滤,即使手工构造 POST 也不能提交秘密字段

局域网 HTTP 仅用于设备发现和临时配置。不要把该端口映射到公网。

## 测试与验证

```bash
# Swift
(cd ios/PodcastEnglishStudio && swift test)
(cd Packages/CloudSyncKit && swift test)
(cd Packages/DomainModels && swift test)
(cd Packages/PlayerKit && swift test)
(cd Packages/ChineseTTS && swift test)

# Node 后端服务与媒体工具
for svc in services/account-service services/content-pipeline services/research-assistant tools/local-youtube-media-service; do
  (cd "$svc" && npm ci && npm run typecheck && npm test && npm run build)
done

# self-host Compose 配置校验
(cd deploy/self-host && for mode in selfhost apple; do ./init-env.sh "$mode" "/tmp/$mode.env" && docker compose -f docker-compose.yml --env-file "/tmp/$mode.env" config --quiet; done)
```

修改 Xcode 工程配置后先运行 `xcodegen generate`,再执行 iOS 与 tvOS 两个无签名构建。GitHub Actions 会在每次 push/PR 时跑 Swift 包测试与无签名构建(`ci.yml`),以及 Node 服务测试和 self-host Compose 校验(`services.yml`)。提交前还应搜索真实域名、IP、Team ID、CloudKit 标识和密钥格式。

## 许可证与责任

代码以 MIT 许可证发布,版权归 `lxd930808`,见 [LICENSE](../LICENSE)。第三方依赖与工具(yt-dlp、bgutil PO Token provider、Caddy、ffmpeg、ripgrep 及 npm 依赖)的许可证清单见 [THIRD_PARTY_LICENSES.md](../THIRD_PARTY_LICENSES.md)。软件按原样提供,不含任何担保。

YouTube、Apple、CloudKit 及第三方服务名称归各自权利人所有,本项目与它们没有隶属或授权关系。仓库使用者和部署者自行承担账号、内容授权、版权、隐私、安全、出口与合规责任。

## 本次快照更新

本次快照用当前的"服务端架构"替换了旧快照的"设备端直填第三方 API Key"架构:App 登录后,转写、翻译、研究助手都经由 `account-service`/`content-pipeline`/`research-assistant`(可用 `deploy/self-host/` 自建)完成,设备端不再有独立可用的离线路径。包含 V17 界面刷新、云端播放与翻译恢复、研究助手客户端及可选中文语音合成功能。不包含作者私有部署目录、原始开发历史和模型权重。内容服务及研究助手地址默认使用 `example.com` 占位(见上文"App 端的服务配置"),启用前需配置自己的服务。中文语音模型要求见 [ChineseTTS](../Packages/ChineseTTS/README.md)。
