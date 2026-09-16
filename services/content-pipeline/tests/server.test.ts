import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import type { AddressInfo } from 'node:net';

import { createApp, listen, SERVICE_VERSION, type AppHandle } from '../src/app.js';
import { loadConfig, type ServiceConfig } from '../src/config.js';
import { RedactingLogger } from '../src/observability/logger.js';

function testConfig(tempRoot: string, port = 0): ServiceConfig {
  const config = loadConfig({
    CONTENT_IDENTITY_MODE: 'selfhost', CONTENT_SERVICE_TOKEN: 'test-service-token-0123456789',
    MEDIA_API_TOKEN: 'test-media-token-0123456789',
    DASHSCOPE_API_KEY: 'test-dashscope-key-0123456789',
    TRANSLATION_API_KEY: 'test-translation-key-0123456789',
    TRANSLATION_MODEL: 'test-model',
    R2_ACCOUNT_ID: 'acct',
    R2_ACCESS_KEY_ID: 'r2-access',
    R2_SECRET_ACCESS_KEY: 'r2-secret-0123456789',
    R2_BUCKET: 'linguacast',
    CONTENT_TEMP_ROOT: tempRoot
  });
  return { ...config, port };
}

async function withServer(
  options: Partial<Parameters<typeof createApp>[0]>,
  run: (baseUrl: string, app: AppHandle) => Promise<void>
): Promise<void> {
  const tempRoot = await mkdtemp(join(tmpdir(), 'content-svc-test-'));
  const logger = new RedactingLogger(() => {});
  const config = testConfig(tempRoot);
  const app = createApp({ config, logger, ...options });
  await listen(app, config, logger);
  const address = app.server.address() as AddressInfo;
  try {
    await run(`http://127.0.0.1:${address.port}`, app);
  } finally {
    await app.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
}

test('liveness responds without any external dependency', async () => {
  await withServer({}, async (baseUrl) => {
    const res = await fetch(`${baseUrl}/v1/content-health/live`);
    assert.equal(res.status, 200);
    const body = (await res.json()) as Record<string, unknown>;
    assert.equal(body.status, 'live');
    assert.equal(body.service, 'linguacast-content');
    assert.equal(body.version, SERVICE_VERSION);
  });
});

test('readiness aggregates dependency checks and reports failure distinctly', async () => {
  await withServer(
    {
      readinessOverrides: {
        database: async () => ({ ok: false, detail: 'cannot open database' })
      }
    },
    async (baseUrl) => {
      const res = await fetch(`${baseUrl}/v1/content-health/ready`);
      assert.equal(res.status, 503);
      const body = (await res.json()) as {
        status: string;
        checks: Record<string, { ok: boolean }>;
      };
      assert.equal(body.status, 'degraded');
      assert.equal(body.checks.database.ok, false);
      assert.equal(body.checks.tempDirWritable.ok, true);
      assert.equal(body.checks.objectStoreConfig.ok, true);
    }
  );
});

test('readiness passes when all checks succeed', async () => {
  await withServer({}, async (baseUrl) => {
    const res = await fetch(`${baseUrl}/v1/content-health/ready`);
    assert.equal(res.status, 200);
    const body = (await res.json()) as { status: string };
    assert.equal(body.status, 'ready');
  });
});

test('unknown routes return a JSON error envelope with trace id', async () => {
  await withServer({}, async (baseUrl) => {
    const res = await fetch(`${baseUrl}/v1/nope`);
    assert.equal(res.status, 404);
    assert.ok(res.headers.get('x-trace-id'));
    const body = (await res.json()) as { error: { code: string; traceId: string } };
    assert.equal(body.error.code, 'JOB_NOT_FOUND');
    assert.ok(body.error.traceId.startsWith('tr_'));
  });
});

test('graceful close stops accepting new connections and drains', async () => {
  await withServer({}, async (baseUrl, app) => {
    const res = await fetch(`${baseUrl}/v1/content-health/live`);
    assert.equal(res.status, 200);
    await app.close();
    await assert.rejects(fetch(`${baseUrl}/v1/content-health/live`));
  });
});
