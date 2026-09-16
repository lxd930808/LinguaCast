import assert from 'node:assert/strict';
import { test } from 'node:test';

import { hydrateYouTubeHits } from '../../src/search/youtube/hydrator.js';
import type { NormalizedSearchHit } from '../../src/search/contracts.js';
import { YouTubeDataApiProvider } from '../../src/search/youtube/data-api.js';
import { loadConfig } from '../../src/config/index.js';

function video(id: string): NormalizedSearchHit {
  return {
    platform: 'youtube',
    sourceType: 'video',
    sourceId: id,
    canonicalURL: `https://www.youtube.com/watch?v=${id}`,
    title: id,
    provider: 'ytdlp',
    provenance: { title: 'ytdlp' },
    deepResearchAvailability: 'available',
    warnings: []
  };
}

test('videos.list hydrates ten ids in one request', async () => {
  const ids = Array.from({ length: 10 }, (_, i) => `vid${String(i).padStart(8, '0')}`);
  let calls = 0;
  const config = loadConfig({
    ASSISTANT_IDENTITY_MODE: 'selfhost', ASSISTANT_SERVICE_TOKEN: 'test-assistant-token-0123456789',
    V10_SERVICE_TOKEN: 'test-v10-token-0123456789',
    V10_BASE_URL: 'https://content.example.test',
    NODE_ENV: 'test',
    YOUTUBE_API_KEY: 'yt-test-key-0123456789'
  });
  const api = new YouTubeDataApiProvider(config, async (url) => {
    calls += 1;
    assert.match(url.pathname, /\/videos$/);
    assert.equal(url.searchParams.get('id')?.split(',').length, 10);
    return {
      status: 200,
      json: {
        items: ids.map((id) => ({
          id,
          snippet: { title: `Title ${id}`, publishedAt: '2026-01-01T00:00:00Z' },
          contentDetails: { duration: 'PT12M' },
          statistics: { viewCount: '9' },
          status: { privacyStatus: 'public' }
        }))
      },
      text: '{}'
    };
  });
  const hits = await hydrateYouTubeHits(ids.map(video), {
    api,
    ytdlp: { details: async () => null } as never,
    hydrationEnabled: true,
    hasApiKey: true
  });
  assert.equal(calls, 1);
  assert.equal(hits[0]?.durationSeconds, 720);
  assert.equal(hits[0]?.title, `Title ${ids[0]}`);
});
