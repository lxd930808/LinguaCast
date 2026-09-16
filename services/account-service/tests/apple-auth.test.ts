import assert from 'node:assert/strict';
import { test } from 'node:test';

import { APPLE_ISSUER, INTERNAL_TOKEN, call, signIn, startHarness, type Harness } from './support/harness.js';

async function challenge(h: Harness, platform = 'ios'): Promise<{ challengeId: string; nonce: string }> {
  const res = await call(h, 'POST', '/v1/auth/apple/challenge', { body: { platform } });
  assert.equal(res.status, 201);
  return res.body as { challengeId: string; nonce: string };
}

async function exchange(h: Harness, body: Record<string, unknown>) {
  return call(h, 'POST', '/v1/auth/apple/exchange', { body });
}

test('challenge returns a single-use nonce with a five minute expiry', async () => {
  const h = await startHarness();
  try {
    const res = await call(h, 'POST', '/v1/auth/apple/challenge', { body: { platform: 'tvos' } });
    assert.equal(res.status, 201);
    assert.match(res.body.challengeId, /^ach_[0-9A-HJKMNP-TV-Z]{26}$/);
    assert.ok(res.body.nonce.length >= 32);
    assert.equal(Date.parse(res.body.expiresAt) - h.clock.now(), 300_000);
    const bad = await call(h, 'POST', '/v1/auth/apple/challenge', { body: { platform: 'android' } });
    assert.equal(bad.status, 400);
    assert.equal(bad.body.error.code, 'INVALID_REQUEST');
  } finally {
    await h.close();
  }
});

test('exchange verifies Apple and issues an App session; config never leaks secrets', async () => {
  const h = await startHarness();
  try {
    const session = await signIn(h, { sub: 'apple-user-1' });
    assert.match(session.accessToken, /^lca_/);
    assert.match(session.refreshToken, /^lcr_/);
    assert.match(session.sessionId, /^ses_/);
    assert.match(session.account.accountId, /^acc_/);
    assert.equal(session.account.authMode, 'apple');
    assert.equal(Date.parse(session.accessTokenExpiresAt) - h.clock.now(), 900_000);
    assert.equal(Date.parse(session.sessionExpiresAt) - h.clock.now(), 30 * 24 * 3600 * 1000);
    assert.equal(h.apple.clientSecretsValid, true, 'client secret must be a valid ES256 JWT');

    const config = await call(h, 'GET', '/v1/me/config', { token: session.accessToken });
    assert.equal(config.status, 200);
    assert.equal(config.body.account.accountId, session.account.accountId);
    assert.equal(config.body.services.contentBaseUrl, 'https://content.example.test');
    assert.deepEqual(config.body.capabilities, {
      contentJobs: true,
      assistantV2: true,
      videoMedia: false,
      quota: true,
      accountDeletion: true
    });
    const serialized = JSON.stringify(config.body);
    for (const secret of [
      INTERNAL_TOKEN,
      h.config.apple!.privateKeyPem,
      h.config.apple!.tokenEncryptionKey.toString('base64'),
      ...h.apple.issuedRefreshTokens,
      session.refreshToken
    ]) {
      assert.ok(!serialized.includes(secret), 'config response must not contain secrets');
    }
    assert.doesNotMatch(serialized, /token|secret|key/i);

    const storedTokens = h.db.prepare('SELECT refresh_token_enc FROM apple_identities').all() as Array<{ refresh_token_enc: string }>;
    assert.equal(storedTokens.length, 1);
    assert.ok(storedTokens[0]!.refresh_token_enc.startsWith('v1.'));
    assert.ok(!storedTokens[0]!.refresh_token_enc.includes(h.apple.issuedRefreshTokens[0]!));
    const dump = JSON.stringify(h.db.prepare('SELECT * FROM access_tokens').all()) + JSON.stringify(h.db.prepare('SELECT * FROM refresh_tokens').all());
    assert.ok(!dump.includes(session.accessToken) && !dump.includes(session.refreshToken), 'only hashes are stored');
  } finally {
    await h.close();
  }
});

test('same Apple user signs in again to the same account with a new session', async () => {
  const h = await startHarness();
  try {
    const first = await signIn(h, { sub: 'apple-user-2' });
    const second = await signIn(h, { sub: 'apple-user-2', platform: 'tvos', aud: 'com.example.linguacast.tv' });
    const other = await signIn(h, { sub: 'apple-user-3' });
    assert.equal(second.account.accountId, first.account.accountId);
    assert.notEqual(second.sessionId, first.sessionId);
    assert.notEqual(other.account.accountId, first.account.accountId);
    const count = h.db.prepare('SELECT COUNT(*) AS n FROM accounts').get() as { n: number };
    assert.equal(count.n, 2);
  } finally {
    await h.close();
  }
});

