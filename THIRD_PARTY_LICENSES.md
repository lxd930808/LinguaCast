# 第三方依赖许可证清单

本仓库以 MIT 许可证开源(见 `LICENSE`)。以下是本项目直接使用的第三方组件及其许可证,分两类:

1. **外部命令行工具 / 容器组件**:以子进程(subprocess)或独立 Docker 镜像方式调用,不与本仓库代码链接或打包分发。
2. **npm 依赖**:随各 Node.js 服务一起安装、打包进构建产物的库。

生成日期:2026-09-16。清单基于各 `package.json` 声明的 `license` 字段与 Dockerfile 中固定的版本,未逐一核对每个依赖自带的 LICENSE 文件原文;如需精确合规审计,请按第三节命令重新生成并抽查可疑条目(如 `UNKNOWN`)。

## 1. 外部命令行工具 / 容器组件

| 组件 | 用途 / 使用位置 | 许可证 | 分发方式 | 备注 |
| --- | --- | --- | --- | --- |
| **yt-dlp** | `services/research-assistant`(Dockerfile 中 `curl` 下载独立二进制,固定 `YTDLP_VERSION=2025.10.14`);`tools/local-youtube-media-service`(`pip install "yt-dlp[default]==2026.08.19"`) | Unlicense(公有领域) | 独立可执行文件,通过 PATH 调用,不链接进本仓库代码 | 两处版本不同,升级需分别改 Dockerfile 的 `YTDLP_VERSION` |
| **bgutil-ytdlp-pot-provider**(PO Token 插件,PyPI 包 + 配套 sidecar 容器) | `tools/local-youtube-media-service` | MIT | pip 安装的 yt-dlp 插件 + 独立 sidecar Docker 镜像,不链接进本仓库代码 | 已钉版本 `2.0.0`(经生产环境核实:media-api 容器内 `pip show` 显示 `2.0.0`,sidecar 镜像 `latest` tag 的 amd64 manifest digest 与 `2.0.0` tag 一致,2026-09-16 确认) |
| **bgutils-js**(同一项目的 npm 客户端库,随 `tools/local-youtube-media-service` 打包) | 见下方 npm 依赖表 | MIT | 已计入第 2 节 npm 依赖 | 与上面的 PyPI 插件同一上游项目(Brainicism/bgutil-ytdlp-pot-provider),许可证一致 |
| **Caddy** | `deploy/self-host/docker-compose.yml`,镜像 `caddy:2.8.4-alpine` | Apache-2.0 | 官方预构建 Docker 镜像,仅作为反向代理/TLS 终端运行,不链接进本仓库代码 | — |
| **ffmpeg / ffprobe** | `services/content-pipeline`(媒体探测、MP3 标准化);`tools/local-youtube-media-service`(转码) | GPL v2+(纯 GPL 构建,不含 nonfree 组件) | 通过 `apt-get install ffmpeg` 安装的系统二进制,以子进程方式调用,不与本仓库代码静态或动态链接 | 已钉版本 `7:5.1.9-0+deb12u1`(经生产服务器核实 `dpkg -s ffmpeg`,2026-09-16)。`ffmpeg -version` 的 `configuration:` 含 `--enable-gpl`、`--enable-libx264`、`--enable-libx265`,**未见** `--enable-nonfree`/`libfdk-aac`。因为是子进程调用(aggregation,非 linking),不会把 GPL 传染到本仓库自身代码;分发容器镜像时仍需满足 ffmpeg/Debian 自身的源码可获得性义务(Debian 官方源已满足) |
| **ripgrep** | `services/research-assistant`(容器内 `apt-get install ripgrep`,供研究助手工具调用 `rg`) | MIT OR Unlicense(双许可,任选其一) | 系统二进制,子进程调用,不链接进本仓库代码 | Dockerfile 中校验版本 major ≥ 13 |

## 2. npm 依赖

以下清单由 `scripts/collect-npm-licenses.js` 扫描四个 Node 项目实际安装的 `node_modules` 生成(含直接依赖与传递依赖,以及构建期依赖,如 `typescript`/`tsx`/`esbuild`;未按 prod/dev 过滤,偏向完整披露)。共 151 条唯一 `name@version` 记录,全部为宽松许可证,**没有发现 GPL/AGPL/copyleft 依赖**。

