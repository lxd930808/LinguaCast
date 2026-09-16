import { generateKeyPairSync, randomBytes, sign, verify, type KeyObject } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { AppleClient, type FetchLike, type FetchResponseLike } from '../../src/apple/apple-client.js';
import { decodeJwt } from '../../src/apple/jwt.js';
import { AuthService } from '../../src/auth/auth-service.js';
import { loadConfig, type ServiceConfig } from '../../src/config.js';
import { SecretBox } from '../../src/crypto/tokens.js';
import { openDatabase } from '../../src/db/migrations.js';
import { DeletionWorker } from '../../src/deletion/deletion-worker.js';
import { SELFHOST_ACCOUNT_ID } from '../../src/domain/ids.js';
import { RedactingLogger } from '../../src/observability/logger.js';
import { FixedWindowRateLimiter } from '../../src/api/rate-limit.js';
import { AccountStore } from '../../src/store/account-store.js';
import { QuotaStore } from '../../src/quota/quota-store.js';
import { createApp, listen, type AppHandle } from '../../src/app.js';
import type { DatabaseSync } from 'node:sqlite';

export const MIGRATIONS_DIR = new URL('../../migrations/', import.meta.url).pathname;
export const APPLE_ISSUER = 'http://apple.test';
export const CLIENT_IDS = ['com.example.linguacast', 'com.example.linguacast.tv'];
export const INTERNAL_TOKEN = 'internal-content-token-0123456789abcdef';
export const SELFHOST_TOKEN = 'selfhost-deploy-token-0123456789abcdef';
export const PURGE_TOKEN = 'purge-token-0123456789abcdef-0123456789';
export const START_TIME = Date.parse('2026-09-14T08:00:00Z');

export function jsonResponse(status: number, body: unknown): FetchResponseLike {
  return { status, json: async () => body };
}

export class TestClock {
  constructor(public current = START_TIME) {}
  now = (): number => this.current;
  advance(ms: number): void {
    this.current += ms;
  }
}

export type AppleEndpointMode = 'ok' | 'invalid_grant' | 'invalid_client' | 'server_error' | 'network' | 'wrong_sub';

/** In-process fake of Apple's JWKS, token and revoke endpoints. */
export class FakeApple {
  readonly rsa = generateKeyPairSync('rsa', { modulusLength: 2048 });
  readonly otherRsa = generateKeyPairSync('rsa', { modulusLength: 2048 });
  readonly ec = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  readonly kid = 'test-kid-1';
  jwksMode: 'ok' | 'server_error' | 'network' = 'ok';
  tokenMode: AppleEndpointMode = 'ok';
  revokeMode: 'ok' | 'server_error' | 'invalid_grant' = 'ok';
  jwksFetches = 0;
  issuedRefreshTokens: string[] = [];
  revokedTokens: string[] = [];
  clientSecretsValid = true;

  constructor(private readonly clock: TestClock, readonly teamId = 'TEAM123456', readonly keyId = 'KEY1234567') {}

  get privateKeyPem(): string {
    return this.ec.privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
  }

  fetch: FetchLike = async (url, init) => {
    const path = new URL(url).pathname;
    if (path === '/auth/keys') {
      this.jwksFetches += 1;
      if (this.jwksMode === 'network') throw new Error('connect ECONNREFUSED');
      if (this.jwksMode === 'server_error') return jsonResponse(502, {});
      const jwk = this.rsa.publicKey.export({ format: 'jwk' });
      return jsonResponse(200, { keys: [{ ...jwk, kid: this.kid, alg: 'RS256', use: 'sig' }] });
    }
    const form = new URLSearchParams(init.body ?? '');
    this.checkClientSecret(form.get('client_secret'), form.get('client_id'));
    if (path === '/auth/token') {
      if (this.tokenMode === 'network') throw new Error('connect ECONNREFUSED');
      if (this.tokenMode === 'server_error') return jsonResponse(500, {});
      if (this.tokenMode === 'invalid_grant') return jsonResponse(400, { error: 'invalid_grant' });
      if (this.tokenMode === 'invalid_client') return jsonResponse(400, { error: 'invalid_client' });
      const code = form.get('code') ?? '';
      const sub = this.tokenMode === 'wrong_sub' ? 'someone-else' : code.replace(/^code-for:/, '');
      const refreshToken = `apple-refresh-${randomBytes(8).toString('hex')}`;
      this.issuedRefreshTokens.push(refreshToken);
      const idToken = this.identityToken({ sub, aud: form.get('client_id') ?? CLIENT_IDS[0]!, nonce: 'n/a' });
      return jsonResponse(200, { access_token: 'apple-access', refresh_token: refreshToken, id_token: idToken });
    }
    if (path === '/auth/revoke') {
      if (this.revokeMode === 'server_error') return jsonResponse(503, {});
      if (this.revokeMode === 'invalid_grant') return jsonResponse(400, { error: 'invalid_grant' });
      this.revokedTokens.push(form.get('token') ?? '');
      return jsonResponse(200, {});
    }
    return jsonResponse(404, {});
  };

