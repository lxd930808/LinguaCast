import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { loadConfig } from '../src/config/index.js';
import { createApp } from '../src/app.js';
import { RedactingLogger } from '../src/observability/logger.js';
import { openDatabase } from '../src/db/migrations.js';
import {
  configPresenceCheck,
  piConfigCheck,
  tempDirWritableCheck,
  ytdlpCheck
} from '../src/api/health.js';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), '..', 'migrations');

function testConfig(overrides: NodeJS.ProcessEnv = {}) {
  return loadConfig({
    ASSISTANT_IDENTITY_MODE: 'selfhost', ASSISTANT_SERVICE_TOKEN: 'test-assistant-token-0123456789',
    V10_SERVICE_TOKEN: 'test-v10-token-0123456789',
    V10_BASE_URL: 'https://content.example.test',
    NODE_ENV: 'test',
    ...overrides
  });
}

async function withServer(
  readiness: Parameters<typeof createApp>[0]['readiness'],
  fn: (base: string) => Promise<void>
): Promise<void> {
  const config = testConfig();
  const app = createApp({
    config,
    logger: new RedactingLogger(() => undefined),
    readiness
  });
  await new Promise<void>((resolve, reject) => {
    app.server.listen(0, '127.0.0.1', () => resolve());
    app.server.once('error', reject);
  });
  const address = app.server.address();
  assert.ok(address && typeof address === 'object');
  const base = `http://127.0.0.1:${address.port}`;
  try {
    await fn(base);
  } finally {
    await app.close();
  }
}

test('live health does not require auth', async () => {
  await withServer(
    {
      config: async () => ({ ok: true }),
      database: async () => ({ ok: true }),
      tempDir: async () => ({ ok: true }),
      piConfig: async () => ({ ok: true }),
      ytdlp: async () => ({ ok: true })
    },
    async (base) => {
      const response = await fetch(`${base}/v1/assistant-health/live`);
      assert.equal(response.status, 200);
      const json = (await response.json()) as { status: string; service: string };
      assert.equal(json.status, 'live');
      assert.equal(json.service, 'linguacast-assistant');
      assert.ok(!JSON.stringify(json).includes('token'));
    }
  );
});

test('unauthenticated V2 route returns 401 and removed V1 routes return 404', async () => {
  await withServer(
    {
      config: async () => ({ ok: true }),
      database: async () => ({ ok: true }),
      tempDir: async () => ({ ok: true }),
      piConfig: async () => ({ ok: true }),
      ytdlp: async () => ({ ok: true })
    },
    async (base) => {
      const response = await fetch(`${base}/v2/assistant/researches`);
      assert.equal(response.status, 401);
      const json = (await response.json()) as { error: { code: string } };
      assert.equal(json.error.code, 'AUTH_REQUIRED');
      const v1 = await fetch(`${base}/v1/assistant/sessions`);
      assert.equal(v1.status, 404);
      assert.equal(((await v1.json()) as { error: { code: string } }).error.code, 'NOT_FOUND');
    }
  );
});

test('ready accepts account credentials without the legacy service token', async () => {
  const config = testConfig({
    ASSISTANT_IDENTITY_MODE: 'account',
    ASSISTANT_SERVICE_TOKEN: undefined,
    ACCOUNT_SERVICE_URL: 'http://account-service:3240',
    ASSISTANT_ACCOUNT_TOKEN: 'test-introspection-token-0123456789',
    ACCOUNT_CONTEXT_SIGNING_KEY: 'test-context-signing-key-0123456789'
  });
  assert.equal(config.serviceToken, '');
  await withServer({
    config: configPresenceCheck(config),
    database: async () => ({ ok: true }),
    tempDir: async () => ({ ok: true }),
    piConfig: async () => ({ ok: true }),
    ytdlp: async () => ({ ok: true })
  }, async (base) => {
    const response = await fetch(`${base}/v1/assistant-health/ready`);
    assert.equal(response.status, 200);
  });
});

test('ready fails when pi config or yt-dlp is missing', async () => {
  const root = mkdtempSync(join(tmpdir(), 'assistant-ready-'));
  const config = testConfig({
    PI_CONFIG_DIR: join(root, 'missing-pi'),
    YTDLP_PATH: join(root, 'missing-ytdlp'),
    ASSISTANT_TEMP_ROOT: join(root, 'tmp'),
    ASSISTANT_DATABASE_PATH: join(root, 'assistant.db')
  });
  const db = openDatabase(config.databasePath, MIGRATIONS);
  await withServer(
    {
      config: configPresenceCheck(config),
      database: async () => {
        db.prepare('SELECT 1').get();
        return { ok: true };
      },
      tempDir: tempDirWritableCheck(config.tempRoot),
      piConfig: piConfigCheck(config.piConfigDir),
      ytdlp: ytdlpCheck(config.ytdlpPath)
    },
    async (base) => {
      const response = await fetch(`${base}/v1/assistant-health/ready`);
      assert.equal(response.status, 503);
      const json = (await response.json()) as { status: string; checks: Record<string, { ok: boolean }> };
      assert.equal(json.status, 'degraded');
      assert.equal(json.checks.piConfig.ok, false);
      assert.equal(json.checks.ytdlp.ok, false);
    }
  );
  db.close();
});

test('ready succeeds with writable db, pi models.json and executable stub', async () => {
  const root = mkdtempSync(join(tmpdir(), 'assistant-ready-ok-'));
  const piDir = join(root, 'pi');
  writeFileSync(join(root, 'ytdlp.sh'), '#!/bin/sh\necho 2025.10.14\n', { mode: 0o755 });
  chmodSync(join(root, 'ytdlp.sh'), 0o755);
  const { mkdirSync } = await import('node:fs');
  mkdirSync(piDir, { recursive: true });
  writeFileSync(join(piDir, 'models.json'), JSON.stringify({ models: [{ alias: 'primary' }] }));
  const config = testConfig({
    PI_CONFIG_DIR: piDir,
    YTDLP_PATH: join(root, 'ytdlp.sh'),
    ASSISTANT_TEMP_ROOT: join(root, 'tmp'),
    ASSISTANT_DATABASE_PATH: join(root, 'assistant.db')
  });
  const db = openDatabase(config.databasePath, MIGRATIONS);
  await withServer(
    {
      config: configPresenceCheck(config),
      database: async () => {
        db.prepare('SELECT 1').get();
        return { ok: true };
      },
      tempDir: tempDirWritableCheck(config.tempRoot),
      piConfig: piConfigCheck(config.piConfigDir),
      ytdlp: ytdlpCheck(config.ytdlpPath)
    },
    async (base) => {
      const response = await fetch(`${base}/v1/assistant-health/ready`);
      assert.equal(response.status, 200);
    }
  );
  db.close();
});
