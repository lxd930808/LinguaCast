#!/usr/bin/env bash
# Consistent backup of the self-host stack: account, content and assistant SQLite
# databases (VACUUM INTO), assistant workspace / global-memory / shared-version trees,
# and account deletion tombstones. Object-storage artifacts are not copied; the backup
# records which bucket and prefix they belong to. Output is a tar archive.
#
# Usage:
#   ./backup.sh [output.tar]
# Options:
#   BACKUP_DIR=<dir>          default ./backups
#   BACKUP_QUIESCE=1          pause the compose project while files are copied
#   SELFHOST_BACKUP_LOCAL=1   read database files from local paths instead of volumes
#                             (ACCOUNT_DB, CONTENT_DB, ASSISTANT_DB, ASSISTANT_WORKSPACES,
#                             ASSISTANT_GLOBAL_MEMORY, ASSISTANT_SHARED_VERSIONS); used for tests
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$HERE/.." && pwd)"
PROJECT="${COMPOSE_PROJECT:-linguacast-selfhost}"
ENV_FILE="${ENV_FILE:-$HERE/.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${BACKUP_DIR:-$HERE/backups}"
OUT="${1:-$BACKUP_DIR/linguacast-selfhost-$STAMP.tar}"
mkdir -p "$BACKUP_DIR" "$(dirname "$OUT")"
WORKDIR="$(mktemp -d "$BACKUP_DIR/.pack-XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

R2_ARGS=(--r2-bucket "${R2_BUCKET:-}" --r2-prefix "${R2_PREFIX:-}" --r2-environment "${R2_ENVIRONMENT:-}")

quiesce() {
  [[ "${BACKUP_QUIESCE:-0}" == "1" ]] || return 0
  docker compose -p "$PROJECT" -f "$HERE/docker-compose.yml" --env-file "$ENV_FILE" "$1" >/dev/null
}

if [[ "${SELFHOST_BACKUP_LOCAL:-0}" == "1" ]]; then
  node "$HERE/lib/selfhost-backup.mjs" pack --out "$WORKDIR/pack" --stamp "$STAMP" \
    --account-db "${ACCOUNT_DB:?ACCOUNT_DB is required in local mode}" \
    --content-db "${CONTENT_DB:?CONTENT_DB is required in local mode}" \
    --assistant-db "${ASSISTANT_DB:?ASSISTANT_DB is required in local mode}" \
    --workspaces "${ASSISTANT_WORKSPACES:-$WORKDIR/empty}" \
    --global-memory "${ASSISTANT_GLOBAL_MEMORY:-$WORKDIR/empty}" \
    --shared-versions "${ASSISTANT_SHARED_VERSIONS:-$WORKDIR/empty}" \
    "${R2_ARGS[@]}"
else
  quiesce pause
  trap 'quiesce unpause || true; cleanup' EXIT
  docker run --rm \
    -v "${PROJECT}_account-data:/volumes/account:ro" \
    -v "${PROJECT}_content-data:/volumes/content:ro" \
    -v "${PROJECT}_assistant-data:/volumes/assistant:ro" \
    -v "${PROJECT}_assistant-workspaces:/volumes/workspaces:ro" \
    -v "${PROJECT}_assistant-global-memory:/volumes/global-memory:ro" \
    -v "${PROJECT}_assistant-shared-versions:/volumes/shared-versions:ro" \
    -v "$DEPLOY_ROOT:/opt/deploy:ro" \
    -v "$WORKDIR:/backup" \
    node:22-bookworm-slim \
    node /opt/deploy/self-host/lib/selfhost-backup.mjs pack --out /backup/pack --stamp "$STAMP" \
      --account-db /volumes/account/account.db \
      --content-db /volumes/content/content.db \
      --assistant-db /volumes/assistant/assistant.db \
      --workspaces /volumes/workspaces \
      --global-memory /volumes/global-memory \
      --shared-versions /volumes/shared-versions \
      "${R2_ARGS[@]}"
  quiesce unpause
  trap cleanup EXIT
fi

tar -C "$WORKDIR/pack" -cf "$OUT" .
chmod 600 "$OUT"
echo "backup complete bytes=$(wc -c < "$OUT" | tr -d ' ') stamp=$STAMP"
