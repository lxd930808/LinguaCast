#!/usr/bin/env bash
# Verify a self-host backup archive or extracted directory. Never touches live volumes.
# Usage: ./restore-verify.sh <backup.tar|backup-dir>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$HERE/.." && pwd)"
SRC="${1:?usage: restore-verify.sh backup.tar|backup-dir}"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

if [[ -d "$SRC" ]]; then
  ROOT="$(cd "$SRC" && pwd)"
else
  tar -C "$TMP" -xf "$SRC"
  ROOT="$TMP"
fi

if command -v node >/dev/null 2>&1 && node -e "require('node:sqlite')" >/dev/null 2>&1; then
  node "$HERE/lib/selfhost-backup.mjs" verify --root "$ROOT"
else
  docker run --rm -v "$DEPLOY_ROOT:/opt/deploy:ro" -v "$ROOT:/backup:ro" node:22-bookworm-slim \
    node /opt/deploy/self-host/lib/selfhost-backup.mjs verify --root /backup
fi
