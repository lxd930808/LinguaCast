import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ALL_BUSINESS_TOOLS, FORBIDDEN_DEFAULT_TOOLS } from '../../src/agent/runtime.js';
import {
  assertNoDefaultCodingTools,
  extractPiAssistantText,
  isRedactedPiThinking,
  mapPiAssistantMessageEnd,
  mapPiThinkingUpdate,
  mapPiToolExecutionEnd,
  PiAgentRuntime,
  registeredPiToolNames,
  resolvePiModel,
  resolvePiRunTools,
  toPiHistoryMessages
} from '../../src/agent/pi-adapter.js';
import { describeUnknownError } from '../../src/domain/types.js';
import { loadConfig } from '../../src/config/index.js';

test('Pi adapter V2 registers six research tools and no legacy aliases', () => {
  const names = registeredPiToolNames(true);
  assert.deepEqual(names, [
    'search_youtube',
    'get_youtube_video_details',
    'search_podcasts',
    'get_podcast_episodes',
    'read_search_run',
    'save_research_report',
    'get_selected_source',
    'get_content_preparation_status',
    'search_current_transcript',
    'read_transcript_evidence',
    'save_grounded_answer'
  ]);
  assert.equal(names.includes('search_apple_podcasts'), false);
  assertNoDefaultCodingTools(names);
});

test('Pi run uses the V2 tool list from the orchestrator', () => {
  const names = resolvePiRunTools({
    kind: 'research',
    searchV2: true,
    tools: ['web_search', 'fetch_web_page', 'retrieve_evidence', 'save_research_report', 'search_youtube']
  });
  assert.deepEqual(names, [
    'web_search',
    'fetch_web_page',
    'retrieve_evidence',
    'save_research_report',
    'search_youtube'
  ]);
});

test('Pi run keeps V1 research tools when the caller does not pass a list', () => {
  assert.deepEqual(resolvePiRunTools({ kind: 'research', searchV2: false }), [
    'search_youtube',
    'search_apple_podcasts',
    'get_podcast_feed_episodes',
    'read_search_results',
    'save_research_report'
  ]);
});

test('Pi run still rejects default coding tools', () => {
  assert.throws(() =>
    resolvePiRunTools({
      kind: 'research',
      searchV2: true,
      tools: ['web_search', 'bash']
    })
  );
});

test('Pi adapter registers exactly the 10 business tools and no default coding tools', () => {
  const names = registeredPiToolNames();
  assert.deepEqual(names, [...ALL_BUSINESS_TOOLS]);
  assertNoDefaultCodingTools(names);
  for (const forbidden of FORBIDDEN_DEFAULT_TOOLS) {
    assert.equal((names as readonly string[]).includes(forbidden), false);
  }
});

test('PiAgentRuntime construction asserts the whitelist without calling a model', () => {
  const config = loadConfig({
    ASSISTANT_IDENTITY_MODE: 'selfhost', ASSISTANT_SERVICE_TOKEN: 'test-assistant-token-0123456789',
    V10_SERVICE_TOKEN: 'test-v10-token-0123456789',
    V10_BASE_URL: 'https://content.example.test',
    NODE_ENV: 'test'
  });
  const runtime = new PiAgentRuntime(config);
  assert.ok(runtime);
});

test('resolvePiModel finds DeepSeek from the builtin catalog', () => {
  const resolved = resolvePiModel({
    models: [{ alias: 'primary', provider: 'deepseek', model: 'deepseek-v4-flash' }]
  });
  assert.equal(resolved.provider, 'deepseek');
  assert.equal(resolved.modelId, 'deepseek-v4-flash');
});

test('assistant stopReason error becomes a model error, not an empty report', () => {
  const event = mapPiAssistantMessageEnd({
    role: 'assistant',
    stopReason: 'error',
    errorMessage: "Credential store modify failed for kimi-coding: EROFS: read-only file system, open '/var/lib/linguacast-assistant/pi/auth.json'",
    content: []
  });
  assert.equal(event?.type, 'error');
  assert.match(event?.error ?? '', /EROFS|Credential store modify failed/);
});

test('assistant abort without a detail still surfaces as a model error', () => {
  const event = mapPiAssistantMessageEnd({
    role: 'assistant',
    stopReason: 'aborted',
    content: [{ type: 'text', text: '' }]
  });
  assert.equal(event?.type, 'error');
  assert.match(event?.error ?? '', /aborted/);
});

