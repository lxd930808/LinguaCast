import assert from 'node:assert/strict';
import { test } from 'node:test';

import { DomainError } from '../../src/domain/types.js';
import { CompositeSearchService, type SearchProvider } from '../../src/search/providers.js';

function hit(id: string) {
  return {
    platform: 'youtube' as const,
    sourceType: 'video' as const,
    sourceId: id,
    canonicalURL: `https://www.youtube.com/watch?v=${id}`,
    title: id,
    provider: 'youtube_api',
    fallback: true,
    provenance: { title: 'youtube_api' },
    deepResearchAvailability: 'available' as const,
    warnings: [] as string[]
  };
}

test('yt-dlp success does not call YouTube Data API', async () => {
  let apiCalls = 0;
  const ytdlp: SearchProvider = {
    name: 'ytdlp',
    async search() {
      return [hit('dQw4w9WgXcQ')];
    }
  };
  const api: SearchProvider = {
    name: 'youtube_api',
    async search() {
      apiCalls += 1;
      return [hit('aaaaaaaaaaa')];
    }
  };
  const service = new CompositeSearchService(ytdlp, api, ytdlp);
  const hits = await service.searchYouTube('english', 5);
  assert.equal(hits[0]?.sourceId, 'dQw4w9WgXcQ');
  assert.equal(apiCalls, 0);
});

test('empty or failed yt-dlp falls back to YouTube Data API exactly once', async () => {
  let apiCalls = 0;
  const empty: SearchProvider = {
    name: 'ytdlp',
    async search() {
      return [];
    }
  };
  const failing: SearchProvider = {
    name: 'ytdlp',
    async search() {
      throw new DomainError('YTDLP_TIMEOUT', 'timed out', true, 503);
    }
  };
  const api: SearchProvider = {
    name: 'youtube_api',
    async search() {
      apiCalls += 1;
      return [hit('dQw4w9WgXcQ')];
    }
  };
  const fromEmpty = new CompositeSearchService(empty, api, empty);
  assert.equal((await fromEmpty.searchYouTube('q', 3))[0]?.sourceId, 'dQw4w9WgXcQ');
  const fromFail = new CompositeSearchService(failing, api, empty);
  assert.equal((await fromFail.searchYouTube('q', 3)).length, 1);
  assert.equal(apiCalls, 2);
});

test('identical query hits the search cache and does not call upstream again', async () => {
  let calls = 0;
  const ytdlp: SearchProvider = {
    name: 'ytdlp',
    async search() {
      calls += 1;
      return [hit('dQw4w9WgXcQ')];
    }
  };
  const service = new CompositeSearchService(ytdlp, null, ytdlp);
  await service.searchYouTube('cache me', 4);
  await service.searchYouTube('cache me', 4);
  assert.equal(calls, 1);
});
