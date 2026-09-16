#!/usr/bin/env bash
# Post-deploy checks for the LinguaCast self-host stack. Run on the deployment host after
#   docker compose -f docker-compose.yml --env-file .env up -d --build
# Usage: ./verify.sh [env-file]
# Prints only pass/fail lines; tokens and response bodies are never echoed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-$HERE/.env}"
[[ -f "$ENV_FILE" ]] || { echo "env file not found" >&2; exit 1; }
COMPOSE=(docker compose -f "$HERE/docker-compose.yml" --env-file "$ENV_FILE")
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

FAILED=0
ok() { echo "ok   $*"; }
fail() { echo "FAIL $*" >&2; FAILED=1; }

if grep -q '^[A-Z0-9_]*=replace-' "$ENV_FILE"; then
  fail "env file still contains replace- placeholders"
fi
"${COMPOSE[@]}" config --quiet || { echo "FAIL compose configuration is invalid" >&2; exit 1; }

# 1. Every service runs; services with a healthcheck report healthy.
for svc in account-service content-pipeline research-assistant media-service pot-provider caddy; do
  state="$("${COMPOSE[@]}" ps --format '{{.State}} {{.Health}}' "$svc" 2>/dev/null | head -1 || true)"
  case "$state" in
    "running healthy" | "running ") ok "$svc is ${state% }" ;;
    *) fail "$svc is not running and healthy (state: ${state:-missing})" ;;
  esac
done

# 2. Only Caddy publishes host ports; the PO Token provider and services stay internal.
for pair in account-service:3240 content-pipeline:3220 research-assistant:3230 media-service:3210 pot-provider:4416; do
  svc="${pair%%:*}"
  port="${pair##*:}"
  if "${COMPOSE[@]}" port "$svc" "$port" >/dev/null 2>&1; then
    fail "$svc publishes port $port on the host"
  else
    ok "$svc:$port is not published"
  fi
done

# 3. Service DNS and ports on the private network.
probe() {
  local from="$1" url="$2" expected="$3" code
  code="$("${COMPOSE[@]}" exec -T "$from" node -e \
    "fetch(process.argv[1]).then((r) => console.log(r.status)).catch(() => console.log(0))" "$url" 2>/dev/null | tail -1 || true)"
  if [[ "$code" == "$expected" ]]; then ok "$from -> $url ($code)"; else fail "$from -> $url expected $expected, got ${code:-none}"; fi
}
probe content-pipeline http://account-service:3240/v1/account-health/live 200
probe content-pipeline http://media-service:3210/health 200
probe research-assistant http://content-pipeline:3220/v1/content-health/live 200
probe research-assistant http://account-service:3240/v1/account-health/live 200
probe media-service http://pot-provider:4416/ping 200

# 4. Public HTTPS entry through Caddy, resolved to this host.
CURL=(curl -sS --max-time 15)
[[ "${CADDY_TLS:-}" == "internal" ]] && CURL+=(-k)
public() {
  local domain="$1" path="$2" expected="$3" code
  shift 3
  code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' --resolve "$domain:443:127.0.0.1" "$@" "https://$domain$path" || true)"
  if [[ "$code" == "$expected" ]]; then ok "https://$domain$path ($code)"; else fail "https://$domain$path expected $expected, got ${code:-none}"; fi
}
public "$ACCOUNT_DOMAIN" /v1/account-health/live 200
public "$ACCOUNT_DOMAIN" /internal/v1/auth/introspect 404 -X POST
public "$CONTENT_DOMAIN" /v1/content-health/live 200
public "$CONTENT_DOMAIN" /internal/v1/accounts/acc_verify/purge 404 -X POST
public "$ASSISTANT_DOMAIN" /v1/assistant-health/live 200
public "$ASSISTANT_DOMAIN" /v2/assistant/researches 401
public "$ASSISTANT_DOMAIN" /v1/assistant/sessions 404
public "$MEDIA_DOMAIN" /health 200

# 5. Client-facing responses carry addresses and capabilities only, never back-end secrets.
SECRET_VARS=(ACCOUNT_PURGE_TOKEN ACCOUNT_CONTEXT_SIGNING_KEY MEDIA_URL_SIGNING_KEY CONTENT_ACCOUNT_TOKEN
  ASSISTANT_ACCOUNT_TOKEN MEDIA_ACCOUNT_TOKEN ASSISTANT_CONTENT_TOKEN CONTENT_MEDIA_API_TOKEN
  SELFHOST_ACCESS_TOKEN DASHSCOPE_API_KEY TRANSLATION_API_KEY R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY
  APPLE_TOKEN_ENCRYPTION_KEY)
check_no_secrets() {
  local label="$1" body="$2" name value leaked=0
  for name in "${SECRET_VARS[@]}"; do
    value="${!name:-}"
    if [[ ${#value} -ge 8 && "$body" == *"$value"* ]]; then
      fail "$label contains the value of $name"
      leaked=1
    fi
  done
  [[ $leaked -eq 0 ]] && ok "$label contains no back-end secrets"
}
if [[ "${AUTH_MODE:-}" == "selfhost" ]]; then
  body="$("${CURL[@]}" --resolve "$ACCOUNT_DOMAIN:443:127.0.0.1" \
    -H "authorization: Bearer $SELFHOST_ACCESS_TOKEN" "https://$ACCOUNT_DOMAIN/v1/me/config" || true)"
  if [[ "$body" == *"https://$CONTENT_DOMAIN"* && "$body" == *"https://$ASSISTANT_DOMAIN"* ]]; then
    ok "self-host config lists the public service addresses"
  else
    fail "self-host config did not return the public service addresses"
  fi
  check_no_secrets "self-host config" "$body"
else
  body="$("${CURL[@]}" --resolve "$ACCOUNT_DOMAIN:443:127.0.0.1" -X POST -H 'content-type: application/json' \
    -d '{"platform":"ios"}' "https://$ACCOUNT_DOMAIN/v1/auth/apple/challenge" || true)"
  if [[ "$body" == *'"challengeId"'* ]]; then ok "Apple sign-in challenge is issued"; else fail "Apple sign-in challenge failed"; fi
  check_no_secrets "Apple challenge" "$body"
fi

# 6. Pi credential file: writable only by the assistant user (uid 1000).
auth="$HERE/pi-config/auth.json"
if [[ -f "$auth" ]]; then
  mode="$(stat -c '%a' "$auth" 2>/dev/null || stat -f '%Lp' "$auth")"
  owner="$(stat -c '%u' "$auth" 2>/dev/null || stat -f '%u' "$auth")"
  if [[ "$mode" == "600" ]]; then ok "pi-config/auth.json mode 600"; else fail "pi-config/auth.json must be mode 600 (is $mode)"; fi
  if [[ "$owner" == "1000" ]]; then ok "pi-config/auth.json owned by uid 1000"; else fail "pi-config/auth.json must be owned by uid 1000 (is $owner)"; fi
else
  fail "pi-config/auth.json is missing (see README: model credentials)"
fi

if [[ $FAILED -ne 0 ]]; then
  echo "verify FAILED" >&2
  exit 1
fi
echo "verify ok"
