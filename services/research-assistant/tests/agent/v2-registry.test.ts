import assert from 'node:assert/strict';
import { test } from 'node:test';

import { assertV2ToolAllowed } from '../../src/agent/v2/guard.js';
import { toolsForTurn, toolsVisibleToAgent, V2_ALL_TOOLS } from '../../src/agent/v2/tools.js';
import { V2_PARAMETER_SCHEMAS, V2_TOOL_DESCRIPTIONS } from '../../src/agent/v2/pi-schemas.js';
import { ALL_BUSINESS_TOOLS, FORBIDDEN_DEFAULT_TOOLS, RESEARCH_TOOLS, QA_TOOLS } from '../../src/agent/runtime.js';
import { DomainError } from '../../src/domain/types.js';

test('V1 business tool sets are unchanged', () => {
  assert.deepEqual([...RESEARCH_TOOLS], [
    'search_youtube',
    'search_apple_podcasts',
    'get_podcast_feed_episodes',
    'read_search_results',
    'save_research_report'
  ]);
  assert.deepEqual([...QA_TOOLS], [
    'get_selected_source',
    'get_content_preparation_status',
    'search_current_transcript',
    'read_transcript_evidence',
    'save_grounded_answer'
  ]);
  assert.equal(ALL_BUSINESS_TOOLS.length, 10);
});

test('V2 research and content_qa tool snapshots never include default coding tools', () => {
  const research = [...toolsForTurn('research', 'gathering')].sort();
  const qa = [...toolsForTurn('content_qa')].sort();
  assert.deepEqual(research, [
    'fetch_web_page',
    'get_artifact',
    'get_podcast_episodes',
    'get_selected_source',
    'get_transcript_job',
    'get_youtube_video_details',
    'grep_files',
    'list_files',
    'propose_global_memory',
    'read_file',
    'read_search_run',
    'request_transcription',
    'retrieve_evidence',
    'save_artifact',
    'search_files',
    'search_podcasts',
    'search_youtube',
    'web_search',
    'write_file',
    'write_research_memory'
  ]);
  assert.deepEqual(qa, [
    'get_artifact',
    'get_selected_source',
    'get_transcript_job',
    'grep_files',
    'list_files',
    'read_file',
    'retrieve_evidence',
    'save_research_report',
    'search_files',
    'write_research_memory'
  ]);
  for (const name of [...research, ...qa, ...V2_ALL_TOOLS]) {
    assert.equal(FORBIDDEN_DEFAULT_TOOLS.includes(name), false);
  }
});

test('research agent sees web fetch, evidence, and report tools across phases', () => {
  const visible = [...toolsVisibleToAgent('research')] as string[];
  for (const required of ['web_search', 'fetch_web_page', 'retrieve_evidence', 'save_research_report', 'search_youtube']) {
    assert.equal(visible.includes(required), true, `missing ${required}`);
  }
  assert.equal(visible.includes('bash'), false);
  assert.equal(visible.includes('web'), false);
});

test('every V2 tool has a Pi schema and description', () => {
  for (const name of V2_ALL_TOOLS) {
    assert.equal(Boolean(V2_PARAMETER_SCHEMAS[name]), true, `missing schema ${name}`);
    assert.equal(Boolean(V2_TOOL_DESCRIPTIONS[name]), true, `missing description ${name}`);
  }
});

test('beforeToolCall blocks forged tools, research ids, grants, and confirmation tokens', () => {
  const base = {
    kind: 'research' as const,
    phase: 'gathering' as const,
    researchId: '01ARZ3NDEKTSV4RRFFQ69G5FAV',
    turnId: 'vt_01ARZ3NDEKTSV4RRFFQ69G5FAV',
    expectedResearchId: '01ARZ3NDEKTSV4RRFFQ69G5FAV',
    expectedTurnId: 'vt_01ARZ3NDEKTSV4RRFFQ69G5FAV',
    grantAliases: ['notes']
  };
  assert.throws(
    () => assertV2ToolAllowed({ ...base, tool: 'bash' }),
    (error: unknown) => error instanceof DomainError && error.code === 'TOOL_NOT_ALLOWED'
  );
  assert.throws(
    () => assertV2ToolAllowed({ ...base, tool: 'web' }),
    (error: unknown) => error instanceof DomainError && error.code === 'TOOL_NOT_ALLOWED'
  );
  assert.throws(
    () => assertV2ToolAllowed({ ...base, tool: 'list_files', researchId: 'other' }),
    (error: unknown) => error instanceof DomainError && error.code === 'FORBIDDEN'
  );
  assert.throws(
    () => assertV2ToolAllowed({ ...base, tool: 'request_transcription' }),
    (error: unknown) => error instanceof DomainError && error.code === 'TRANSCRIPT_CONFIRMATION_REQUIRED'
  );
  assert.throws(
    () => assertV2ToolAllowed({ ...base, tool: 'read_file', uri: 'shared://secret/x.md' }),
    (error: unknown) => error instanceof DomainError && error.code === 'WORKSPACE_GRANT_DENIED'
  );
  assert.doesNotThrow(() =>
    assertV2ToolAllowed({ ...base, tool: 'read_file', uri: 'shared://notes/x.md' })
  );
});
