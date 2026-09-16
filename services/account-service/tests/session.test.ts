import assert from 'node:assert/strict';
import { test } from 'node:test';

import { INTERNAL_TOKEN, call, signIn, startHarness, type Harness } from './support/harness.js';

async function refresh(h: Harness, refreshToken: string) {
  return call(h, 'POST', '/v1/auth/refresh', { body: { refreshToken } });
}

async function introspect(h: Harness, token: string) {
  return call(h, 'POST', '/internal/v1/auth/introspect', { token: INTERNAL_TOKEN, body: { token } });
}

test('refresh rotates the credential; reuse outside the grace window revokes the session', async () => {
  const h = await startHarness();
  try {
    const session = await signIn(h);
    h.clock.advance(60_000);
    const rotated = await refresh(h, session.refreshToken);
    assert.equal(rotated.status, 200);
    assert.notEqual(rotated.body.refreshToken, session.refreshToken);
    assert.equal(rotated.body.sessionId, session.sessionId);
    assert.equal(rotated.body.sessionExpiresAt, session.sessionExpiresAt, 'refresh never extends the session');
    assert.equal((await call(h, 'GET', '/v1/me/config', { token: rotated.body.accessToken })).status, 200);

    h.clock.advance(31_000);
    const reused = await refresh(h, session.refreshToken);
    assert.equal(reused.status, 401);
    assert.equal(reused.body.error.code, 'REFRESH_TOKEN_REUSED');

    const afterReuse = await call(h, 'GET', '/v1/me/config', { token: rotated.body.accessToken });
    assert.equal(afterReuse.status, 401);
    assert.equal(afterReuse.body.error.code, 'SESSION_REVOKED');
    const successor = await refresh(h, rotated.body.refreshToken);
    assert.equal(successor.body.error.code, 'SESSION_REVOKED');
  } finally {
    await h.close();
  }
});

test('grace window re-rotates a lost response once and invalidates the unused successor', async () => {
  const h = await startHarness();
  try {
    const session = await signIn(h);
    const lost = await refresh(h, session.refreshToken);
    assert.equal(lost.status, 200);
    h.clock.advance(5_000);
    const retried = await refresh(h, session.refreshToken);
    assert.equal(retried.status, 200, 'retry inside grace succeeds');
    assert.equal(h.store.countActiveRefreshTokens(session.sessionId), 1);

    const stale = await refresh(h, lost.body.refreshToken);
    assert.equal(stale.body.error.code, 'REFRESH_TOKEN_REUSED', 'superseded successor is treated as reuse');
    assert.equal((await refresh(h, retried.body.refreshToken)).body.error.code, 'SESSION_REVOKED');
  } finally {
    await h.close();
  }
});

test('concurrent refreshes with one credential leave exactly one usable refresh token', async () => {
  const h = await startHarness();
  try {
    const session = await signIn(h);
    const results = await Promise.all(Array.from({ length: 6 }, () => refresh(h, session.refreshToken)));
    assert.ok(results.every((result) => result.status === 200));
    assert.equal(h.store.countActiveRefreshTokens(session.sessionId), 1);
    const activeHashes = h.db
      .prepare("SELECT token_hash FROM refresh_tokens WHERE session_id = ? AND status = 'active'")
      .all(session.sessionId) as Array<{ token_hash: string }>;
    assert.equal(activeHashes.length, 1);
  } finally {
    await h.close();
  }
});

test('access token expiry, session max age and unknown refresh tokens', async () => {
  const h = await startHarness();
  try {
    const session = await signIn(h);
    h.clock.advance(901_000);
    const expired = await call(h, 'GET', '/v1/me/config', { token: session.accessToken });
    assert.equal(expired.status, 401);
    assert.equal(expired.body.error.code, 'ACCESS_TOKEN_EXPIRED');
    assert.equal(expired.body.error.retryable, true);
    const renewed = await refresh(h, session.refreshToken);
    assert.equal(renewed.status, 200);

    h.clock.advance(30 * 24 * 3600 * 1000);
    const tooOld = await refresh(h, renewed.body.refreshToken);
    assert.equal(tooOld.body.error.code, 'REFRESH_TOKEN_INVALID');

    const unknown = await refresh(h, 'lcr_this-token-was-never-issued-000000');
    assert.equal(unknown.body.error.code, 'REFRESH_TOKEN_INVALID');
  } finally {
    await h.close();
  }
});

test('logout revokes the session immediately and is idempotent for the caller', async () => {
  const h = await startHarness();
  try {
    const session = await signIn(h);
    const other = await signIn(h, { sub: '001234.abcdef.0001', platform: 'tvos', aud: 'com.example.linguacast.tv' });
    assert.equal((await call(h, 'POST', '/v1/auth/logout', { token: session.accessToken })).status, 204);
    const after = await introspect(h, session.accessToken);
    assert.deepEqual(after.body, { active: false, inactiveReason: 'revoked' });
    assert.equal((await call(h, 'GET', '/v1/me/config', { token: session.accessToken })).body.error.code, 'SESSION_REVOKED');
    assert.equal((await refresh(h, session.refreshToken)).body.error.code, 'SESSION_REVOKED');
    assert.equal((await call(h, 'POST', '/v1/auth/logout', { token: session.accessToken })).status, 401);
    assert.equal((await call(h, 'GET', '/v1/me/config', { token: other.accessToken })).status, 200, 'other device stays signed in');
  } finally {
    await h.close();
  }
});

test('introspection requires the internal credential and returns identity only', async () => {
  const h = await startHarness();
  try {
    const session = await signIn(h);
    const none = await call(h, 'POST', '/internal/v1/auth/introspect', { body: { token: session.accessToken } });
    assert.equal(none.status, 401);
    const withUserToken = await call(h, 'POST', '/internal/v1/auth/introspect', {
      token: session.accessToken,
      body: { token: session.accessToken }
    });
    assert.equal(withUserToken.status, 401, 'user tokens never unlock internal routes');

    const active = await introspect(h, session.accessToken);
    assert.equal(active.status, 200);
    assert.deepEqual(active.body, {
      active: true,
      identity: { accountId: session.account.accountId, authMode: 'apple', sessionId: session.sessionId }
    });
    assert.deepEqual((await introspect(h, session.refreshToken)).body, { active: false, inactiveReason: 'unknown' });
    h.clock.advance(901_000);
    assert.deepEqual((await introspect(h, session.accessToken)).body, { active: false, inactiveReason: 'expired' });

    const extra = await call(h, 'POST', '/internal/v1/auth/introspect', {
      token: INTERNAL_TOKEN,
      body: { token: session.accessToken, accountId: 'acc_01ARZ3NDEKTSV4RRFFQ69G5FAV' }
    });
    assert.equal(extra.status, 400, 'callers cannot inject identity fields');
    assert.equal((await call(h, 'POST', '/internal/v1/unknown', { token: INTERNAL_TOKEN, body: {} })).status, 404);
  } finally {
    await h.close();
  }
});

test('public routes reject a forwarded account context header', async () => {
  const h = await startHarness();
  try {
    const session = await signIn(h);
    const res = await call(h, 'GET', '/v1/me/config', {
      token: session.accessToken,
      headers: { 'X-LinguaCast-Account-Context': 'v1.e30.sig' }
    });
    assert.equal(res.status, 400);
    assert.equal(res.body.error.code, 'INVALID_REQUEST');
  } finally {
    await h.close();
  }
});
