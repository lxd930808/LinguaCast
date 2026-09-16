import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ALL_BUSINESS_TOOLS, assertToolWhitelist, FORBIDDEN_DEFAULT_TOOLS } from '../../src/agent/runtime.js';

test('business tool whitelist is exactly 10 names', () => {
  assert.deepEqual(
    [...ALL_BUSINESS_TOOLS],
    [
      'search_youtube',
      'search_apple_podcasts',
      'get_podcast_feed_episodes',
      'read_search_results',
      'save_research_report',
      'get_selected_source',
      'get_content_preparation_status',
      'search_current_transcript',
      'read_transcript_evidence',
      'save_grounded_answer'
    ]
  );
  assertToolWhitelist(ALL_BUSINESS_TOOLS);
});

test('adding a default coding tool fails the whitelist assertion', () => {
  for (const forbidden of FORBIDDEN_DEFAULT_TOOLS.slice(0, 3)) {
    assert.throws(() => assertToolWhitelist([...ALL_BUSINESS_TOOLS, forbidden]));
  }
  assert.throws(() => assertToolWhitelist(ALL_BUSINESS_TOOLS.slice(1)));
});
