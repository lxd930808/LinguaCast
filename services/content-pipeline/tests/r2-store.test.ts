import assert from 'node:assert/strict';
import test from 'node:test';

import { R2ObjectStore } from '../src/storage/r2-store.js';
import type { R2Config } from '../src/config.js';

/**
 * R2 store wire behavior (regression for the 2026-08-29 production incident):
 * every signed request must force `accept-encoding: identity`. The Cloudflare
 * edge otherwise negotiates gzip on compressible types, which strips
 * content-length from HEAD responses (weak etag) and breaks the publisher's
 * byte verification and range-read semantics.
 */

function testConfig(): R2Config {
  return {
    accountId: 'test-account',
    accessKeyId: 'test-access',
    secretAccessKey: 'test-secret-0123456789',
    bucket: 'linguacast',
    prefix: 'content-pipeline',
    environment: 'test',
    signedUrlTtlSeconds: 3600
  };
}

interface CapturedRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
}

test('head sends accept-encoding identity and reads content-length', async (t) => {
  const original = globalThis.fetch;
  const requests: CapturedRequest[] = [];
  globalThis.fetch = (async (input: unknown, init?: RequestInit) => {
    const headers: Record<string, string> = {};
    for (const [k, v] of Object.entries((init?.headers ?? {}) as Record<string, string>)) {
      headers[k.toLowerCase()] = String(v);
    }
    requests.push({ url: String(input), method: init?.method ?? 'GET', headers });
    return new Response(null, {
      status: 200,
      headers: { 'content-length': '1234', etag: '"abc"' }
    });
  }) as typeof fetch;
  t.after(() => { globalThis.fetch = original; });

  const store = new R2ObjectStore(testConfig());
  const meta = await store.head('content-pipeline/x/y.json');
  assert.equal(meta?.bytes, 1234);
  assert.equal(requests.length, 1);
  assert.equal(requests[0]!.headers['accept-encoding'], 'identity');
  // The header must be inside the SigV4 signed-header list, not just sent.
  assert.match(requests[0]!.headers['authorization'] ?? '', /SignedHeaders=[^,]*accept-encoding/);
});

test('put and range GET also pin accept-encoding identity', async (t) => {
  const original = globalThis.fetch;
  const requests: CapturedRequest[] = [];
  globalThis.fetch = (async (input: unknown, init?: RequestInit) => {
    const headers: Record<string, string> = {};
    for (const [k, v] of Object.entries((init?.headers ?? {}) as Record<string, string>)) {
      headers[k.toLowerCase()] = String(v);
    }
    requests.push({ url: String(input), method: init?.method ?? 'GET', headers });
    if ((init?.method ?? 'GET') === 'PUT') {
      return new Response(null, { status: 200, headers: { etag: '"x"' } });
    }
    return new Response(new Uint8Array([1, 2, 3]), {
      status: 206,
      headers: { 'content-length': '3', 'content-range': 'bytes 0-2/10' }
    });
  }) as typeof fetch;
  t.after(() => { globalThis.fetch = original; });

  const store = new R2ObjectStore(testConfig());
  await store.put('content-pipeline/x/y.json', Buffer.from([1, 2, 3]), 'application/json');
  const range = await store.getRange('content-pipeline/x/y.json', 0, 2);
  assert.equal(range.length, 3);
  assert.equal(requests[0]!.headers['accept-encoding'], 'identity');
  assert.equal(requests[1]!.headers['accept-encoding'], 'identity');
  assert.equal(requests[1]!.headers['range'], 'bytes=0-2');
});
