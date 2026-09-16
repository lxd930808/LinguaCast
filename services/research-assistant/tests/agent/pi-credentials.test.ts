import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { JsonFileCredentialStore } from '../../src/agent/pi-credentials.js';
import { resolvePiModel } from '../../src/agent/pi-adapter.js';

test('resolvePiModel finds kimi-for-coding from the builtin catalog', () => {
  const resolved = resolvePiModel({
    models: [{ alias: 'primary', provider: 'kimi-coding', model: 'kimi-for-coding' }]
  });
  assert.equal(resolved.provider, 'kimi-coding');
  assert.equal(resolved.modelId, 'kimi-for-coding');
});

test('resolvePiModel finds k3-256k from the builtin catalog', () => {
  const resolved = resolvePiModel({
    models: [{ alias: 'primary', provider: 'kimi-coding', model: 'k3-256k' }]
  });
  assert.equal(resolved.provider, 'kimi-coding');
  assert.equal(resolved.modelId, 'k3-256k');
});

test('JsonFileCredentialStore reads oauth entries without exposing other providers', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'pi-auth-'));
  const path = join(dir, 'auth.json');
  writeFileSync(
    path,
    JSON.stringify({
      'kimi-coding': { type: 'oauth', access: 'access-token-value', refresh: 'refresh-token-value', expires: 1 }
    })
  );
  const store = new JsonFileCredentialStore(path);
  const listed = await store.list();
  assert.deepEqual(listed, [{ providerId: 'kimi-coding', type: 'oauth' }]);
  const cred = await store.read('kimi-coding');
  assert.equal(cred?.type, 'oauth');
});
