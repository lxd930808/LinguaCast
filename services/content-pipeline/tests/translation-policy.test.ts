import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  chatCompletionsUrl,
  extractContent,
  isEmptyContent,
  maxConcurrentRequests,
  normalizedProvider,
  requestBody,
  retryDelaySeconds,
  shouldRetryHTTPStatus
} from '../src/providers/translation/policy.js';
import {
  alignedTranslationSplitSystemPrompt,
  batchSystemPrompt,
  contextExtractionSystemPrompt,
  promptNameForTarget,
  singleSystemPrompt
} from '../src/pipeline/translation/prompts.js';
import {
  blockContext,
  sampleContextTexts,
  termsMatching
} from '../src/pipeline/translation/context.js';
import { missingSequences, numberedUserPrompt, planBatches } from '../src/pipeline/translation/batches.js';
import type { LearningSegment } from '../src/pipeline/segmentation/types.js';

// Translation policy + prompt golden tests (WP6): pin request bodies,
// provider differences and prompt strings so server and Swift client stay
// wire-compatible.

function segment(sequence: number, text: string): LearningSegment {
  return {
    sequence,
    startMS: sequence * 1000,
    endMS: sequence * 1000 + 900,
    text,
    learningText: text,
    translation: '',
    notes: '',
    words: [],
    timingSource: 'wordTimeline'
  };
}

test('normalizedProvider recognizes OpenRouter and DeepSeek', () => {
  assert.equal(normalizedProvider('OpenRouter'), 'openrouter');
  assert.equal(normalizedProvider(' openrouter '), 'openrouter');
  assert.equal(normalizedProvider('dashscope'), 'dashscope');
  assert.equal(normalizedProvider(' DeepSeek '), 'deepseek');
  assert.equal(normalizedProvider('anything'), 'dashscope');
});

test('chatCompletionsUrl appends the versioned path exactly once', () => {
  assert.equal(
    chatCompletionsUrl('dashscope', 'https://dashscope.aliyuncs.com'),
    'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions'
  );
  assert.equal(
    chatCompletionsUrl('dashscope', 'https://dashscope.aliyuncs.com/compatible-mode/v1/'),
    'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions'
  );
  assert.equal(
    chatCompletionsUrl('openrouter', 'https://openrouter.ai/api'),
    'https://openrouter.ai/api/v1/chat/completions'
  );
  assert.equal(
    chatCompletionsUrl('openrouter', 'https://openrouter.ai/api/v1'),
    'https://openrouter.ai/api/v1/chat/completions'
  );
  assert.equal(
    chatCompletionsUrl('openrouter', 'http://127.0.0.1:9999/v1'),
    'http://127.0.0.1:9999/v1/chat/completions'
  );
});

test('requestBody golden: dashscope sends no reasoning field', () => {
  const body = requestBody('dashscope', 'qwen-turbo', null, [
    { role: 'system', content: 'S' },
    { role: 'user', content: 'U' }
  ]);
  assert.deepEqual(body, {
    model: 'qwen-turbo',
    messages: [
      { role: 'system', content: 'S' },
      { role: 'user', content: 'U' }
    ],
    temperature: 0.2,
    top_p: 0.7
  });
});

test('requestBody golden: openrouter nests reasoning effort', () => {
  const body = requestBody('openrouter', 'openai/gpt-5', 'high', [
    { role: 'system', content: 'S' },
    { role: 'user', content: 'U' }
  ]);
  assert.deepEqual(body, {
    model: 'openai/gpt-5',
    messages: [
      { role: 'system', content: 'S' },
      { role: 'user', content: 'U' }
    ],
    temperature: 0.2,
    top_p: 0.7,
    reasoning: { effort: 'high' }
  });
});

test('requestBody: unconfigured effort omits the reasoning field', () => {
  const body = requestBody('openrouter', 'm', null, []);
  assert.ok(!('reasoning' in body));
});

test('transient HTTP retry policy is openrouter-only (client parity)', () => {
  assert.ok(shouldRetryHTTPStatus(429, 'openrouter'));
  assert.ok(shouldRetryHTTPStatus(500, 'openrouter'));
  assert.ok(shouldRetryHTTPStatus(503, 'openrouter'));
  assert.ok(!shouldRetryHTTPStatus(404, 'openrouter'));
  assert.ok(!shouldRetryHTTPStatus(429, 'dashscope'));
  assert.ok(!shouldRetryHTTPStatus(500, 'dashscope'));
});

