import assert from 'node:assert/strict';
import { test } from 'node:test';

import { assignStableIdentity, dedupeHits, hashNormalizedUrl, validateSearchPlan } from '../../src/search/identity.js';
import type { NormalizedSearchHit } from '../../src/search/contracts.js';

function hit(partial: Partial<NormalizedSearchHit> & Pick<NormalizedSearchHit, 'sourceType' | 'sourceId' | 'title'>): NormalizedSearchHit {
  return {
    platform: partial.platform ?? 'podcast',
    canonicalURL: partial.canonicalURL ?? `https://example.test/${partial.sourceId}`,
    provider: partial.provider ?? 'podcastindex',
    provenance: partial.provenance ?? { title: 'test' },
    deepResearchAvailability: partial.deepResearchAvailability ?? 'available',
    warnings: partial.warnings ?? [],
    ...partial
  };
}

test('YouTube identity requires an 11-character video id', () => {
  assert.throws(() =>
    assignStableIdentity(
      hit({ platform: 'youtube', sourceType: 'video', sourceId: 'short', title: 'x' })
    )
  );
  const video = assignStableIdentity(
    hit({ platform: 'youtube', sourceType: 'video', sourceId: 'dQw4w9WgXcQ', title: 'Talk' })
  );
  assert.equal(video.stableId, 'youtube:video:dQw4w9WgXcQ');
});

test('feed URLs with tracking params and trailing slashes are equivalent', () => {
  const a = hashNormalizedUrl('https://Feeds.Example.com/show/?utm_source=x');
  const b = hashNormalizedUrl('https://feeds.example.com/show');
  assert.equal(a, b);
});

test('PI feed and Apple iTunes alias merge into one show', () => {
  const pi = assignStableIdentity(
    hit({
      sourceType: 'podcast_show',
      sourceId: 'pi:feed:9',
      title: 'Acquired',
      podcastIndexFeedId: 9,
      itunesId: '123',
      feedURL: 'https://feeds.example.com/acquired.xml',
      provider: 'podcastindex'
    })
  );
  const apple = assignStableIdentity(
    hit({
      sourceType: 'podcast_show',
      sourceId: '123',
      title: 'Acquired',
      itunesId: '123',
      feedURL: 'https://feeds.example.com/acquired.xml',
      provider: 'apple_search',
      canonicalURL: 'https://podcasts.apple.com/podcast/id123'
    })
  );
  const merged = dedupeHits([pi, apple]);
  assert.equal(merged.length, 1);
  assert.equal(merged[0]?.provider, 'podcastindex');
  assert.ok(merged[0]?.warnings.includes('merged_providers'));
});

test('SearchPlan keeps entity text verbatim and expands now-Nd', () => {
  const plan = validateSearchPlan(
    { queries: ['Satya Nadella'], person: 'Satya Nadella', intent: 'recent', publishedAfter: 'now-30d' },
    new Date('2026-08-31T00:00:00Z')
  );
  assert.equal(plan.person, 'Satya Nadella');
  assert.equal(plan.publishedAfter, '2026-08-01T00:00:00Z');
});
