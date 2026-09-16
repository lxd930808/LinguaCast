#!/usr/bin/env bash
# Restore a verified self-host backup into a scratch directory or into NEW volumes.
# Deletions recorded after the backup was taken are replayed from a tombstone source,
# so restored data of deleted accounts is purged again by the account service.
#
# Usage:
#   ./restore.sh backup.tar <scratch-dir>
#   LOAD_VOLUMES=1 VOLUME_PREFIX=linguacast-selfhost-restore ./restore.sh backup.tar
# Tombstone source (strongly recommended whenever a newer account database exists):
#   TOMBSTONES_DB=<path to the newer account.db>
#   TOMBSTONES_FROM_LIVE=1     read the live ${COMPOSE_PROJECT:-linguacast-selfhost}_account-data volume
# The live volume prefix is refused unless RESTORE_CLOBBER_LIVE=1 after a verified scratch restore.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "$HERE/.." && pwd)"
SRC="${1:?usage: restore.sh backup.tar [scratch-dir]}"
SCRATCH="${2:-}"
LIVE_PREFIX="${COMPOSE_PROJECT:-linguacast-selfhost}"
VOLUME_PREFIX="${VOLUME_PREFIX:-${LIVE_PREFIX}-restore}"
LIB="$HERE/lib/selfhost-backup.mjs"

if [[ -z "$SCRATCH" && "${LOAD_VOLUMES:-0}" != "1" ]]; then
  echo "usage: restore.sh backup.tar <scratch-dir>  OR  LOAD_VOLUMES=1 restore.sh backup.tar" >&2
  exit 1
fi
if [[ "$VOLUME_PREFIX" == "$LIVE_PREFIX" && "${RESTORE_CLOBBER_LIVE:-0}" != "1" ]]; then
  echo "refusing to restore onto the live volume prefix (set RESTORE_CLOBBER_LIVE=1 only after a verified scratch restore)" >&2
  exit 1
fi

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/restore"
if [[ -d "$SRC" ]]; then
  cp -R "$SRC/." "$TMP/restore/"
else
  tar -C "$TMP/restore" -xf "$SRC"
fi

run_lib() {
  if command -v node >/dev/null 2>&1 && node -e "require('node:sqlite')" >/dev/null 2>&1; then
    node "$LIB" "$@"
  else
    docker run --rm -v "$DEPLOY_ROOT:/opt/deploy:ro" -v "$TMP:$TMP" node:22-bookworm-slim \
      node /opt/deploy/self-host/lib/selfhost-backup.mjs "$@"
  fi
}

run_lib verify --root "$TMP/restore"

# Replay deletions from the newer account database before anything is loaded.
if [[ -n "${TOMBSTONES_DB:-}" ]]; then
  cp "$TOMBSTONES_DB" "$TMP/live-account.db"
  run_lib tombstones-export --database "$TMP/live-account.db" --out "$TMP/tombstones-live.json"
elif [[ "${TOMBSTONES_FROM_LIVE:-0}" == "1" ]]; then
  docker run --rm -v "${LIVE_PREFIX}_account-data:/live:ro" -v "$DEPLOY_ROOT:/opt/deploy:ro" -v "$TMP:/work" \
    node:22-bookworm-slim node /opt/deploy/self-host/lib/selfhost-backup.mjs tombstones-export \
      --database /live/account.db --out /work/tombstones-live.json
else
  echo "WARN no newer tombstone source given; deletions made after this backup will not be replayed" >&2
fi
if [[ -f "$TMP/tombstones-live.json" ]]; then
  run_lib tombstones-apply --database "$TMP/restore/account/account.db" --in "$TMP/tombstones-live.json"
fi

if [[ -n "$SCRATCH" ]]; then
  mkdir -p "$SCRATCH"
  cp -R "$TMP/restore/." "$SCRATCH/"
  echo "restore extracted to scratch (live volumes untouched)"
fi

if [[ "${LOAD_VOLUMES:-0}" == "1" ]]; then
  for volume in account-data content-data assistant-data assistant-workspaces assistant-global-memory assistant-shared-versions; do
    docker volume create "${VOLUME_PREFIX}_${volume}" >/dev/null
  done
  docker run --rm \
    -v "${VOLUME_PREFIX}_account-data:/volumes/account" \
    -v "${VOLUME_PREFIX}_content-data:/volumes/content" \
    -v "${VOLUME_PREFIX}_assistant-data:/volumes/assistant" \
    -v "${VOLUME_PREFIX}_assistant-workspaces:/volumes/workspaces" \
    -v "${VOLUME_PREFIX}_assistant-global-memory:/volumes/global-memory" \
    -v "${VOLUME_PREFIX}_assistant-shared-versions:/volumes/shared-versions" \
    -v "$TMP/restore:/backup:ro" \
    node:22-bookworm-slim bash -c '
      set -euo pipefail
      cp /backup/account/account.db /volumes/account/account.db
      cp /backup/content/content.db /volumes/content/content.db
      cp /backup/assistant/assistant.db /volumes/assistant/assistant.db
      for d in workspaces global-memory shared-versions; do
        if [ -d "/backup/assistant/$d" ]; then cp -R "/backup/assistant/$d/." "/volumes/$d/"; fi
      done
      chown -R 1000:1000 /volumes'
  echo "restore loaded into volume prefix ${VOLUME_PREFIX} (live volumes untouched)"
fi