test('retryDelaySeconds honors Retry-After then exponential backoff', () => {
  assert.equal(
    retryDelaySeconds(429, 'openrouter', 1, { 'Retry-After': '17' }),
    17
  );
  assert.equal(retryDelaySeconds(429, 'openrouter', 1, {}), 2);
  assert.equal(retryDelaySeconds(500, 'openrouter', 2, {}), 4);
  assert.equal(retryDelaySeconds(503, 'openrouter', 3, {}), 8);
  assert.equal(retryDelaySeconds(503, 'openrouter', 9, {}), 8);
  assert.equal(retryDelaySeconds(429, 'dashscope', 1, { 'Retry-After': '5' }), null);
});

test('extractContent pulls choices[0].message.content', () => {
  assert.equal(
    extractContent({ choices: [{ message: { content: 'hello' } }] }),
    'hello'
  );
  assert.equal(extractContent({ choices: [] }), null);
  assert.equal(extractContent({}), null);
  assert.ok(isEmptyContent(null));
  assert.ok(isEmptyContent('   '));
  assert.ok(!isEmptyContent(' x '));
});

test('maxConcurrentRequests keeps small-batch fan-out at 3', () => {
  assert.equal(maxConcurrentRequests('dashscope'), 3);
  assert.equal(maxConcurrentRequests('openrouter'), 3);
});

test('promptNameForTarget covers every client locale and falls back to raw', () => {
  assert.equal(promptNameForTarget('zh-Hans'), 'Simplified Chinese');
  assert.equal(promptNameForTarget('zh-Hant'), 'Traditional Chinese');
  assert.equal(promptNameForTarget('pt-BR'), 'Brazilian Portuguese');
  assert.equal(promptNameForTarget('ar'), 'Arabic');
  assert.equal(promptNameForTarget('xx-YY'), 'xx-YY');
});

test('batchSystemPrompt golden: quality mode', () => {
  const prompt = batchSystemPrompt({
    target: 'zh-Hans',
    topicSummary: 'A show about libraries.',
    terms: [{ source: 'library', target: '图书馆', note: 'building' }],
    contextBefore: ['Earlier line.'],
    contextAfter: ['Later line.'],
    qualityMode: 'quality'
  });
  assert.equal(
    prompt,
    `You are translating English podcast transcript lines into concise Simplified Chinese for language learning.
Use the writing system implied by the target locale zh-Hans. Do not add explanations.
Return strict JSON only, an object keyed by each line's number:
{"1":{"origin":"<exact source line>","direct":"<literal Simplified Chinese>","reflection":"<one short improvement note>","final":"<natural Simplified Chinese>"}}
Include every provided number exactly once. \`origin\` must match the source line character-for-character.

Topic summary:
A show about libraries.

Glossary terms to honour:
- library → 图书馆 (building)

Previous lines (context only, do not translate):
Earlier line.

Following lines (context only, do not translate):
Later line.`
  );
});

test('batchSystemPrompt golden: fast mode with no context blocks', () => {
  const prompt = batchSystemPrompt({
    target: 'es',
    topicSummary: '',
    terms: [],
    contextBefore: [],
    contextAfter: [],
    qualityMode: 'fast'
  });
  assert.equal(
    prompt,
    `You are translating English podcast transcript lines into concise Spanish for language learning.
Use the writing system implied by the target locale es. Do not add explanations.
Return strict JSON only, an object keyed by each line's number:
{"1":{"origin":"<exact source line>","direct":"<literal Spanish>"}}
Include every provided number exactly once. \`origin\` must match the source line character-for-character.

Topic summary:
(none)`
  );
});

test('singleSystemPrompt golden: quality mode with terms', () => {
  const prompt = singleSystemPrompt({
    target: 'ja',
    topicSummary: 'Topic.',
    terms: [{ source: 'NASA', target: 'NASA', note: '' }],
    qualityMode: 'quality'
  });
  assert.equal(
    prompt,
    `You are translating one English podcast transcript line into concise Japanese for language learning.
Use the writing system implied by the target locale ja. Do not add explanations.
The user input is a JSON object with \`id\` and \`text\`. Translate only the decoded \`text\` value; \`id\` is metadata, never part of the source or translation. Copy \`text\` exactly into \`origin\`, including any numbering that is already inside \`text\`.
Return strict JSON only: {"origin":"<exact source line>","direct":"<literal Japanese>","reflection":"<one short improvement note>","final":"<natural Japanese>"}.
\`origin\` must match the source line character-for-character.

Topic summary:
Topic.

Glossary terms to honour:
- NASA → NASA`
  );
});

