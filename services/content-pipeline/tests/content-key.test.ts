import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { dedupeKey, podcastContentKey, videoContentKey } from '../src/domain/content-key.js';

interface Vector {
  name: string;
  contentType: 'podcast_episode' | 'video';
  input: Record<string, string>;
  normalizedFeedUrl?: string;
  expectedContentKey?: string;
  expectedDedupeKey?: string;
}

const vectorsDoc = JSON.parse(
  readFileSync(new URL('../fixtures/contract/content-key-vectors.json', import.meta.url), 'utf8')
) as { vectors: Vector[] };

test('content key golden vectors are stable', () => {
  for (const vector of vectorsDoc.vectors) {
    if (vector.expectedContentKey) {
      const actual =
        vector.contentType === 'podcast_episode'
          ? podcastContentKey(vector.input.feedUrl!, vector.input.episodeGuid!)
          : videoContentKey(vector.input.platform!, vector.input.videoId!);
      assert.equal(actual, vector.expectedContentKey, `vector ${vector.name}`);
    }
    if (vector.expectedDedupeKey) {
      const actual = dedupeKey({
        ownerScope: vector.input.ownerScope!,
        contentType: vector.input.contentType as 'podcast_episode' | 'video',
        contentKey: vector.input.contentKey!,
        sourceLanguage: vector.input.sourceLanguage!,
        targetLanguage: vector.input.targetLanguage!,
        translationQuality: vector.input.translationQuality as 'fast' | 'quality',
        pipelineVersion: vector.input.pipelineVersion!
      });
      assert.equal(actual, vector.expectedDedupeKey, `vector ${vector.name}`);
    }
  }
});

test('podcast key is stable across URL cosmetics', () => {
  const a = podcastContentKey('HTTPS://Example.COM:443/podcast/feed.xml#frag', 'ep-1');
  const b = podcastContentKey('https://example.com/podcast/feed.xml', 'ep-1');
  assert.equal(a, b);
});

test('dedupe key changes with any variant field', () => {
  const base = {
    ownerScope: 'selfhost',
    contentType: 'podcast_episode' as const,
    contentKey: 'podcast:aaaa:bbbb',
    sourceLanguage: 'en',
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality' as const,
    pipelineVersion: 'v10.1'
  };
  const baseKey = dedupeKey(base);
  assert.notEqual(dedupeKey({ ...base, targetLanguage: 'ja' }), baseKey);
  assert.notEqual(dedupeKey({ ...base, translationQuality: 'fast' }), baseKey);
  assert.notEqual(dedupeKey({ ...base, pipelineVersion: 'v10.2' }), baseKey);
  assert.notEqual(dedupeKey({ ...base, ownerScope: 'other' }), baseKey);
});