test('identity token checks: signature, alg, iss, aud, exp, iat and nonce', async () => {
  const h = await startHarness();
  try {
    const nowSeconds = Math.floor(h.clock.now() / 1000);
    const cases: Array<[string, (nonce: string) => string]> = [
      ['signature', (nonce) => h.apple.identityToken({ sub: 'u', nonce, signWith: h.apple.otherRsa.privateKey })],
      ['alg', (nonce) => h.apple.identityToken({ sub: 'u', nonce, alg: 'HS256' })],
      ['kid', (nonce) => h.apple.identityToken({ sub: 'u', nonce, kid: 'unknown-kid' })],
      ['iss', (nonce) => h.apple.identityToken({ sub: 'u', nonce, iss: 'https://evil.example' })],
      ['aud', (nonce) => h.apple.identityToken({ sub: 'u', nonce, aud: 'com.attacker.app' })],
      ['exp', (nonce) => h.apple.identityToken({ sub: 'u', nonce, iatSeconds: nowSeconds - 7200, expSeconds: nowSeconds - 3600 })],
      ['iat', (nonce) => h.apple.identityToken({ sub: 'u', nonce, iatSeconds: nowSeconds + 3600, expSeconds: nowSeconds + 7200 })],
      ['nonce', () => h.apple.identityToken({ sub: 'u', nonce: 'a-different-nonce-value-000000000000' })],
      ['nonce', () => h.apple.identityToken({ sub: 'u' })],
      ['format', () => 'not-a-jwt-but-long-enough']
    ];
    for (const [check, makeToken] of cases) {
      const c = await challenge(h);
      const res = await exchange(h, {
        challengeId: c.challengeId,
        identityToken: makeToken(c.nonce),
        authorizationCode: 'code-for:u',
        platform: 'ios'
      });
      assert.equal(res.status, 401, `${check} should be rejected`);
      assert.equal(res.body.error.code, 'APPLE_TOKEN_INVALID');
      assert.equal(res.body.error.params.check, check);
    }
    const count = h.db.prepare('SELECT COUNT(*) AS n FROM accounts').get() as { n: number };
    assert.equal(count.n, 0, 'no account is created for rejected tokens');
    assert.equal(APPLE_ISSUER, h.config.apple!.issuer);
  } finally {
    await h.close();
  }
});

test('challenge is single use (even after a failed attempt), expires, and is platform bound', async () => {
  const h = await startHarness();
  try {
    const c = await challenge(h);
    const bad = await exchange(h, {
      challengeId: c.challengeId,
      identityToken: h.apple.identityToken({ sub: 'u', nonce: c.nonce, signWith: h.apple.otherRsa.privateKey }),
      authorizationCode: 'code-for:u',
      platform: 'ios'
    });
    assert.equal(bad.body.error.code, 'APPLE_TOKEN_INVALID');
    const replay = await exchange(h, {
      challengeId: c.challengeId,
      identityToken: h.apple.identityToken({ sub: 'u', nonce: c.nonce }),
      authorizationCode: 'code-for:u',
      platform: 'ios'
    });
    assert.equal(replay.status, 400);
    assert.equal(replay.body.error.code, 'CHALLENGE_CONSUMED');

    const good = await challenge(h);
    const ok = await exchange(h, {
      challengeId: good.challengeId,
      identityToken: h.apple.identityToken({ sub: 'u', nonce: good.nonce }),
      authorizationCode: 'code-for:u',
      platform: 'ios'
    });
    assert.equal(ok.status, 200);
    const replayed = await exchange(h, {
      challengeId: good.challengeId,
      identityToken: h.apple.identityToken({ sub: 'u', nonce: good.nonce }),
      authorizationCode: 'code-for:u',
      platform: 'ios'
    });
    assert.equal(replayed.body.error.code, 'CHALLENGE_CONSUMED');

    const late = await challenge(h);
    h.clock.advance(301_000);
    const expired = await exchange(h, {
      challengeId: late.challengeId,
      identityToken: h.apple.identityToken({ sub: 'u', nonce: late.nonce }),
      authorizationCode: 'code-for:u',
      platform: 'ios'
    });
    assert.equal(expired.body.error.code, 'CHALLENGE_EXPIRED');

    const tv = await challenge(h, 'tvos');
    const mismatch = await exchange(h, {
      challengeId: tv.challengeId,
      identityToken: h.apple.identityToken({ sub: 'u', nonce: tv.nonce }),
      authorizationCode: 'code-for:u',
      platform: 'ios'
    });
    assert.equal(mismatch.body.error.code, 'CHALLENGE_INVALID');

    const unknown = await exchange(h, {
      challengeId: 'ach_01ARZ3NDEKTSV4RRFFQ69G5FAV',
      identityToken: h.apple.identityToken({ sub: 'u', nonce: 'x' }),
      authorizationCode: 'code-for:u',
      platform: 'ios'
    });
    assert.equal(unknown.body.error.code, 'CHALLENGE_INVALID');
  } finally {
    await h.close();
  }
});

