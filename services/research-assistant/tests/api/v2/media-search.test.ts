import assert from 'node:assert/strict';
import { test } from 'node:test';

import { mediaSearchFromOrchestrator } from '../../../src/api/v2/media-search.js';
import type { SearchOrchestrator } from '../../../src/search/orchestrator.js';
import type { NormalizedSearchHit } from '../../../src/search/contracts.js';

function episodeHit(): NormalizedSearchHit {
  return {
    platform: 'podcast',
    sourceType: 'podcast_episode',
    sourceId: 'ep-1',
    canonicalURL: 'https://podcasts.apple.com/episode/id9',
    title: 'Episode 9',
    provider: 'apple_search',
    publishedAt: '2026-01-15T00:00:00Z',
    provenance: { title: 'apple_search' },
    deepResearchAvailability: 'available',
    warnings: [],
    feedURL: 'https://feeds.example.test/show.xml',
    enclosureUrl: 'https://cdn.example.test/9.mp3'
  };
}

test('V2 media search keeps podcast feed and enclosure for V10', async () => {
  const orchestrator = {
    async searchYouTube() {
      return { hits: [] };
    },
    async search() {
      return { hits: [episodeHit()], warnings: [] };
    }
  } as unknown as SearchOrchestrator;
  const search = mediaSearchFromOrchestrator(orchestrator);
  assert.ok(search);
  const podcasts = await search.searchPodcasts('accounting', 5);
  assert.equal(podcasts.hits.length, 1);
  assert.equal(podcasts.hits[0]?.sourceType, 'podcast_episode');
  assert.equal(podcasts.hits[0]?.feedURL, 'https://feeds.example.test/show.xml');
  assert.equal(podcasts.hits[0]?.enclosureUrl, 'https://cdn.example.test/9.mp3');
});
