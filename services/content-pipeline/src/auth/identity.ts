import { createHash, timingSafeEqual } from 'node:crypto';
import type { IncomingMessage } from 'node:http';

import { ACCOUNT_CONTEXT_HEADER, verifyAccountContext } from './account-context.js';

/**
 * Request identity resolution (docs/contracts/account-v1-integration.md §2).
 * Only this module turns credentials into a RequestIdentity. Public requests
 * are resolved by account-service introspection (account mode) or by the
 * deployment token (explicit selfhost mode). Internal callers must present
 * their own token AND a signed account context; the token alone never yields
 * an identity.
 */

export type IdentityMode = 'selfhost' | 'account';

export interface RequestIdentity {
  accountId: string;
  authMode: 'apple' | 'selfhost';
  sessionId: string | null;
}

export interface ResolvedCaller {
  identity: RequestIdentity;
  via: 'public' | 'internal';
  caller: string | null;
  operationKey: string | null;
  reservationId: string | null;
}

export interface InternalCallerToken {
  name: string;
  token: string;
}

export const SELFHOST_ACCOUNT_ID = 'selfhost';
export const ACCOUNT_ID_PATTERN = /^acc_[0-9A-HJKMNP-TV-Z]{26}$/;

export class IdentityError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly retryable = false,
    readonly retryAfterSeconds?: number
  ) {
    super(message);
    this.name = 'IdentityError';
  }
}

export interface IdentityResolverOptions {
  mode: IdentityMode;
  selfhostToken: string | null;
  accountServiceUrl: string | null;
  introspectionToken: string | null;
  internalCallers: readonly InternalCallerToken[];
  contextSigningKey: string | null;
  fetchImpl?: typeof fetch;
  now?: () => number;
  timeoutMs?: number;
}

const MAX_PUBLIC_TOKEN_LENGTH = 256;

export function safeEqual(a: string, b: string): boolean {
  const da = createHash('sha256').update(a).digest();
  const db = createHash('sha256').update(b).digest();
  return timingSafeEqual(da, db);
}

function bearer(req: IncomingMessage): string | null {
  const header = req.headers.authorization;
  if (typeof header !== 'string' || !header.startsWith('Bearer ')) return null;
  const token = header.slice('Bearer '.length).trim();
  return token === '' ? null : token;
}

function authRequired(message = 'missing or invalid credential'): IdentityError {
  return new IdentityError(401, 'AUTH_REQUIRED', message);
}

function accountServiceUnavailable(): IdentityError {
  return new IdentityError(503, 'ACCOUNT_SERVICE_UNAVAILABLE', 'identity could not be verified', true, 5);
}

function inactiveError(reason: unknown): IdentityError {
  switch (reason) {
    case 'expired':
      return new IdentityError(401, 'ACCESS_TOKEN_EXPIRED', 'access token expired', true);
    case 'revoked':
      return new IdentityError(401, 'SESSION_REVOKED', 'session was revoked');
    case 'account_disabled':
      return new IdentityError(403, 'ACCOUNT_DISABLED', 'account is disabled');
    case 'account_deleting':
      return new IdentityError(403, 'ACCOUNT_DELETING', 'account deletion is in progress');
    default:
      return authRequired();
  }
}

function isIdentity(value: unknown): value is RequestIdentity {
  if (!value || typeof value !== 'object') return false;
  const v = value as Record<string, unknown>;
  return (
    typeof v.accountId === 'string' &&
    (ACCOUNT_ID_PATTERN.test(v.accountId) || v.accountId === SELFHOST_ACCOUNT_ID) &&
    (v.authMode === 'apple' || v.authMode === 'selfhost') &&
    (v.sessionId === null || typeof v.sessionId === 'string')
  );
}

export class IdentityResolver {
  constructor(private readonly options: IdentityResolverOptions) {}

  get mode(): IdentityMode {
    return this.options.mode;
  }

  /** Name of the internal caller whose token is presented, or null. No account context required. */
  internalCaller(req: IncomingMessage): string | null {
    const token = bearer(req);
    return token === null ? null : this.matchInternal(token);
  }

  async resolve(req: IncomingMessage): Promise<ResolvedCaller> {
    const token = bearer(req);
    if (token === null) throw authRequired();
    const contextHeader = req.headers[ACCOUNT_CONTEXT_HEADER];
    const caller = this.matchInternal(token);

    if (caller !== null) {
      const key = this.options.contextSigningKey;
      if (typeof contextHeader !== 'string' || !key) {
        throw authRequired('internal calls require a signed account context');
      }
      const verified = verifyAccountContext(contextHeader, key, (this.options.now ?? Date.now)());
      if (!verified.ok) throw authRequired('account context rejected');
      const payload = verified.payload;
      const selfhostContext = payload.accountId === SELFHOST_ACCOUNT_ID;
      if (selfhostContext !== (this.options.mode === 'selfhost')) {
        throw authRequired('account context does not match this deployment mode');
      }
      return {
        identity: { accountId: payload.accountId, authMode: payload.authMode, sessionId: payload.sessionId },
        via: 'internal',
        caller,
        operationKey: payload.operationKey ?? null,
        reservationId: payload.reservationId ?? null
      };
    }

    if (contextHeader !== undefined) {
      throw new IdentityError(400, 'INVALID_REQUEST', 'account context header is not accepted on public requests');
    }
    const identity =
      this.options.mode === 'selfhost' ? this.selfhostIdentity(token) : await this.introspect(token);
    return { identity, via: 'public', caller: null, operationKey: null, reservationId: null };
  }

  private selfhostIdentity(token: string): RequestIdentity {
    const expected = this.options.selfhostToken;
    if (!expected || !safeEqual(token, expected)) throw authRequired();
    return { accountId: SELFHOST_ACCOUNT_ID, authMode: 'selfhost', sessionId: null };
  }

  private matchInternal(token: string): string | null {
    const match = this.options.internalCallers.find((entry) => safeEqual(token, entry.token));
    return match ? match.name : null;
  }

  private async introspect(token: string): Promise<RequestIdentity> {
    if (token.length > MAX_PUBLIC_TOKEN_LENGTH) throw authRequired();
    const { accountServiceUrl, introspectionToken } = this.options;
    if (!accountServiceUrl || !introspectionToken) throw accountServiceUnavailable();
    const fetchImpl = this.options.fetchImpl ?? fetch;
    let response: Response;
    try {
      response = await fetchImpl(`${accountServiceUrl}/internal/v1/auth/introspect`, {
        method: 'POST',
        headers: { authorization: `Bearer ${introspectionToken}`, 'content-type': 'application/json' },
        body: JSON.stringify({ token }),
        signal: AbortSignal.timeout(this.options.timeoutMs ?? 5000)
      });
    } catch {
      throw accountServiceUnavailable();
    }
    if (response.status === 400) throw authRequired();
    if (response.status !== 200) throw accountServiceUnavailable();
    const body = (await response.json().catch(() => null)) as
      | { active?: unknown; inactiveReason?: unknown; identity?: unknown }
      | null;
    if (!body || typeof body.active !== 'boolean') throw accountServiceUnavailable();
    if (!body.active) throw inactiveError(body.inactiveReason);
    if (!isIdentity(body.identity)) throw accountServiceUnavailable();
    return {
      accountId: body.identity.accountId,
      authMode: body.identity.authMode,
      sessionId: body.identity.sessionId
    };
  }
}
