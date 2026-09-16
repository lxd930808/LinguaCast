import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  parseContextResponse,
  parseNumberedBatchTranslations,
  parsePartialBatchTranslations,
  parseNumberedSingleTranslation,
  parseTranslationSplitParts,
  requiredTranslation,
  stripJSONMarkdown,
  TranslationContentError
} from '../src/pipeline/translation/parse.js';
import type { LearningSegment } from '../src/pipeline/segmentation/types.js';

// Strict numbered-JSON parser tests (WP6): malformed key sets, wrong
// sequences, origin mismatches, missing fields and markdown fences must all
// surface as TranslationContentError so the batch layer retries in place.

function segment(sequence: number, text: string): LearningSegment {
  return {
    sequence,
    startMS: 0,
    endMS: 1000,
    text,
    learningText: text,
    translation: '',
    notes: '',
    words: [],
    timingSource: 'wordTimeline'
  };
}

const EXPECTED = [segment(1, 'Hello world.'), segment(2, 'Second line here.')];

function batchResponse(entries: Record<string, unknown>): string {
  return JSON.stringify(entries);
}

test('valid quality batch parses and collapses interior whitespace', () => {
  const raw = batchResponse({
    '1': { origin: 'Hello world.', direct: '直译一', reflection: 'note', final: '你好\n世界。' },
    '2': { origin: 'Second line here.', direct: '直译二', reflection: 'note', final: '第二行。' }
  });
  const result = parseNumberedBatchTranslations(raw, EXPECTED, 'quality');
  assert.equal(result.get(1), '你好 世界。');
  assert.equal(result.get(2), '第二行。');
});

test('fast mode publishes direct and ignores final', () => {
  const raw = batchResponse({
    '1': { origin: 'Hello world.', direct: '直译一', final: '不应使用' },
    '2': { origin: 'Second line here.', direct: '直译二' }
  });
  const result = parseNumberedBatchTranslations(raw, EXPECTED, 'fast');
  assert.equal(result.get(1), '直译一');
});

test('markdown fences around the JSON are stripped', () => {
  const raw =
    '```json\n' +
    batchResponse({
      '1': { origin: 'Hello world.', direct: '直译一' },
      '2': { origin: 'Second line here.', direct: '直译二' }
    }) +
    '\n```';
  const result = parseNumberedBatchTranslations(raw, EXPECTED, 'fast');
  assert.equal(result.size, 2);
});

test('missing key, extra key and wrong sequence are invalidJSON', () => {
  const onlyOne = batchResponse({ '1': { origin: 'Hello world.', direct: 'x' } });
  assert.throws(() => parseNumberedBatchTranslations(onlyOne, EXPECTED, 'fast'), TranslationContentError);

  const extra = batchResponse({
    '1': { origin: 'Hello world.', direct: 'x' },
    '2': { origin: 'Second line here.', direct: 'y' },
    '3': { origin: 'Third.', direct: 'z' }
  });
  assert.throws(() => parseNumberedBatchTranslations(extra, EXPECTED, 'fast'), TranslationContentError);

  const wrongSeq = batchResponse({
    '1': { origin: 'Hello world.', direct: 'x' },
    '9': { origin: 'Second line here.', direct: 'y' }
  });
  assert.throws(() => parseNumberedBatchTranslations(wrongSeq, EXPECTED, 'fast'), TranslationContentError);
});

test('origin mismatch is invalidJSON', () => {
  const raw = batchResponse({
    '1': { origin: 'Hello world!', direct: 'x' },
    '2': { origin: 'Second line here.', direct: 'y' }
  });
  assert.throws(() => parseNumberedBatchTranslations(raw, EXPECTED, 'fast'), TranslationContentError);
});

test('missing required field is missingContent', () => {
  const raw = batchResponse({
    '1': { origin: 'Hello world.' },
    '2': { origin: 'Second line here.', direct: 'y' }
  });
  try {
    parseNumberedBatchTranslations(raw, EXPECTED, 'fast');
    assert.fail('expected throw');
  } catch (error) {
    assert.ok(error instanceof TranslationContentError);
    assert.equal(error.kind, 'missingContent');
  }
});

test('non-JSON and array payloads are invalidJSON', () => {
  assert.throws(() => parseNumberedBatchTranslations('not json', EXPECTED, 'fast'), TranslationContentError);
  assert.throws(() => parseNumberedBatchTranslations('[1,2]', EXPECTED, 'fast'), TranslationContentError);
});