  identityToken(options: {
    sub: string;
    nonce?: string;
    aud?: string;
    iss?: string;
    iatSeconds?: number;
    expSeconds?: number;
    alg?: string;
    kid?: string;
    signWith?: KeyObject;
  }): string {
    const iat = options.iatSeconds ?? Math.floor(this.clock.now() / 1000);
    const header = { alg: options.alg ?? 'RS256', kid: options.kid ?? this.kid };
    const payload: Record<string, unknown> = {
      iss: options.iss ?? APPLE_ISSUER,
      aud: options.aud ?? CLIENT_IDS[0],
      iat,
      exp: options.expSeconds ?? iat + 600,
      sub: options.sub,
      nonce_supported: true
    };
    if (options.nonce !== undefined) payload.nonce = options.nonce;
    const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString('base64url');
    const input = `${encode(header)}.${encode(payload)}`;
    const signature = sign('RSA-SHA256', Buffer.from(input), options.signWith ?? this.rsa.privateKey);
    return `${input}.${signature.toString('base64url')}`;
  }

  private checkClientSecret(secret: string | null, clientId: string | null): void {
    const jwt = secret ? decodeJwt(secret) : null;
    const valid =
      jwt !== null &&
      jwt.header.alg === 'ES256' &&
      jwt.header.kid === this.keyId &&
      jwt.payload.iss === this.teamId &&
      jwt.payload.sub === clientId &&
      verify('sha256', Buffer.from(jwt.signingInput), { key: this.ec.publicKey, dsaEncoding: 'ieee-p1363' }, jwt.signature);
    if (!valid) this.clientSecretsValid = false;
  }
}

export interface Harness {
  baseUrl: string;
  config: ServiceConfig;
  db: DatabaseSync;
  store: AccountStore;
  quota: QuotaStore;
  auth: AuthService;
  apple: FakeApple;
  clock: TestClock;
  logLines: string[];
  deletion: DeletionWorker;
  purgeCalls: string[];
  purgeResponder: (url: string) => FetchResponseLike | Promise<FetchResponseLike>;
  close: () => Promise<void>;
}

