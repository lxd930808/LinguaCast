import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  DEFAULT_SESSION_TITLE,
  canAutoTitle,
  provisionalTitle,
  sanitizeLlmTitle
} from '../../src/research-v2/session-title.js';

test('provisionalTitle collapses whitespace and truncates to 40 chars', () => {
  assert.equal(provisionalTitle('  slow   english\nnews  '), 'slow english news');
  assert.equal(provisionalTitle(''), DEFAULT_SESSION_TITLE);
  const long = '会计'.repeat(30);
  assert.equal([...provisionalTitle(long)].length, 40);
});

test('sanitizeLlmTitle strips quotes markdown and trailing punctuation', () => {
  assert.equal(sanitizeLlmTitle('"英文慢速新闻"'), '英文慢速新闻');
  assert.equal(sanitizeLlmTitle('## Accounting AI.'), 'Accounting AI');
  assert.equal(sanitizeLlmTitle('「播客推荐」'), '播客推荐');
  assert.equal(sanitizeLlmTitle('   \n  '), null);
  assert.equal(sanitizeLlmTitle('a'.repeat(80))?.length, 40);
});

test('canAutoTitle only replaces default or matching provisional titles', () => {
  assert.equal(canAutoTitle(DEFAULT_SESSION_TITLE, 'slow english news'), true);
  assert.equal(canAutoTitle('slow english news', 'slow english news'), true);
  assert.equal(canAutoTitle('英文慢速新闻', 'slow english news'), false);
});
