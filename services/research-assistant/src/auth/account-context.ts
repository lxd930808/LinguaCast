import { createHmac, timingSafeEqual } from 'node:crypto';

/**
 * Signed account context for service-to-service calls
 * (docs/contracts/account-v1-integration.md §2.3):
 *   v1.<base64url(JSON payload)>.<base64url(HMAC-SHA256(key, "v1.<payload>"))>
 * The same implementation is vendored in each backend service and checked
 * against docs/contracts/account-context-v1.vectors.json.
 */

export const ACCOUNT_CONTEXT_HEADER = 'x-linguacast-account-context';
export const ACCOUNT_CONTEXT_MAX_TTL_SECONDS = 300;
const DEFAULT_TTL_SECONDS = 120;
const CLOCK_SKEW_SECONDS = 30;
const ACCOUNT_ID = /^(acc_[0-9A-HJKMNP-TV-Z]{26}|selfhost)$/;

export interface AccountContextPayload {
  accountId: string;
  authMode: 'apple' | 'selfhost';
  sessionId: string | null;
  operationKey?: string | null;
  reservationId?: string | null;
  issuer: string;
  exp: number;
}

export type AccountContextInput = Omit<AccountContextPayload, 'exp'> & { exp?: number };

export type AccountContextVerification =
  | { ok: true; payload: AccountContextPayload }
  | { ok: false; reason: 'format' | 'signature' | 'payload' | 'expired' };

function mac(key: string, signingInput: string): string {
  return createHmac('sha256', key).update(signingInput, 'utf8').digest('base64url');
}

export function signAccountContext(
  input: AccountContextInput,
  key: string,
  nowMs = Date.now(),
  ttlSeconds = DEFAULT_TTL_SECONDS
): string {
  const payload: AccountContextPayload = {
    ...input,
    exp: input.exp ?? Math.floor(nowMs / 1000) + Math.min(ttlSeconds, ACCOUNT_CONTEXT_MAX_TTL_SECONDS)
  };
  const encoded = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64url');
  const signingInput = `v1.${encoded}`;
  return `${signingInput}.${mac(key, signingInput)}`;
}

function isPayload(value: unknown): value is AccountContextPayload {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const p = value as Record<string, unknown>;
  const optionalString = (field: unknown) => field === undefined || field === null || (typeof field === 'string' && field.length <= 200);
  return (
    typeof p.accountId === 'string' &&
    ACCOUNT_ID.test(p.accountId) &&
    (p.authMode === 'apple' || p.authMode === 'selfhost') &&
    (p.sessionId === null || (typeof p.sessionId === 'string' && p.sessionId.length <= 64)) &&
    optionalString(p.operationKey) &&
    optionalString(p.reservationId) &&
    typeof p.issuer === 'string' &&
    p.issuer.length > 0 &&
    typeof p.exp === 'number' &&
    Number.isInteger(p.exp)
  );
}

export function verifyAccountContext(token: string, key: string, nowMs = Date.now()): AccountContextVerification {
  const parts = token.split('.');
  if (parts.length !== 3 || parts[0] !== 'v1' || !parts[1] || !parts[2]) return { ok: false, reason: 'format' };
  const expected = Buffer.from(mac(key, `v1.${parts[1]}`), 'utf8');
  const provided = Buffer.from(parts[2], 'utf8');
  if (expected.length !== provided.length || !timingSafeEqual(expected, provided)) {
    return { ok: false, reason: 'signature' };
  }
  let payload: unknown;
  try {
    payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
  } catch {
    return { ok: false, reason: 'payload' };
  }
  if (!isPayload(payload)) return { ok: false, reason: 'payload' };
  const nowSeconds = Math.floor(nowMs / 1000);
  if (
    payload.exp <= nowSeconds - CLOCK_SKEW_SECONDS ||
    payload.exp > nowSeconds + ACCOUNT_CONTEXT_MAX_TTL_SECONDS + CLOCK_SKEW_SECONDS
  ) {
    return { ok: false, reason: 'expired' };
  }
  return { ok: true, payload };
}