重新生成方式:

```bash
# 先确保四个项目都已 npm install
node scripts/collect-npm-licenses.js "$(pwd)"
```

### Apache-2.0(43)
`@aws-crypto/sha256-browser@5.2.0`、`@aws-crypto/sha256-js@5.2.0`、`@aws-crypto/supports-web-crypto@5.2.0`、`@aws-crypto/util@5.2.0`、`@aws-sdk/client-bedrock-runtime@3.1048.0`、`@aws-sdk/core@3.977.9`、`@aws-sdk/credential-provider-env@3.972.70`、`@aws-sdk/credential-provider-http@3.972.72`、`@aws-sdk/credential-provider-ini@3.973.15`、`@aws-sdk/credential-provider-login@3.972.77`、`@aws-sdk/credential-provider-node@3.972.81`、`@aws-sdk/credential-provider-process@3.972.70`、`@aws-sdk/credential-provider-sso@3.973.14`、`@aws-sdk/credential-provider-web-identity@3.972.76`、`@aws-sdk/eventstream-handler-node@3.972.34`、`@aws-sdk/middleware-eventstream@3.972.29`、`@aws-sdk/middleware-websocket@3.972.52`、`@aws-sdk/nested-clients@3.997.44`、`@aws-sdk/signature-v4-multi-region@3.996.46`、`@aws-sdk/token-providers@3.1048.0`、`@aws-sdk/types@3.974.5`、`@aws-sdk/util-locate-window@3.965.10`、`@aws-sdk/xml-builder@3.972.40`、`@aws/lambda-invoke-store@0.3.0`、`@google/genai@1.52.0`、`@smithy/core@3.33.3`、`@smithy/credential-provider-imds@4.5.2`、`@smithy/fetch-http-handler@5.7.2`、`@smithy/is-array-buffer@2.2.0`、`@smithy/node-http-handler@4.7.3`、`@smithy/signature-v4@5.7.3`、`@smithy/types@4.17.2`、`@smithy/util-buffer-from@2.2.0`、`@smithy/util-utf8@2.3.0`、`ecdsa-sig-formatter@1.0.11`、`gaxios@7.3.1`、`gcp-metadata@8.1.2`、`google-auth-library@10.9.1`、`google-logging-utils@1.1.3`、`long@5.3.2`、`openai@6.40.0`、`typescript@5.9.3`、`xml-name-validator@5.0.0`

### (Apache-2.0 AND BSD-3-Clause)(1)
`@bufbuild/protobuf@2.13.0`

### BSD-2-Clause(2)
`entities@6.0.1`、`webidl-conversions@7.0.0`

### BSD-3-Clause(13)
`@protobufjs/aspromise@1.1.2`、`@protobufjs/base64@1.1.2`、`@protobufjs/codegen@2.0.5`、`@protobufjs/eventemitter@1.1.1`、`@protobufjs/fetch@1.1.1`、`@protobufjs/float@1.0.2`、`@protobufjs/path@1.1.2`、`@protobufjs/pool@1.1.0`、`@protobufjs/utf8@1.1.2`、`buffer-equal-constant-time@1.0.1`、`diff@8.0.4`、`protobufjs@7.6.6`、`tough-cookie@5.1.2`

### ISC(4)
`lru-cache@10.4.3`、`meriyah@6.1.4`、`saxes@6.0.0`、`yaml@2.9.0`

