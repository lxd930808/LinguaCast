import assert from 'node:assert/strict';
import { test } from 'node:test';

import { loadConfig } from '../../src/config/index.js';
import { ApplePodcastSearchProvider } from '../../src/search/podcast/apple-search.js';
import { PodcastSearchOrchestrator } from '../../src/search/podcast/orchestrator.js';
import type { HttpGet } from '../../src/search/http.js';
import type { SearchPlan } from '../../src/search/contracts.js';

function config() {
  return loadConfig({
    ASSISTANT_IDENTITY_MODE: 'selfhost', ASSISTANT_SERVICE_TOKEN: 'test-assistant-token-0123456789',
    V10_SERVICE_TOKEN: 'test-v10-token-0123456789',
    V10_BASE_URL: 'https://content.example.test',
    NODE_ENV: 'test',
    APPLE_SEARCH_BASE_URL: 'https://itunes.example.test'
  });
}

test('Apple episode search returns selectable episodes with enclosure', async () => {
  const httpGet: HttpGet = async (url) => {
    assert.equal(url.searchParams.get('entity'), 'podcastEpisode');
    return {
      status: 200,
      text: '{}',
      json: {
        results: [
          {
            trackId: 88001,
            trackName: 'Self-improving agents',
            collectionId: 42,
            collectionName: 'ML Street Talk',
            artistName: 'MLST',
            feedUrl: 'https://feeds.example.test/show.xml',
            episodeUrl: 'https://cdn.example.test/ep.mp3',
            trackViewUrl: 'https://podcasts.apple.com/episode/id88001',
            artworkUrl600: 'https://is1.example.test/art.jpg',
            releaseDate: '2026-01-15T00:00:00Z',
            trackTimeMillis: 3_600_000,
            description: 'A conversation about recursive self-improvement.'
          }
        ]
      }
    };
  };
  const apple = new ApplePodcastSearchProvider(config(), httpGet);
  const hits = await apple.searchEpisodes('self improving', 5, 'US');
  assert.equal(hits.length, 1);
  assert.equal(hits[0]?.sourceType, 'podcast_episode');
  assert.equal(hits[0]?.deepResearchAvailability, 'available');
  assert.equal(hits[0]?.enclosureUrl, 'https://cdn.example.test/ep.mp3');
  assert.equal(hits[0]?.title, 'Self-improving agents');
});

test('orchestrator Apple fallback includes episodes when Podcast Index is off', async () => {
  const httpGet: HttpGet = async (url) => {
    const entity = url.searchParams.get('entity');
    if (entity === 'podcastEpisode') {
      return {
        status: 200,
        text: '{}',
        json: {
          results: [
            {
              trackId: 9,
              trackName: 'Episode 9',
              collectionId: 1,
              collectionName: 'Show',
              feedUrl: 'https://feeds.example.test/show.xml',
              episodeUrl: 'https://cdn.example.test/9.mp3',
              trackViewUrl: 'https://podcasts.apple.com/episode/id9'
            }
          ]
        }
      };
    }
    return {
      status: 200,
      text: '{}',
      json: {
        results: [
          {
            collectionId: 1,
            collectionName: 'Show',
            artistName: 'Host',
            feedUrl: 'https://feeds.example.test/show.xml',
            collectionViewUrl: 'https://podcasts.apple.com/podcast/id1'
          }
        ]
      }
    };
  };
  const apple = new ApplePodcastSearchProvider(config(), httpGet);
  const orchestrator = new PodcastSearchOrchestrator({
    index: null,
    apple,
    httpGet,
    enabled: false
  });
  const plan: SearchPlan = {
    intent: 'topic',
    media: ['podcast'],
    queries: ['self improving'],
    person: null,
    showOrChannel: null,
    language: 'en',
    region: 'US',
    publishedAfter: null,
    publishedBefore: null,
    duration: 'any',
    clean: true
  };
  const outcome = await orchestrator.search(plan, 5);
  assert.equal(outcome.hits.some((hit) => hit.sourceType === 'podcast_episode'), true);
  assert.equal(outcome.hits.some((hit) => hit.sourceType === 'podcast_show'), true);
});
