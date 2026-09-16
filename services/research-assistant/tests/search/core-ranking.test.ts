import assert from 'node:assert/strict';
import { test } from 'node:test';

import { validateSearchPlan } from '../../src/search/identity.js';
import { applyHardFilters, rankHits } from '../../src/search/ranking.js';
import type { NormalizedSearchHit } from '../../src/search/contracts.js';

function hit(partial: Partial<NormalizedSearchHit> & { title: string; sourceId: string }): NormalizedSearchHit {
  return {
    platform: 'youtube',
    sourceType: 'video',
    canonicalURL: `https://www.youtube.com/watch?v=${partial.sourceId}`,
    provider: 'ytdlp',
    provenance: { title: 'ytdlp' },
    deepResearchAvailability: 'available',
    warnings: [],
    publishedAt: '2026-06-01T00:00:00Z',
    durationSeconds: 1800,
    description: partial.description ?? partial.title,
    ...partial
  };
}

test('ranking is deterministic for the same input order', () => {
  const plan = validateSearchPlan({ queries: ['Agent Harness interview'] });
  const hits = [
    hit({ sourceId: 'aaaaaaaaaaa', title: 'Unrelated clip', description: 'cats' }),
    hit({ sourceId: 'bbbbbbbbbbb', title: 'Agent Harness interview' }),
    hit({ sourceId: 'ccccccccccc', title: 'Agent Harness interview recap' })
  ];
  const first = rankHits(hits, plan).map((row) => `${row.rank}:${row.sourceId}:${row.matchReason}`);
  const second = rankHits(hits, plan).map((row) => `${row.rank}:${row.sourceId}:${row.matchReason}`);
  assert.deepEqual(first, second);
  assert.equal(rankHits(hits, plan)[0]?.sourceId, 'bbbbbbbbbbb');
  assert.equal(rankHits(hits, plan)[0]?.matchReason, 'title_exact');
  assert.equal(rankHits(hits, plan)[0]?.qualified, true);
});

test('provider rank alone does not qualify a candidate', () => {
  const plan = validateSearchPlan({ queries: ['Agent Harness interview'] });
  const ranked = rankHits(
    [hit({ sourceId: 'ddddddddddd', title: 'Minecraft walkthrough funny moments', description: 'gaming', providerRank: 1 })],
    plan
  );
  assert.equal(ranked[0]?.qualified, false);
  assert.equal(ranked[0]?.matchReason, 'unqualified');
});

test('hard date filter drops older publishedAt values', () => {
  const plan = validateSearchPlan({
    queries: ['latest AI news'],
    intent: 'recent',
    publishedAfter: '2026-01-01T00:00:00Z'
  });
  const { accepted, filtered } = applyHardFilters(
    [
      hit({ sourceId: 'oldeoldeold', title: 'latest AI news archive', publishedAt: '2022-01-01T00:00:00Z' }),
      hit({ sourceId: 'neweeneween', title: 'latest AI news', publishedAt: '2026-03-01T00:00:00Z' })
    ],
    plan
  );
  assert.equal(filtered, 1);
  assert.equal(accepted.length, 1);
  assert.equal(accepted[0]?.sourceId, 'neweeneween');
});