test('single translation accepts bare object and numbered wrapper', () => {
  const bare = JSON.stringify({ origin: 'Hello world.', direct: '你好。' });
  assert.equal(parseNumberedSingleTranslation(bare, EXPECTED[0], 'fast'), '你好。');

  const wrapped = JSON.stringify({ '1': { origin: 'Hello world.', direct: '你好。' } });
  assert.equal(parseNumberedSingleTranslation(wrapped, EXPECTED[0], 'fast'), '你好。');

  const wrongOrigin = JSON.stringify({ origin: 'Other.', direct: 'x' });
  assert.throws(() => parseNumberedSingleTranslation(wrongOrigin, EXPECTED[0], 'fast'), TranslationContentError);
});

test('requiredTranslation picks the mode-specific field', () => {
  const entry = { direct: ' d ', final: ' f ' };
  assert.equal(requiredTranslation(entry, 'fast'), 'd');
  assert.equal(requiredTranslation(entry, 'quality'), 'f');
  assert.equal(requiredTranslation({ final: '' }, 'quality'), null);
});

test('parseContextResponse caps terms at 15 and drops incomplete entries', () => {
  const terms = Array.from({ length: 20 }, (_, i) => ({
    source: `term${i}`,
    target: `术语${i}`,
    note: ''
  }));
  terms.push({ source: '', target: 'x', note: '' });
  const parsed = parseContextResponse(
    JSON.stringify({ summary: '  A topic. ', terms })
  );
  assert.ok(parsed);
  assert.equal(parsed.topicSummary, 'A topic.');
  assert.equal(parsed.terms.length, 15);
  assert.equal(parseContextResponse('garbage'), null);
});

test('parseTranslationSplitParts requires the exact part count', () => {
  assert.deepEqual(parseTranslationSplitParts('{"parts":["a","b"]}', 2), ['a', 'b']);
  assert.equal(parseTranslationSplitParts('{"parts":["a"]}', 2), null);
  assert.equal(parseTranslationSplitParts('{"parts":["a",""]}', 2), null);
  assert.deepEqual(
    parseTranslationSplitParts('```json\n{"parts":[" a ","b"]}\n``` trailing', 2),
    ['a', 'b']
  );
  assert.equal(parseTranslationSplitParts('no json here', 2), null);
});

test('stripJSONMarkdown removes fences and trims', () => {
  assert.equal(stripJSONMarkdown('```json\n{}\n```'), '{}');
});


test('partial batch retains valid rows and identifies each failure without returning wrong rows', () => {
  const expected = Array.from({ length: 5 }, (_, i) => segment(i + 1, `Line ${i + 1}`));
  const parsed = parsePartialBatchTranslations(JSON.stringify({
    1: { origin: 'Line 1', final: '有效译文' },
    2: { origin: '2. Line 2', final: '错误原文' },
    3: { origin: 'Line 3', direct: '不能替代 final', final: '  ' },
    4: null,
    99: { origin: 'Line 5', final: '不能按原文猜测编号' }
  }), expected, 'quality');
  assert.deepEqual([...parsed.translations], [[1, '有效译文']]);
  assert.deepEqual(parsed.issues.filter((i) => i.sequence !== undefined), [
    { sequence: 2, kind: 'originMismatch' },
    { sequence: 3, kind: 'missingContent' },
    { sequence: 4, kind: 'invalidJSON' },
    { sequence: 5, kind: 'sequenceMismatch' }
  ]);
});

test('duplicate and aliased IDs cannot silently overwrite translations', () => {
  for (const key of ['"1"', '"01"', '"\\u0031"']) {
    const raw = '{"1":{"origin":"Hello world.","direct":"first"},' + key +
      ':{"origin":"Hello world.","direct":"second"},"2":{"origin":"Second line here.","direct":"valid"}}';
    const parsed = parsePartialBatchTranslations(raw, EXPECTED, 'fast');
    assert.deepEqual([...parsed.translations], [[2, 'valid']]);
    assert.ok(parsed.issues.some((i) => i.sequence === 1 && i.kind === 'sequenceMismatch'));
  }
});

test('key scanning ignores escaped quotes and nested keys in transcript content', () => {
  const text = '1. Say "hello", then read {"2": ["x"]}.\n第二行';
  const raw = JSON.stringify({ 7: { origin: text, final: '你好', reflection: { nested: 'key' } } });
  assert.deepEqual([...parsePartialBatchTranslations(raw, [segment(7, text)], 'quality').translations], [[7, '你好']]);
});

test('single origin mismatch is distinguished from missing translation and invalid JSON', () => {
  assert.throws(() => parseNumberedSingleTranslation('{"origin":"1. Hello world.","direct":"你好"}', EXPECTED[0], 'fast'), { kind: 'originMismatch' });
  assert.throws(() => parseNumberedSingleTranslation('{"origin":"Hello world.","direct":""}', EXPECTED[0], 'fast'), { kind: 'missingContent' });
  assert.throws(() => parseNumberedSingleTranslation('broken', EXPECTED[0], 'fast'), { kind: 'invalidJSON' });
});