test('contextExtractionSystemPrompt and split prompt goldens', () => {
  assert.equal(
    contextExtractionSystemPrompt('zh-Hans'),
    `You analyze an English podcast transcript excerpt and return strict JSON only:
{"summary":"<two short sentences describing the topic>","terms":[{"source":"<English term>","target":"<Simplified Chinese rendering>","note":"<optional disambiguation>"}]}
Include at most 15 terms, only proper nouns / domain terms worth consistent translation.`
  );
  assert.equal(
    alignedTranslationSplitSystemPrompt('ko', 3),
    `You split a Korean translation into exactly 3 consecutive parts matching a source split.
Return strict JSON only: {"parts":["part1","part2",...]} with exactly 3 non-empty strings in order.
Do not translate again; only split the provided translation. Use the writing system implied by ko.`
  );
});

test('context sampling: short transcripts pass through whole', () => {
  const segments = [segment(1, 'One.'), segment(2, 'Two.')];
  assert.deepEqual(sampleContextTexts(segments), ['One.', 'Two.']);
});

test('context sampling: long transcripts sample 8 buckets within budget', () => {
  // 100 segments × 200 chars = 20000 chars total.
  const text = 'x'.repeat(200);
  const segments = Array.from({ length: 100 }, (_, i) => segment(i + 1, text));
  const sampled = sampleContextTexts(segments);
  const total = sampled.reduce((sum, t) => sum + t.length, 0);
  assert.ok(total <= 8000 + 200, `total ${total} exceeds budget`);
  assert.ok(sampled.length > 8, 'expected more than one sentence per bucket');
  // Order preserved: all sampled texts are identical here, so check count only.
});

test('blockContext returns previous 3 and following 2 lines', () => {
  const segments = Array.from({ length: 10 }, (_, i) => segment(i + 1, `line ${i + 1}`));
  const { before, after } = blockContext(segments, new Set([5, 6]));
  assert.deepEqual(before, ['line 2', 'line 3', 'line 4']);
  assert.deepEqual(after, ['line 7', 'line 8']);
});

test('termsMatching is case-insensitive and skips empty sources', () => {
  const terms = [
    { source: 'NASA', target: 'NASA', note: '' },
    { source: '', target: 'x', note: '' },
    { source: 'mars', target: '火星', note: '' }
  ];
  const matched = termsMatching(terms, 'The NASA rover landed on Mars.');
  assert.deepEqual(matched.map((t) => t.source), ['NASA', 'mars']);
});

test('planBatches splits on item and character budgets', () => {
  const segments = Array.from({ length: 25 }, (_, i) => segment(i + 1, 'short'));
  const batches = planBatches(segments, 10, 600);
  assert.deepEqual(batches.map((b) => b.segments.length), [10, 10, 5]);

  const long = [segment(1, 'a'.repeat(400)), segment(2, 'b'.repeat(400)), segment(3, 'c')];
  const charBatches = planBatches(long, 10, 600);
  assert.deepEqual(charBatches.map((b) => b.segments.map((s) => s.sequence)), [[1], [2, 3]]);
});

test('missingSequences and numberedUserPrompt', () => {
  const [batch] = planBatches([segment(3, 'three'), segment(4, 'four')], 10, 600);
  assert.deepEqual(missingSequences(batch, new Set([3])), [4]);
  assert.equal(numberedUserPrompt(batch), '3. three\n4. four');
});


test('DeepSeek default effort and versioned endpoint match the App', () => {
  assert.equal(chatCompletionsUrl('deepseek', 'https://api.deepseek.com/v1/'), 'https://api.deepseek.com/v1/chat/completions');
  assert.equal(requestBody('deepseek', 'deepseek-v4-flash', null, []).reasoning_effort, 'high');
  for (const status of [429, 500, 503]) assert.equal(shouldRetryHTTPStatus(status, 'deepseek'), true);
  assert.equal(shouldRetryHTTPStatus(401, 'deepseek'), false);
});
