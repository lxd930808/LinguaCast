import { createPrivateKey, createPublicKey, type JsonWebKey, type KeyObject } from 'node:crypto';

import { constantTimeEqual, sha256Hex } from '../crypto/tokens.js';
import { AccountError } from '../domain/errors.js';
import { decodeJwt, signEs256Jwt, verifyRs256 } from './jwt.js';

/**
 * Sign in with Apple server-side operations: identity token verification
 * against Apple JWKS, authorization code redemption and refresh token
 * revocation. Verification never degrades: when keys cannot be fetched the
 * request fails with APPLE_KEYS_UNAVAILABLE.
 */

export interface FetchResponseLike {
  status: number;
  json(): Promise<unknown>;
}

export type FetchLike = (
  url: string,
  init: { method: string; headers?: Record<string, string>; body?: string }
) => Promise<FetchResponseLike>;

export const defaultFetch: FetchLike = (url, init) => fetch(url, { ...init, signal: AbortSignal.timeout(10_000) });

export interface AppleClientOptions {
  teamId: string;
  keyId: string;
  privateKeyPem: string;
  clientIds: readonly string[];
  baseUrl: string;
  issuer: string;
  fetchImpl?: FetchLike;
  now?: () => number;
}

export interface AppleIdentity {
  sub: string;
  clientId: string;
}

const CLOCK_SKEW_MS = 60_000;
const JWKS_TTL_MS = 6 * 60 * 60 * 1000;
const UNKNOWN_KID_REFETCH_MS = 60_000;
const CLIENT_SECRET_TTL_SECONDS = 300;
const KNOWN_APPLE_ERRORS = new Set(['invalid_request', 'invalid_client', 'invalid_grant', 'unauthorized_client', 'unsupported_grant_type', 'invalid_scope']);

function invalidToken(check: string): AccountError {
  return new AccountError(401, 'APPLE_TOKEN_INVALID', `identity token failed the ${check} check`, false, { check });
}

function appleUnavailable(what: string): AccountError {
  return new AccountError(503, 'APPLE_KEYS_UNAVAILABLE', `${what} is unavailable`, true, undefined, 5);
}