### MIT(86)
`@anthropic-ai/sdk@0.91.1`、`@asamuzakjp/css-color@3.2.0`、`@babel/runtime@7.29.7`、`@csstools/css-calc@2.1.4`、`@csstools/css-color-parser@3.1.0`、`@csstools/css-parser-algorithms@3.0.5`、`@csstools/css-tokenizer@3.0.4`、`@earendil-works/pi-agent-core@0.84.4`、`@earendil-works/pi-ai@0.84.4`、`@earendil-works/pi-telemetry@0.84.4`、`@esbuild/darwin-arm64@0.28.2`、`@esbuild/darwin-arm64@0.28.1`、`@nodable/entities@3.0.0`、`@types/jsdom@21.1.7`、`@types/node@22.20.2`、`@types/node@22.20.1`、`@types/retry@0.12.0`、`@types/tough-cookie@4.0.5`、`agent-base@7.1.4`、`anynum@1.0.1`、`base64-js@1.5.1`、`bgutils-js@3.2.0`、`bignumber.js@9.3.1`、`bowser@2.14.1`、`cssstyle@4.6.0`、`data-uri-to-buffer@4.0.1`、`data-urls@5.0.0`、`debug@4.4.3`、`decimal.js@10.6.0`、`esbuild@0.28.2`、`esbuild@0.28.1`、`extend@3.0.2`、`fast-xml-builder@1.3.1`、`fast-xml-parser@5.11.1`、`fetch-blob@3.2.0`、`fflate@0.8.3`、`formdata-polyfill@4.0.10`、`fsevents@2.3.3`、`googlevideo@4.1.1`、`html-encoding-sniffer@4.0.0`、`http-proxy-agent@7.0.2`、`https-proxy-agent@7.0.6`、`iconv-lite@0.6.3`、`ignore@7.0.5`、`is-potential-custom-element-name@1.0.1`、`is-unsafe@2.0.2`、`jsdom@26.1.0`、`json-bigint@1.0.0`、`json-schema-to-ts@3.1.1`、`jwa@2.0.1`、`jws@4.0.1`、`ms@2.1.3`、`node-domexception@1.0.0`、`node-fetch@3.3.2`、`nwsapi@2.2.24`、`p-retry@4.6.2`、`parse5@7.3.0`、`partial-json@0.1.7`、`path-expression-matcher@1.6.2`、`punycode@2.3.1`、`retry@0.13.1`、`rrweb-cssom@0.8.0`、`safe-buffer@5.2.1`、`safer-buffer@2.1.2`、`strnum@2.4.2`、`symbol-tree@3.2.4`、`tldts@6.1.86`、`tldts-core@6.1.86`、`tr46@5.1.1`、`ts-algebra@2.0.0`、`tsx@4.23.13`、`tsx@4.23.12`、`tsx@4.23.5`、`typebox@1.3.7`、`ulid@3.0.2`、`undici-types@6.21.0`、`w3c-xmlserializer@5.0.0`、`web-streams-polyfill@3.3.3`、`whatwg-encoding@3.1.1`、`whatwg-mimetype@4.0.0`、`whatwg-url@14.2.0`、`ws@8.21.3`、`ws@8.21.1`、`xml-naming@0.3.0`、`xmlchars@2.2.0`、`youtubei.js@17.2.0`

### MIT-0(1)
`@csstools/color-helpers@5.1.0`

### 0BSD(1)
`tslib@2.8.1`

## 3. 已知需要人工确认的事项

- ~~bgutil 版本未钉~~ **已解决**(2026-09-16):经生产环境(`podcast-yt-media` 项目)核实,pip 包与 sidecar 镜像实际运行的都是 `2.0.0`,已写入 `deploy/self-host/.env.example` 的 `BGUTIL_POT_PROVIDER_VERSION=2.0.0` 和 `tools/local-youtube-media-service/Dockerfile` 的 `ARG BGUTIL_POT_PROVIDER_VERSION=2.0.0`。
- ~~ffmpeg 未钉版本、构建配置未核实~~ **已解决**(2026-09-16):经生产服务器核实,`dpkg -s ffmpeg` 显示 `7:5.1.9-0+deb12u1`,已写入 `services/content-pipeline/Dockerfile` 和 `tools/local-youtube-media-service/Dockerfile` 的 `ARG FFMPEG_VERSION=7:5.1.9-0+deb12u1`。`configuration:` 已确认为纯 GPL 构建(详见第 1 节)。后续升级 Debian 基础镜像时需要重新核实这个版本号,否则 `apt-get install "ffmpeg=${FFMPEG_VERSION}"` 会因为旧版本被移出源而构建失败。
- **web 端(`web/`、`web_admin/`、`web_api/`)不在开源范围内**——已确认为产品决定(D2 相关):这三个目录本身也**没有纳入本 git 仓库**(`.gitignore` 里整体忽略),所以不存在"遗漏扫描"的问题,不需要为它们生成依赖清单。
- iOS/tvOS 客户端(SwiftPM)当前只有两个直接依赖,已知信息:`Kingfisher`(MIT)、`YouTubeKit`(alexeichhorn 维护的社区包,许可证待单独确认)。如需要正式收录进本清单,告知后可以补一节。
