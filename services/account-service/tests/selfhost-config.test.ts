import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { test } from 'node:test';

import { ConfigError, loadConfig } from '../src/config.js';
import { openDatabase } from '../src/db/migrations.js';
import { MIGRATIONS_DIR, INTERNAL_TOKEN, SELFHOST_TOKEN, call, startHarness } from './support/harness.js';

test('selfhost mode yields only the fixed selfhost identity', async () => {
  const h = await startHarness({ mode: 'selfhost' });
  try {
    const config = await call(h, 'GET', '/v1/me/config', { token: SELFHOST_TOKEN });
    assert.equal(config.status, 200);
    assert.equal(config.body.account.accountId, 'selfhost');
    assert.equal(config.body.account.authMode, 'selfhost');
    assert.equal(config.body.capabilities.accountDeletion, false);
    assert.equal(config.body.capabilities.quota, false);

    const wrong = await call(h, 'GET', '/v1/me/config', { token: `${SELFHOST_TOKEN}x` });
    assert.equal(wrong.status, 401);
    assert.equal(wrong.body.error.code, 'AUTH_REQUIRED');
    assert.equal((await call(h, 'GET', '/v1/me/config')).body.error.code, 'AUTH_REQUIRED');

    const intro = await call(h, 'POST', '/internal/v1/auth/introspect', { token: INTERNAL_TOKEN, body: { token: SELFHOST_TOKEN } });
    assert.deepEqual(intro.body, { active: true, identity: { accountId: 'selfhost', authMode: 'selfhost', sessionId: null } });

    for (const [method, path, body] of [
      ['POST', '/v1/auth/apple/challenge', { platform: 'ios' }],
      ['POST', '/v1/auth/refresh', { refreshToken: 'lcr_0000000000000000000000' }]
    ] as const) {
      const res = await call(h, method, path, { body });
      assert.equal(res.status, 404);
      assert.equal(res.body.error.code, 'AUTH_MODE_UNSUPPORTED');
    }
    const del = await call(h, 'DELETE', '/v1/me', { token: SELFHOST_TOKEN });
    assert.equal(del.body.error.code, 'AUTH_MODE_UNSUPPORTED');
    assert.equal((await call(h, 'POST', '/v1/auth/logout', { token: SELFHOST_TOKEN })).status, 204);
    assert.equal((await call(h, 'GET', '/v1/me/config', { token: SELFHOST_TOKEN })).status, 200);
  } finally {
    await h.close();
  }
});

test('health probes need no credentials', async () => {
  const h = await startHarness({ mode: 'selfhost' });
  try {
    assert.equal((await call(h, 'GET', '/v1/account-health/live')).status, 200);
    const ready = await call(h, 'GET', '/v1/account-health/ready');
    assert.equal(ready.status, 200);
    assert.equal(ready.body.checks.database, 'ok');
  } finally {
    await h.close();
  }
});

const BASE_ENV = {
  AUTH_MODE: 'selfhost',
  SELFHOST_ACCESS_TOKEN: SELFHOST_TOKEN,
  ACCOUNT_INTERNAL_TOKENS: `content-pipeline:${INTERNAL_TOKEN}`,
  PUBLIC_ACCOUNT_BASE_URL: 'https://account.example.test',
  PUBLIC_CONTENT_BASE_URL: 'https://content.example.test',
  PUBLIC_ASSISTANT_BASE_URL: 'https://assistant.example.test'
};

function configError(env: Record<string, string | undefined>): ConfigError {
  try {
    loadConfig(env);
  } catch (error) {
    assert.ok(error instanceof ConfigError);
    return error;
  }
  assert.fail('expected ConfigError');
}

