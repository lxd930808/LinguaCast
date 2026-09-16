import assert from 'node:assert/strict';
import { test } from 'node:test';

import { EVAL_CORPUS } from '../../evaluation/corpus.js';
import { buildReport } from '../../scripts/evaluate-search.js';
import { v13BaselineRuns, V13_BASELINE_FIXTURE_VERSION } from '../../evaluation/v13-baseline.js';

test('labeled corpus meets V14 coverage constraints', () => {
  assert.ok(EVAL_CORPUS.length >= 60, `need >=60 queries, got ${EVAL_CORPUS.length}`);
  const ids = EVAL_CORPUS.map((row) => row.id);
  assert.equal(new Set(ids).size, ids.length, 'duplicate query ids');
  const queries = EVAL_CORPUS.map((row) => row.query.normalize('NFC').trim().toLowerCase());
  assert.equal(new Set(queries).size, queries.length, 'duplicate query text');
  const en = EVAL_CORPUS.filter((row) => row.language === 'en').length;
  const zh = EVAL_CORPUS.filter((row) => row.language === 'zh').length;
  assert.ok(en >= 20, `english ${en}`);
  assert.ok(zh >= 20, `chinese ${zh}`);
  for (const intent of ['topic', 'person', 'show', 'channel', 'recent'] as const) {
    const count = EVAL_CORPUS.filter((row) => row.intent === intent).length;
    assert.ok(count >= 8, `${intent} ${count}`);
  }
  assert.ok(EVAL_CORPUS.filter((row) => row.ambiguous).length >= 10);
  assert.ok(EVAL_CORPUS.filter((row) => row.expectZero).length >= 10);
  for (const row of EVAL_CORPUS) {
    assert.ok(row.media.length >= 1, `${row.id} missing media`);
    assert.ok(row.intent, `${row.id} missing intent`);
    if (!row.expectZero) {
      assert.ok(row.relevant.length >= 1, `${row.id} missing relevant labels`);
    }
  }
});

test('baseline runner is deterministic', () => {
  const first = buildReport('baseline', v13BaselineRuns(), V13_BASELINE_FIXTURE_VERSION);
  const second = buildReport('baseline', v13BaselineRuns(), V13_BASELINE_FIXTURE_VERSION);
  assert.deepEqual(first.metrics, second.metrics);
  assert.deepEqual(first.perQuery, second.perQuery);
  assert.equal(first.metrics.queryCount, EVAL_CORPUS.length);
  assert.ok(first.metrics.youtubeTop5Precision != null);
});