async function readJson(response: FetchResponseLike): Promise<Record<string, unknown> | null> {
  try {
    const value = await response.json();
    return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

export class AppleClient {
  private keys = new Map<string, KeyObject>();
  private fetchedAt = 0;
  private lastAttemptAt = Number.NEGATIVE_INFINITY;
  private readonly privateKey: KeyObject;
  private readonly fetchImpl: FetchLike;
  private readonly now: () => number;

  constructor(private readonly options: AppleClientOptions) {
    this.privateKey = createPrivateKey(options.privateKeyPem);
    this.fetchImpl = options.fetchImpl ?? defaultFetch;
    this.now = options.now ?? Date.now;
  }

  async verifyIdentityToken(token: string, expectedNonceHash: string): Promise<AppleIdentity> {
    const jwt = decodeJwt(token);
    if (!jwt) throw invalidToken('format');
    if (jwt.header.alg !== 'RS256') throw invalidToken('alg');
    const kid = jwt.header.kid;
    if (typeof kid !== 'string' || kid === '') throw invalidToken('kid');
    const key = await this.keyFor(kid);
    if (!key) throw invalidToken('kid');
    if (!verifyRs256(jwt, key)) throw invalidToken('signature');

    const claims = jwt.payload;
    if (claims.iss !== this.options.issuer) throw invalidToken('iss');
    const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    const clientId = audiences.find(
      (aud): aud is string => typeof aud === 'string' && this.options.clientIds.includes(aud)
    );
    if (!clientId) throw invalidToken('aud');
    const now = this.now();
    if (typeof claims.exp !== 'number' || claims.exp * 1000 <= now - CLOCK_SKEW_MS) throw invalidToken('exp');
    if (typeof claims.iat !== 'number' || claims.iat * 1000 > now + CLOCK_SKEW_MS) throw invalidToken('iat');
    if (typeof claims.sub !== 'string' || claims.sub.trim() === '') throw invalidToken('sub');
    if (typeof claims.nonce !== 'string' || !constantTimeEqual(sha256Hex(claims.nonce), expectedNonceHash)) {
      throw invalidToken('nonce');
    }
    return { sub: claims.sub, clientId };
  }

  /** Redeems the one-time authorization code; returns Apple's refresh token when issued. */
  async redeemAuthorizationCode(code: string, identity: AppleIdentity): Promise<string | null> {
    const body = new URLSearchParams({
      client_id: identity.clientId,
      client_secret: this.clientSecret(identity.clientId),
      code,
      grant_type: 'authorization_code'
    }).toString();
    const response = await this.post('/auth/token', body, 'Apple token endpoint');
    const payload = await readJson(response);
    if (response.status !== 200) {
      const appleError = typeof payload?.error === 'string' && KNOWN_APPLE_ERRORS.has(payload.error) ? payload.error : 'unknown';
      if (appleError === 'invalid_client') {
        throw new AccountError(503, 'SERVICE_UNAVAILABLE', 'Apple rejected the configured client credentials');
      }
      throw new AccountError(401, 'APPLE_CODE_REJECTED', 'authorization code was rejected', false, { appleError });
    }
    const idToken = payload?.id_token;
    if (typeof idToken === 'string') {
      const decoded = decodeJwt(idToken);
      if (!decoded || decoded.payload.sub !== identity.sub) {
        throw new AccountError(401, 'APPLE_CODE_REJECTED', 'authorization code belongs to a different Apple user');
      }
    }
    return typeof payload?.refresh_token === 'string' && payload.refresh_token !== '' ? payload.refresh_token : null;
  }

  async revokeRefreshToken(refreshToken: string, clientId: string): Promise<void> {
    const body = new URLSearchParams({
      client_id: clientId,
      client_secret: this.clientSecret(clientId),
      token: refreshToken,
      token_type_hint: 'refresh_token'
    }).toString();
    const response = await this.post('/auth/revoke', body, 'Apple revoke endpoint');
    if (response.status === 200) return;
    const payload = await readJson(response);
    if (payload?.error === 'invalid_client') {
      throw new AccountError(503, 'SERVICE_UNAVAILABLE', 'Apple rejected the configured client credentials');
    }
    // invalid_grant / invalid_request: the token can no longer be used, which is the goal.
  }

  private async post(path: string, body: string, what: string): Promise<FetchResponseLike> {
    let response: FetchResponseLike;
    try {
      response = await this.fetchImpl(`${this.options.baseUrl}${path}`, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
        body
      });
    } catch {
      throw appleUnavailable(what);
    }
    if (response.status >= 500 || response.status === 429) throw appleUnavailable(what);
    return response;
  }

  private clientSecret(clientId: string): string {
    const iat = Math.floor(this.now() / 1000);
    return signEs256Jwt(
      { alg: 'ES256', kid: this.options.keyId },
      { iss: this.options.teamId, iat, exp: iat + CLIENT_SECRET_TTL_SECONDS, aud: this.options.issuer, sub: clientId },
      this.privateKey
    );
  }

  private async keyFor(kid: string): Promise<KeyObject | null> {
    const now = this.now();
    const fresh = now - this.fetchedAt < JWKS_TTL_MS;
    if (fresh && this.keys.has(kid)) return this.keys.get(kid) ?? null;
    if (!fresh || now - this.lastAttemptAt >= UNKNOWN_KID_REFETCH_MS) {
      this.lastAttemptAt = now;
      try {
        await this.refreshKeys(now);
      } catch {
        if (!this.keys.has(kid)) throw appleUnavailable('Apple JWKS');
      }
    }
    return this.keys.get(kid) ?? null;
  }

  private async refreshKeys(now: number): Promise<void> {
    const response = await this.fetchImpl(`${this.options.baseUrl}/auth/keys`, { method: 'GET' });
    if (response.status !== 200) throw new Error(`jwks status ${response.status}`);
    const payload = await readJson(response);
    const entries = Array.isArray(payload?.keys) ? payload.keys : null;
    if (!entries) throw new Error('jwks payload invalid');
    const next = new Map<string, KeyObject>();
    for (const entry of entries) {
      if (!entry || typeof entry !== 'object') continue;
      const jwk = entry as JsonWebKey & { kid?: unknown };
      if (jwk.kty !== 'RSA' || typeof jwk.kid !== 'string') continue;
      try {
        next.set(jwk.kid, createPublicKey({ key: { kty: jwk.kty, n: jwk.n, e: jwk.e }, format: 'jwk' }));
      } catch {
        // Skip malformed keys; other keys remain usable.
      }
    }
    if (next.size === 0) throw new Error('jwks contained no usable keys');
    this.keys = next;
    this.fetchedAt = now;
  }
}
