#!/usr/bin/env bash
# Generate a self-host .env with fresh random internal secrets for one identity mode.
#
# Usage:
#   ./init-env.sh selfhost [output-file]
#   ./init-env.sh apple    [output-file]
#
# Provider credentials (DashScope, translation, R2, Apple) stay as "replace-"
# placeholders that must be edited afterwards. Generated secrets are never printed.
# An existing output file is only overwritten with FORCE=1.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:?usage: init-env.sh selfhost|apple [output-file]}"
OUT="${2:-$HERE/.env}"

if [[ "$MODE" != "selfhost" && "$MODE" != "apple" ]]; then
  echo "mode must be selfhost or apple" >&2
  exit 2
fi
if [[ -e "$OUT" && "${FORCE:-0}" != "1" ]]; then
  echo "refusing to overwrite an existing env file (set FORCE=1)" >&2
  exit 1
fi
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

secret() { openssl rand -hex 32; }

PURGE="$(secret)"
MEDIA_SIGNING="$(secret)"
ASSISTANT_TO_CONTENT="$(secret)"
CONTENT_TO_MEDIA="$(secret)"
INTROSPECT_CONTENT="$(secret)"
INTROSPECT_ASSISTANT="$(secret)"
INTROSPECT_MEDIA="$(secret)"

if [[ "$MODE" == "selfhost" ]]; then
  DEPLOYMENT_TOKEN="$(secret)"
  AUTH_MODE=selfhost
  IDENTITY=selfhost
  SELFHOST_ACCESS_TOKEN="$DEPLOYMENT_TOKEN"
  # The app sends the single deployment token to every service.
  CONTENT_SERVICE_TOKEN="$DEPLOYMENT_TOKEN"
  ASSISTANT_SERVICE_TOKEN="$DEPLOYMENT_TOKEN"
  MEDIA_AUTH_TOKEN="$DEPLOYMENT_TOKEN"
  CONTENT_MEDIA_API_TOKEN="$DEPLOYMENT_TOKEN"
  ASSISTANT_CONTENT_TOKEN="$DEPLOYMENT_TOKEN"
  CONTENT_ACCOUNT_TOKEN=
  ASSISTANT_ACCOUNT_TOKEN=
  MEDIA_ACCOUNT_TOKEN=
  ACCOUNT_CONTEXT_SIGNING_KEY=
  APPLE_TOKEN_ENCRYPTION_KEY=
else
  AUTH_MODE=apple
  IDENTITY=account
  SELFHOST_ACCESS_TOKEN=
  CONTENT_SERVICE_TOKEN=
  ASSISTANT_SERVICE_TOKEN=
  MEDIA_AUTH_TOKEN=
  # Service-to-service calls use per-caller tokens plus a signed account context.
  CONTENT_MEDIA_API_TOKEN="$CONTENT_TO_MEDIA"
  ASSISTANT_CONTENT_TOKEN="$ASSISTANT_TO_CONTENT"
  CONTENT_ACCOUNT_TOKEN="$INTROSPECT_CONTENT"
  ASSISTANT_ACCOUNT_TOKEN="$INTROSPECT_ASSISTANT"
  MEDIA_ACCOUNT_TOKEN="$INTROSPECT_MEDIA"
  ACCOUNT_CONTEXT_SIGNING_KEY="$(secret)"
  APPLE_TOKEN_ENCRYPTION_KEY="$(openssl rand -base64 32)"
fi

umask 077
sed \
  -e "s|^LINGUACAST_MODE=.*|LINGUACAST_MODE=$MODE|" \
  -e "s|^AUTH_MODE=.*|AUTH_MODE=$AUTH_MODE|" \
  -e "s|^SELFHOST_ACCESS_TOKEN=.*|SELFHOST_ACCESS_TOKEN=$SELFHOST_ACCESS_TOKEN|" \
  -e "s|^ACCOUNT_INTERNAL_TOKENS=.*|ACCOUNT_INTERNAL_TOKENS=content-pipeline:$INTROSPECT_CONTENT,research-assistant:$INTROSPECT_ASSISTANT,media-service:$INTROSPECT_MEDIA|" \
  -e "s|^ACCOUNT_PURGE_TOKEN=.*|ACCOUNT_PURGE_TOKEN=$PURGE|" \
  -e "s|^APPLE_TOKEN_ENCRYPTION_KEY=.*|APPLE_TOKEN_ENCRYPTION_KEY=$APPLE_TOKEN_ENCRYPTION_KEY|" \
  -e "s|^CONTENT_IDENTITY_MODE=.*|CONTENT_IDENTITY_MODE=$IDENTITY|" \
  -e "s|^ASSISTANT_IDENTITY_MODE=.*|ASSISTANT_IDENTITY_MODE=$IDENTITY|" \
  -e "s|^MEDIA_IDENTITY_MODE=.*|MEDIA_IDENTITY_MODE=$IDENTITY|" \
  -e "s|^CONTENT_SERVICE_TOKEN=.*|CONTENT_SERVICE_TOKEN=$CONTENT_SERVICE_TOKEN|" \
  -e "s|^ASSISTANT_SERVICE_TOKEN=.*|ASSISTANT_SERVICE_TOKEN=$ASSISTANT_SERVICE_TOKEN|" \
  -e "s|^MEDIA_AUTH_TOKEN=.*|MEDIA_AUTH_TOKEN=$MEDIA_AUTH_TOKEN|" \
  -e "s|^CONTENT_ACCOUNT_TOKEN=.*|CONTENT_ACCOUNT_TOKEN=$CONTENT_ACCOUNT_TOKEN|" \
  -e "s|^ASSISTANT_ACCOUNT_TOKEN=.*|ASSISTANT_ACCOUNT_TOKEN=$ASSISTANT_ACCOUNT_TOKEN|" \
  -e "s|^MEDIA_ACCOUNT_TOKEN=.*|MEDIA_ACCOUNT_TOKEN=$MEDIA_ACCOUNT_TOKEN|" \
  -e "s|^CONTENT_INTERNAL_CALLERS=.*|CONTENT_INTERNAL_CALLERS=research-assistant:$ASSISTANT_TO_CONTENT,account-service:$PURGE|" \
  -e "s|^ASSISTANT_INTERNAL_CALLERS=.*|ASSISTANT_INTERNAL_CALLERS=account-service:$PURGE|" \
  -e "s|^MEDIA_INTERNAL_CALLERS=.*|MEDIA_INTERNAL_CALLERS=content-pipeline:$CONTENT_TO_MEDIA,account-service:$PURGE|" \
  -e "s|^ACCOUNT_CONTEXT_SIGNING_KEY=.*|ACCOUNT_CONTEXT_SIGNING_KEY=$ACCOUNT_CONTEXT_SIGNING_KEY|" \
  -e "s|^CONTENT_MEDIA_API_TOKEN=.*|CONTENT_MEDIA_API_TOKEN=$CONTENT_MEDIA_API_TOKEN|" \
  -e "s|^ASSISTANT_CONTENT_TOKEN=.*|ASSISTANT_CONTENT_TOKEN=$ASSISTANT_CONTENT_TOKEN|" \
  -e "s|^MEDIA_URL_SIGNING_KEY=.*|MEDIA_URL_SIGNING_KEY=$MEDIA_SIGNING|" \
  "$HERE/.env.example" > "$OUT"
chmod 600 "$OUT"
echo "wrote env file for mode=$MODE; replace every value that starts with replace- before starting"
