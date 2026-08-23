#!/usr/bin/env bash
#
# ci-gate.sh — 合并前必过的「QA 门禁」。
#
# 用法：
#   ./scripts/ci-gate.sh           # 全部检查（swift test + iOS build + tvOS build）
#   ./scripts/ci-gate.sh --fast    # 只跑 swift test（纯逻辑层，最快）
#   ./scripts/ci-gate.sh --builds  # 只跑 iOS + tvOS 构建（swift test 有基线失败时用）
#
# 设计目标：作为 coding agent 合并改动前的统一验收脚本，用脚本实现「QA Agent」，
# 不拟人化。任一环节失败即以非零退出码终止。
#
set -euo pipefail

# 定位到 ios/PodcastEnglishStudio（本脚本位于其 scripts/ 下）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJ_DIR}"

# 若存在 XcodeGen 工程描述则优先生成（幂等）；否则沿用已入库的 .xcodeproj。
PROJECT="PodcastEnglishStudio.xcodeproj"
SCHEME="PodcastEnglishStudio"
if [[ -f "project.yml" ]] && command -v xcodegen >/dev/null 2>&1; then
  echo "==> xcodegen generate"
  xcodegen generate --quiet
fi

run_swift_test() {
  echo "==> swift test (PodcastEnglishStudioCore)"
  swift test
}

run_build() {
  local platform="$1"   # iOS | tvOS
  echo "==> xcodebuild ${platform} (unsigned)"
  xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -destination "generic/platform=${platform}" \
    CODE_SIGNING_ALLOWED=NO \
    build | tail -n 3
}

case "${1:-all}" in
  --fast)
    run_swift_test
    ;;
  --builds)
    run_build "iOS"
    run_build "tvOS"
    ;;
  all|"")
    run_swift_test
    run_build "iOS"
    run_build "tvOS"
    ;;
  *)
    echo "未知参数: $1 (可用: --fast | --builds | all)" >&2
    exit 2
    ;;
esac

echo "==> CI 门禁全部通过 ✅"
