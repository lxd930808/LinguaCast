import assert from 'node:assert/strict';
import { test } from 'node:test';

import { INTERNAL_TOKEN, PURGE_TOKEN, call, jsonResponse, signIn, startHarness } from './support/harness.js';

const PURGE_ENV = {
  ACCOUNT_PURGE_TARGETS: 'content-pipeline=http://content.internal:3220,research-assistant=http://assistant.internal:3230',
  ACCOUNT_PURGE_TOKEN: PURGE_TOKEN
};

test('account deletion disables the account and revokes every session immediately', async () => {
  const h = await startHarness({ env: PURGE_ENV });
  try {
    const phone = await signIn(h, { sub: 'delete-me' });
    const tv = await signIn(h, { sub: 'delete-me', platform: 'tvos', aud: 'com.example.linguacast.tv' });
    const res = await call(h, 'DELETE', '/v1/me', { token: phone.accessToken });
    assert.equal(res.status, 202);
    assert.match(res.body.deletionId, /^del_/);
    assert.equal(res.body.status, 'pending');

    for (const token of [phone.accessToken, tv.accessToken]) {
      const config = await call(h, 'GET', '/v1/me/config', { token });
      assert.equal(config.status, 403);
      assert.equal(config.body.error.code, 'ACCOUNT_DELETING');
      const intro = await call(h, 'POST', '/internal/v1/auth/introspect', { token: INTERNAL_TOKEN, body: { token } });
      assert.deepEqual(intro.body, { active: false, inactiveReason: 'account_deleting' });
    }
    const refresh = await call(h, 'POST', '/v1/auth/refresh', { body: { refreshToken: tv.refreshToken } });
    assert.equal(refresh.body.error.code, 'ACCOUNT_DELETING');
    assert.equal(h.db.prepare('SELECT COUNT(*) AS n FROM apple_identities').get()!.n, 0, 'Apple mapping removed at request time');
  } finally {
    await h.close();
  }
});

test('deletion workflow retries purge targets, revokes Apple and keeps a tombstone', async () => {
  const h = await startHarness({ env: PURGE_ENV });
  try {
    const session = await signIn(h, { sub: 'purge-user' });
    const accountId = session.account.accountId as string;
    await call(h, 'DELETE', '/v1/me', { token: session.accessToken });

    let contentAttempts = 0;
    h.purgeResponder = (url) => {
      if (url.startsWith('http://content.internal')) {
        contentAttempts += 1;
        return contentAttempts === 1 ? jsonResponse(500, {}) : jsonResponse(200, { status: 'done' });
      }
      return jsonResponse(202, { status: 'in_progress' });
    };
    assert.equal(await h.deletion.runOnce(), 0);
    let row = h.store.getDeletionForAccount(accountId)!;
    assert.equal(row.status, 'in_progress');
    assert.equal(row.lastErrorCode, 'PURGE_HTTP_500');
    assert.equal(h.apple.revokedTokens.length, 1, 'Apple revoke runs independently of other steps');
    assert.ok(row.appleRefreshTokenEnc, 'token kept until the whole workflow completes');
    assert.ok(h.purgeCalls.every((entry) => entry.endsWith('auth-ok')));
    assert.ok(h.purgeCalls[0]!.includes(`/internal/v1/accounts/${accountId}/purge`));

    assert.equal(await h.deletion.runOnce(), 0, 'backoff delays the retry');
    h.clock.advance(31_000);
    h.purgeResponder = () => jsonResponse(200, { status: 'done' });
    assert.equal(await h.deletion.runOnce(), 1);

    row = h.store.getDeletionForAccount(accountId)!;
    assert.equal(row.status, 'completed');
    assert.equal(row.appleRefreshTokenEnc, null);
    assert.ok(row.steps.every((step) => step.status === 'done'));
    assert.equal(h.store.getAccount(accountId)!.status, 'deleted');
    assert.deepEqual(h.store.listTombstones().map((t) => t.accountId), [accountId]);

    const again = await signIn(h, { sub: 'purge-user' });
    assert.notEqual(again.account.accountId, accountId, 'same Apple ID creates a new account after deletion');
  } finally {
    await h.close();
  }
});

test('Apple revoke failures are retried; invalid_grant counts as already revoked', async () => {
  const h = await startHarness();
  try {
    const session = await signIn(h, { sub: 'revoke-user' });
    await call(h, 'DELETE', '/v1/me', { token: session.accessToken });
    h.apple.revokeMode = 'server_error';
    assert.equal(await h.deletion.runOnce(), 0);
    assert.equal(h.store.getDeletionForAccount(session.account.accountId)!.lastErrorCode, 'APPLE_KEYS_UNAVAILABLE');
    h.clock.advance(31_000);
    h.apple.revokeMode = 'invalid_grant';
    assert.equal(await h.deletion.runOnce(), 1);
  } finally {
    await h.close();
  }
});