export async function startHarness(
  options: { mode?: 'apple' | 'selfhost'; env?: Record<string, string> } = {}
): Promise<Harness> {
  const tempRoot = await mkdtemp(join(tmpdir(), 'account-service-test-'));
  const clock = new TestClock();
  const apple = new FakeApple(clock);
  const mode = options.mode ?? 'apple';
  const env: Record<string, string> = {
    NODE_ENV: 'test',
    AUTH_MODE: mode,
    ACCOUNT_DATABASE_PATH: join(tempRoot, 'account.db'),
    ACCOUNT_INTERNAL_TOKENS: `content-pipeline:${INTERNAL_TOKEN}`,
    PUBLIC_ACCOUNT_BASE_URL: 'https://account.example.test',
    PUBLIC_CONTENT_BASE_URL: 'https://content.example.test',
    PUBLIC_ASSISTANT_BASE_URL: 'https://assistant.example.test',
    ...(mode === 'selfhost'
      ? { SELFHOST_ACCESS_TOKEN: SELFHOST_TOKEN }
      : {
          APPLE_TEAM_ID: apple.teamId,
          APPLE_KEY_ID: apple.keyId,
          APPLE_PRIVATE_KEY: apple.privateKeyPem,
          APPLE_CLIENT_IDS: CLIENT_IDS.join(','),
          APPLE_BASE_URL: APPLE_ISSUER,
          APPLE_ISSUER,
          APPLE_TOKEN_ENCRYPTION_KEY: randomBytes(32).toString('base64')
        }),
    ...options.env
  };
  const config = loadConfig(env);
  const logLines: string[] = [];
  const logger = new RedactingLogger((line) => logLines.push(line));
  const db = openDatabase(config.databasePath, MIGRATIONS_DIR);
  const store = new AccountStore(db);
  const quota = new QuotaStore(db);
  if (mode === 'selfhost') store.ensureAccount(SELFHOST_ACCOUNT_ID, 'selfhost', clock.now());
  const appleClient = config.apple
    ? new AppleClient({ ...config.apple, fetchImpl: apple.fetch, now: clock.now })
    : null;
  const secretBox = config.apple ? new SecretBox(config.apple.tokenEncryptionKey) : null;
  const auth = new AuthService({ config, store, apple: appleClient, secretBox, now: clock.now });

  const purgeCalls: string[] = [];
  const harness = {} as Harness;
  const purgeFetch: FetchLike = async (url, init) => {
    purgeCalls.push(`${init.method} ${url} ${init.headers?.authorization === `Bearer ${PURGE_TOKEN}` ? 'auth-ok' : 'auth-bad'}`);
    return harness.purgeResponder(url);
  };
  const deletion = new DeletionWorker({
    store,
    quota,
    apple: appleClient,
    secretBox,
    purgeTargets: config.purgeTargets,
    purgeToken: config.purgeToken,
    fetchImpl: purgeFetch,
    logger,
    now: clock.now,
    intervalMs: config.deletionIntervalMs
  });
  const app: AppHandle = createApp({
    config,
    store,
    auth,
    quota,
    now: clock.now,
    logger,
    authRateLimiter: new FixedWindowRateLimiter(config.authRateLimitPerMinute, clock.now)
  });
  await listen(app, { host: '127.0.0.1', port: 0 }, logger);
  const port = (app.server.address() as AddressInfo).port;

  Object.assign(harness, {
    baseUrl: `http://127.0.0.1:${port}`,
    config,
    db,
    store,
    quota,
    auth,
    apple,
    clock,
    logLines,
    deletion,
    purgeCalls,
    purgeResponder: () => jsonResponse(200, { status: 'done' }),
    close: async () => {
      await app.close();
      store.close();
      await rm(tempRoot, { recursive: true, force: true });
    }
  });
  return harness;
}

export interface CallResult {
  status: number;
  body: Record<string, any>;
  headers: Headers;
}

export async function call(
  harness: Harness,
  method: string,
  path: string,
  options: { body?: unknown; token?: string; headers?: Record<string, string> } = {}
): Promise<CallResult> {
  const headers: Record<string, string> = { ...options.headers };
  if (options.body !== undefined) headers['content-type'] = 'application/json';
  if (options.token !== undefined) headers.authorization = `Bearer ${options.token}`;
  const response = await fetch(`${harness.baseUrl}${path}`, {
    method,
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body)
  });
  const text = await response.text();
  return { status: response.status, body: text ? (JSON.parse(text) as Record<string, any>) : {}, headers: response.headers };
}

export async function signIn(
  harness: Harness,
  options: { sub?: string; platform?: string; aud?: string } = {}
): Promise<Record<string, any>> {
  const sub = options.sub ?? '001234.abcdef.0001';
  const platform = options.platform ?? 'ios';
  const challenge = await call(harness, 'POST', '/v1/auth/apple/challenge', { body: { platform } });
  if (challenge.status !== 201) throw new Error(`challenge failed: ${JSON.stringify(challenge.body)}`);
  const exchange = await call(harness, 'POST', '/v1/auth/apple/exchange', {
    body: {
      challengeId: challenge.body.challengeId,
      identityToken: harness.apple.identityToken({ sub, nonce: challenge.body.nonce, aud: options.aud }),
      authorizationCode: `code-for:${sub}`,
      platform,
      deviceName: 'Test iPhone'
    }
  });
  if (exchange.status !== 200) throw new Error(`exchange failed: ${JSON.stringify(exchange.body)}`);
  return exchange.body;
}