test('configuration validation names variables and never echoes values', () => {
  assert.equal(loadConfig(BASE_ENV).authMode, 'selfhost');
  assert.equal(configError({ ...BASE_ENV, AUTH_MODE: undefined }).variable, 'AUTH_MODE');
  assert.equal(configError({ ...BASE_ENV, AUTH_MODE: 'password' }).variable, 'AUTH_MODE');
  const short = configError({ ...BASE_ENV, SELFHOST_ACCESS_TOKEN: 'short-secret-value' });
  assert.equal(short.variable, 'SELFHOST_ACCESS_TOKEN');
  assert.ok(!short.message.includes('short-secret-value'));
  assert.equal(configError({ ...BASE_ENV, ACCOUNT_HOST: '0.0.0.0' }).variable, 'ACCOUNT_HOST');
  assert.equal(loadConfig({ ...BASE_ENV, ACCOUNT_HOST: '0.0.0.0', ACCOUNT_BIND_ALL_INTERFACES: '1' }).host, '0.0.0.0');
  assert.equal(configError({ ...BASE_ENV, ACCOUNT_INTERNAL_TOKENS: `admin:${INTERNAL_TOKEN}` }).variable, 'ACCOUNT_INTERNAL_TOKENS');
  assert.equal(configError({ ...BASE_ENV, PUBLIC_CONTENT_BASE_URL: 'http://content.example.test' }).variable, 'PUBLIC_CONTENT_BASE_URL');
  assert.equal(
    configError({ ...BASE_ENV, ACCOUNT_PURGE_TARGETS: 'content-pipeline=https://content.internal' }).variable,
    'ACCOUNT_PURGE_TOKEN'
  );

  const ec = generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
  const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
  const appleEnv = {
    ...BASE_ENV,
    AUTH_MODE: 'apple',
    APPLE_TEAM_ID: 'TEAM123456',
    APPLE_KEY_ID: 'KEY1234567',
    APPLE_PRIVATE_KEY: ec,
    APPLE_CLIENT_IDS: 'com.example.linguacast',
    APPLE_TOKEN_ENCRYPTION_KEY: randomBytes(32).toString('base64')
  };
  const apple = loadConfig(appleEnv);
  assert.equal(apple.quotaEnforced, true);
  assert.equal(apple.selfhostAccessToken, null);
  assert.equal(apple.apple?.issuer, 'https://appleid.apple.com');
  assert.equal(configError({ ...appleEnv, APPLE_CLIENT_IDS: undefined }).variable, 'APPLE_CLIENT_IDS');
  assert.equal(configError({ ...appleEnv, APPLE_PRIVATE_KEY: rsa }).variable, 'APPLE_PRIVATE_KEY');
  assert.equal(configError({ ...appleEnv, APPLE_TOKEN_ENCRYPTION_KEY: randomBytes(16).toString('base64') }).variable, 'APPLE_TOKEN_ENCRYPTION_KEY');
  const badKey = configError({ ...appleEnv, APPLE_PRIVATE_KEY: 'not a key' });
  assert.ok(!badKey.message.includes('not a key'));
});

test('migrations apply to an empty database and are idempotent on reopen', async () => {
  const { migrate } = await import('../src/db/migrations.js');
  const db = openDatabase(':memory:', MIGRATIONS_DIR);
  migrate(db, MIGRATIONS_DIR);
  const tables = (db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all() as Array<{ name: string }>).map(
    (row) => row.name
  );
  for (const name of ['accounts', 'apple_identities', 'auth_challenges', 'sessions', 'access_tokens', 'refresh_tokens', 'account_deletions', 'quota_reservations', 'quota_ledger']) {
    assert.ok(tables.includes(name), `${name} exists`);
  }
  db.prepare("INSERT INTO accounts VALUES ('acc_A', 'apple', 'active', 1, 1)").run();
  db.prepare("INSERT INTO accounts VALUES ('acc_B', 'apple', 'active', 1, 1)").run();
  db.prepare("INSERT INTO apple_identities VALUES ('sub-1', 'acc_A', 'com.example', NULL, 1, 1)").run();
  assert.throws(() => db.prepare("INSERT INTO apple_identities VALUES ('sub-1', 'acc_B', 'com.example', NULL, 1, 1)").run(), /UNIQUE/);
  assert.throws(() => db.prepare("INSERT INTO accounts VALUES ('acc_C', 'apple', 'bogus', 1, 1)").run(), /CHECK/);
  const versions = (db.prepare('SELECT version FROM schema_migration').all() as Array<{ version: number }>).map((row) => row.version);
  assert.deepEqual(versions, [1, 2]);
  db.close();
});
