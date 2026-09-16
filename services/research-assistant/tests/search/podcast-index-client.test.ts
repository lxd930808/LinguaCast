import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  PodcastIndexClient,
  PodcastIndexError,
  signPodcastIndex,
  podcastIndexHeaders
} from '../../src/search/podcast/podcast-index-client.js';

const KEY = 'test-podcastindex-key-aaaaaaaa';
const SECRET = 'test-podcastindex-secret-bbbbbbbb';
const NOW = 1_724_000_000;

test('Podcast Index signature is SHA1(key + secret + unixTime)', () => {
  const expected = signPodcastIndex(KEY, SECRET, NOW);
  assert.equal(expected.length, 40);
  const headers = podcastIndexHeaders(KEY, SECRET, NOW);
  assert.equal(headers['X-Auth-Key'], KEY);
  assert.equal(headers['X-Auth-Date'], String(NOW));
  assert.equal(headers.Authorization, expected);
  assert.equal(headers['User-Agent'], 'LinguaCastResearchAssistant/1.0');
});

test('401/429/HTML map to typed errors and never echo secrets', async () => {
  const cases: Array<{ status: number; body: string; type: string; code: string }> = [
    { status: 401, body: '{}', type: 'application/json', code: 'PODCASTINDEX_AUTH_FAILED' },
    { status: 429, body: '{}', type: 'application/json', code: 'PODCASTINDEX_RATE_LIMITED' },
    { status: 200, body: '<html>nope</html>', type: 'text/html', code: 'PODCASTINDEX_INVALID_RESPONSE' }
  ];
  for (const row of cases) {
    const client = new PodcastIndexClient({
      apiKey: KEY,
      apiSecret: SECRET,
      baseUrl: 'https://api.example.test/api/1.0',
      now: () => NOW,
      http: async () => ({
        status: row.status,
        headers: { 'content-type': row.type, 'retry-after': '12' },
        body: row.body
      })
    });
    await assert.rejects(
      () => client.searchByPerson('Ada Lovelace', 5),
      (error: unknown) => {
        assert.ok(error instanceof PodcastIndexError);
        assert.equal(error.code, row.code);
        assert.equal(error.message.includes(KEY), false);
        assert.equal(error.message.includes(SECRET), false);
        return true;
      }
    );
  }
});

test('oversized bodies are rejected before JSON parse', async () => {
  const client = new PodcastIndexClient({
    apiKey: KEY,
    apiSecret: SECRET,
    baseUrl: 'https://api.example.test/api/1.0',
    http: async () => ({
      status: 200,
      headers: { 'content-type': 'application/json' },
      body: 'x'.repeat(1_500_001)
    })
  });
  await assert.rejects(
    () => client.searchByTerm('q', 3),
    (error: unknown) => error instanceof PodcastIndexError && error.code === 'PODCASTINDEX_INVALID_RESPONSE'
  );
});