test('JWKS or token endpoint failures fail closed with retryable 503', async () => {
  const h = await startHarness();
  try {
    for (const mode of ['network', 'server_error'] as const) {
      h.apple.jwksMode = mode;
      const c = await challenge(h);
      const res = await exchange(h, {
        challengeId: c.challengeId,
        identityToken: h.apple.identityToken({ sub: 'u', nonce: c.nonce }),
        authorizationCode: 'code-for:u',
        platform: 'ios'
      });
      assert.equal(res.status, 503);
      assert.equal(res.body.error.code, 'APPLE_KEYS_UNAVAILABLE');
      assert.equal(res.body.error.retryable, true);
      h.clock.advance(61_000);
    }
    h.apple.jwksMode = 'ok';
    h.apple.tokenMode = 'network';
    const c = await challenge(h);
    const res = await exchange(h, {
      challengeId: c.challengeId,
      identityToken: h.apple.identityToken({ sub: 'u', nonce: c.nonce }),
      authorizationCode: 'code-for:u',
      platform: 'ios'
    });
    assert.equal(res.status, 503);
    assert.equal(res.body.error.code, 'APPLE_KEYS_UNAVAILABLE');
    const count = h.db.prepare('SELECT COUNT(*) AS n FROM accounts').get() as { n: number };
    assert.equal(count.n, 0);
  } finally {
    await h.close();
  }
});

test('authorization code rejection, user mismatch and bad client credentials', async () => {
  const h = await startHarness();
  try {
    const expectations: Array<[typeof h.apple.tokenMode, number, string]> = [
      ['invalid_grant', 401, 'APPLE_CODE_REJECTED'],
      ['wrong_sub', 401, 'APPLE_CODE_REJECTED'],
      ['invalid_client', 503, 'SERVICE_UNAVAILABLE']
    ];
    for (const [mode, status, code] of expectations) {
      h.apple.tokenMode = mode;
      const c = await challenge(h);
      const res = await exchange(h, {
        challengeId: c.challengeId,
        identityToken: h.apple.identityToken({ sub: 'u', nonce: c.nonce }),
        authorizationCode: 'code-for:u',
        platform: 'ios'
      });
      assert.equal(res.status, status, mode);
      assert.equal(res.body.error.code, code, mode);
    }
  } finally {
    await h.close();
  }
});

test('auth endpoints are rate limited per client address', async () => {
  const h = await startHarness({ env: { ACCOUNT_AUTH_RATE_LIMIT_PER_MINUTE: '3' } });
  try {
    for (let i = 0; i < 3; i += 1) {
      assert.equal((await call(h, 'POST', '/v1/auth/apple/challenge', { body: { platform: 'ios' } })).status, 201);
    }
    const limited = await call(h, 'POST', '/v1/auth/apple/challenge', { body: { platform: 'ios' } });
    assert.equal(limited.status, 429);
    assert.equal(limited.body.error.code, 'RATE_LIMITED');
    assert.ok(Number(limited.headers.get('retry-after')) > 0);
    h.clock.advance(60_000);
    assert.equal((await call(h, 'POST', '/v1/auth/apple/challenge', { body: { platform: 'ios' } })).status, 201);
  } finally {
    await h.close();
  }
});

test('logs never contain App credentials, Apple tokens or authorization codes', async () => {
  const h = await startHarness();
  try {
    const session = await signIn(h, { sub: 'apple-log-user' });
    h.apple.tokenMode = 'server_error';
    const c = await challenge(h);
    const identityToken = h.apple.identityToken({ sub: 'apple-log-user', nonce: c.nonce });
    await exchange(h, { challengeId: c.challengeId, identityToken, authorizationCode: 'code-for:apple-log-user', platform: 'ios' });
    const logs = h.logLines.join('\n');
    assert.ok(h.logLines.length > 0, 'the failing exchange must be logged');
    for (const secret of [session.accessToken, session.refreshToken, identityToken, ...h.apple.issuedRefreshTokens]) {
      assert.ok(!logs.includes(secret));
    }
  } finally {
    await h.close();
  }
});
