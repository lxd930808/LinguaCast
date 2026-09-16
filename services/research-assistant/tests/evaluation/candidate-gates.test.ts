import assert from 'node:assert/strict';
import { test } from 'node:test';

import { EVAL_CORPUS } from '../../evaluation/corpus.js';
import { v14CandidateRuns } from '../../evaluation/v14-candidate.js';
import { aggregate } from '../../scripts/evaluate-search.js';

test('V14 candidate ranking fixtures meet offline quality gates', () => {
  const metrics = aggregate(EVAL_CORPUS, v14CandidateRuns());
  assert.ok((metrics.youtubeTop5Precision ?? 0) >= 0.8, `youtube ${metrics.youtubeTop5Precision}`);
  assert.ok((metrics.podcastTop5Precision ?? 0) >= 0.8, `podcast ${metrics.podcastTop5Precision}`);
  assert.ok((metrics.personEpisodeTop5Precision ?? 0) >= 0.85, `person ${metrics.personEpisodeTop5Precision}`);
  assert.ok(metrics.qualifiedHitCoverage >= 0.9, `coverage ${metrics.qualifiedHitCoverage}`);
  assert.equal(metrics.dateCompliance, 1);
  assert.ok(metrics.reportOffTopicRate < 0.05, `off-topic ${metrics.reportOffTopicRate}`);
});