test('successful assistant message_end is not a model error', () => {
  assert.equal(
    mapPiAssistantMessageEnd({
      role: 'assistant',
      stopReason: 'stop',
      content: [{ type: 'text', text: 'found two podcasts' }]
    }),
    null
  );
  assert.equal(extractPiAssistantText({ content: [{ type: 'text', text: 'found two podcasts' }] }), 'found two podcasts');
});

test('failed Pi tool execution stays a tool_result, not a fatal model error', () => {
  const event = mapPiToolExecutionEnd({
    toolName: 'search_youtube',
    toolCallId: 'tool_1',
    isError: true,
    result: { code: 'YTDLP_INVALID_OUTPUT', message: 'yt-dlp exited unsuccessfully' }
  });
  assert.equal(event.type, 'tool_result');
  assert.equal(event.tool, 'search_youtube');
  assert.equal(event.error, 'yt-dlp exited unsuccessfully');
});

test('thinking deltas map to thinking events, never text_delta', () => {
  const start = mapPiThinkingUpdate({ type: 'thinking_start', contentIndex: 0 });
  assert.equal(start.type, 'thinking');
  assert.equal(start.thinking?.stage, 'start');
  assert.equal(start.thinking?.blockId, 'th_0');

  const delta = mapPiThinkingUpdate({
    type: 'thinking_delta',
    contentIndex: 0,
    delta: 'The user wants research on accounting.',
    partial: { content: [{ type: 'thinking', thinking: 'The user wants' }] }
  });
  assert.equal(delta.type, 'thinking');
  assert.equal(delta.thinking?.stage, 'delta');
  assert.equal(delta.thinking?.text, 'The user wants research on accounting.');

  const end = mapPiThinkingUpdate(
    { type: 'thinking_end', contentIndex: 0 },
    1_000,
    false,
    () => 2_500
  );
  assert.equal(end.thinking?.stage, 'end');
  assert.equal(end.thinking?.durationMs, 1500);
  assert.equal(end.thinking?.redacted, undefined);
});

test('redacted reasoning maps to stage redacted and never carries text', () => {
  const byFlag = mapPiThinkingUpdate({
    type: 'thinking_delta',
    contentIndex: 0,
    delta: 'hidden',
    partial: { content: [{ type: 'thinking', thinking: 'hidden', redacted: true }] }
  });
  assert.equal(byFlag.thinking?.stage, 'redacted');
  assert.equal(byFlag.thinking?.text, undefined);
  assert.equal(byFlag.thinking?.redacted, true);

  const byPlaceholder = mapPiThinkingUpdate({
    type: 'thinking_delta',
    contentIndex: 1,
    delta: '[Reasoning redacted]'
  });
  assert.equal(byPlaceholder.thinking?.stage, 'redacted');
  assert.equal(byPlaceholder.thinking?.text, undefined);
  assert.equal(isRedactedPiThinking({ contentIndex: 1, delta: '[Reasoning redacted]' }), true);
  assert.equal(
    isRedactedPiThinking({ contentIndex: 0, delta: 'normal', partial: { content: [{ type: 'text', text: 'x' }] } }),
    false
  );

  const end = mapPiThinkingUpdate({ type: 'thinking_end', contentIndex: 0 }, 100, true, () => 200);
  assert.equal(end.thinking?.stage, 'end');
  assert.equal(end.thinking?.redacted, true);
});

test('describeUnknownError does not stringify objects as [object Object]', () => {
  assert.equal(describeUnknownError({ message: 'provider timeout' }), 'provider timeout');
  assert.notEqual(describeUnknownError({ code: 'YTDLP_INVALID_OUTPUT' }), '[object Object]');
});

test('toPiHistoryMessages keeps user and assistant turns for the next prompt', () => {
  const messages = toPiHistoryMessages([
    { role: 'user', markdown: '大模型领域谈论的RSI是什么', createdAt: '2026-08-31T06:03:18Z' },
    { role: 'assistant', markdown: 'RSI 是 Recursive Self-Improvement', createdAt: '2026-08-31T06:06:31Z' }
  ]);
  assert.equal(messages.length, 2);
  assert.equal(messages[0]?.role, 'user');
  assert.equal(messages[1]?.role, 'assistant');
  if (messages[0]?.role === 'user') assert.equal(messages[0].content, '大模型领域谈论的RSI是什么');
  if (messages[1]?.role === 'assistant') {
    const text = messages[1].content.find((part) => part.type === 'text');
    assert.equal(text && 'text' in text ? text.text : '', 'RSI 是 Recursive Self-Improvement');
  }
});
