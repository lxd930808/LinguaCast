import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { DomainError } from '../../src/domain/types.js';
import {
  KIMI_OAUTH_TOKEN_URL,
  KIMI_SEARCH_URL,
  KimiCodingWebSearchProvider
} from '../../src/web/kimi-search.js';
import { createWebSearchProvider, isWebSearchConfigured } from '../../src/web/provider.js';
import type { ServiceConfig } from '../../src/config/index.js';

function writeAuth(path: string, expires: number, access = 'access-live-token'): void {
  writeFileSync(
    path,
    `${JSON.stringify({
      'kimi-coding': { type: 'oauth', access, refresh: 'refresh-live-token', expires }
    })}\n`,
    { mode: 0o600 }
  );
}

test('fresh kimi-coding token searches without refresh', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'kimi-web-'));
  const authPath = join(dir, 'auth.json');
  writeAuth(authPath, Date.now() + 10 * 60 * 1000);
  const calls: string[] = [];
  const provider = new KimiCodingWebSearchProvider({
    authPath,
    fetchImpl: async (input, init) => {
      const url = String(input);
      calls.push(url);
      assert.equal(url, KIMI_SEARCH_URL);
      const headers = new Headers(init?.headers);
      assert.equal(headers.get('authorization'), 'Bearer access-live-token');
      const body = JSON.parse(String(init?.body)) as { enable_page_crawling?: boolean; text_query?: string };
      assert.equal(body.enable_page_crawling, false);
      assert.equal(body.text_query, 'TypeScript');
      return new Response(
        JSON.stringify({
          search_results: [
            {
              title: 'TypeScript',
              url: 'https://www.typescriptlang.org/',
              snippet: 'Typed JavaScript',
              site_name: 'TypeScript',
              date: '2026-01-01'
            }
          ]
        }),
        { status: 200 }
      );
    }
  });
  const hits = await provider.search('TypeScript', { limit: 5 });
  assert.deepEqual(hits, [
    {
      title: 'TypeScript',
      url: 'https://www.typescriptlang.org/',
      snippet: 'Typed JavaScript',
      publishedAt: '2026-01-01',
      site: 'TypeScript'
    }
  ]);
  assert.deepEqual(calls, [KIMI_SEARCH_URL]);
});

test('expired token refreshes, persists, then searches', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'kimi-web-'));
  const authPath = join(dir, 'auth.json');
  const now = 1_700_000_000_000;
  writeAuth(authPath, now - 1000);
  const provider = new KimiCodingWebSearchProvider({
    authPath,
    now: () => now,
    fetchImpl: async (input, init) => {
      const url = String(input);
      if (url === KIMI_OAUTH_TOKEN_URL) {
        const body = String(init?.body);
        assert.match(body, /grant_type=refresh_token/);
        assert.match(body, /refresh_token=refresh-live-token/);
        assert.doesNotMatch(body, /access-live-token/);
        return new Response(
          JSON.stringify({
            access_token: 'access-new-token',
            refresh_token: 'refresh-new-token',
            expires_in: 900
          }),
          { status: 200 }
        );
      }
      const headers = new Headers(init?.headers);
      assert.equal(headers.get('authorization'), 'Bearer access-new-token');
      return new Response(
        JSON.stringify({
          search_results: [{ title: 'Docs', url: 'https://example.com/docs', snippet: 'ok' }]
        }),
        { status: 200 }
      );
    }
  });
  const hits = await provider.search('docs', { limit: 3 });
  assert.equal(hits.length, 1);
  assert.equal(hits[0]?.url, 'https://example.com/docs');
  const stored = JSON.parse(readFileSync(authPath, 'utf8')) as {
    'kimi-coding': { access: string; refresh: string; expires: number };
  };
  assert.equal(stored['kimi-coding'].access, 'access-new-token');
  assert.equal(stored['kimi-coding'].refresh, 'refresh-new-token');
  assert.equal(stored['kimi-coding'].expires, 1_700_000_000_000 + 900_000);
});

test('401 search refreshes once and retries', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'kimi-web-'));
  const authPath = join(dir, 'auth.json');
  writeAuth(authPath, Date.now() + 10 * 60 * 1000);
  let searches = 0;
  const provider = new KimiCodingWebSearchProvider({
    authPath,
    fetchImpl: async (input) => {
      const url = String(input);
      if (url === KIMI_OAUTH_TOKEN_URL) {
        return new Response(
          JSON.stringify({
            access_token: 'access-after-401',
            refresh_token: 'refresh-after-401',
            expires_in: 900
          }),
          { status: 200 }
        );
      }
      searches += 1;
      if (searches === 1) return new Response('expired', { status: 401 });
      return new Response(
        JSON.stringify({ search_results: [{ title: 'Retry', url: 'https://example.com/r' }] }),
        { status: 200 }
      );
    }
  });
  const hits = await provider.search('retry', { limit: 2 });
  assert.equal(searches, 2);
  assert.equal(hits[0]?.title, 'Retry');
});

test('errors omit bearer tokens', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'kimi-web-'));
  const authPath = join(dir, 'auth.json');
  writeAuth(authPath, Date.now() + 10 * 60 * 1000, 'super-secret-access-token');
  const provider = new KimiCodingWebSearchProvider({
    authPath,
    fetchImpl: async () => new Response('nope super-secret-access-token', { status: 502 })
  });
  await assert.rejects(
    () => provider.search('x', { limit: 1 }),
    (error: unknown) => {
      assert.ok(error instanceof DomainError);
      assert.equal(error.code, 'WEB_SEARCH_FAILED');
      assert.equal(error.message.includes('super-secret-access-token'), false);
      return true;
    }
  );
});

test('createWebSearchProvider wires kimi without an API key', () => {
  const dir = mkdtempSync(join(tmpdir(), 'kimi-web-'));
  const authPath = join(dir, 'auth.json');
  writeAuth(authPath, Date.now() + 10 * 60 * 1000);
  const config = {
    webProvider: 'kimi',
    webApiKey: '',
    piAuthPath: authPath,
    assistantWebEnabled: true
  } as ServiceConfig;
  assert.equal(isWebSearchConfigured(config), true);
  const provider = createWebSearchProvider(config);
  assert.equal(provider?.name, 'kimi');
  assert.equal(isWebSearchConfigured({ ...config, webProvider: 'brave' }), false);
});
