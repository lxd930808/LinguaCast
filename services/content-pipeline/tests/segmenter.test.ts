import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  bestBinarySplit,
  PODCAST_PROFILE,
  renderText,
  resegmentLearningSegments,
  segmentsFromWords
} from '../src/pipeline/segmentation/sentence-segmenter.js';
import { weightedLength } from '../src/pipeline/segmentation/weighted-length.js';
import type { LearningSegment, TranscriptWord } from '../src/pipeline/segmentation/types.js';

// Segmenter vectors (WP5) — mirrors TimedTextSentenceSegmenterTests.swift so
// the TS and Swift implementations provably cut identically.

const profile = PODCAST_PROFILE;

function word(text: string, start: number, end: number, punctuation?: string): TranscriptWord {
  return { text, startMS: start, endMS: end, ...(punctuation ? { punctuation } : {}) };
}

function assertWordPreservation(original: TranscriptWord[], segments: LearningSegment[]): void {
  const rebuilt = segments.flatMap((s) => s.words);
  assert.deepEqual(rebuilt.map((w) => w.text), original.map((w) => w.text));
  assert.deepEqual(rebuilt.map((w) => w.startMS), original.map((w) => w.startMS));
  assert.deepEqual(rebuilt.map((w) => w.endMS), original.map((w) => w.endMS));
  assert.deepEqual(
    rebuilt.map((w) => w.punctuation ?? null),
    original.map((w) => w.punctuation ?? null)
  );
}

function assertMonotonic(segments: LearningSegment[]): void {
  for (const segment of segments) {
    assert.ok(segment.startMS <= segment.endMS);
  }
  for (let i = 1; i < segments.length; i += 1) {
    assert.ok(segments[i - 1].endMS <= segments[i].endMS);
  }
}

test('podcast profile matches the frozen defaults', () => {
  assert.deepEqual(profile, {
    softPauseMS: 250,
    strongPauseMS: 700,
    targetDurationMS: 4000,
    maxDurationMS: 7000,
    targetWeightedLength: 60,
    maxWeightedLength: 75,
    minimumWordCount: 2
  });
});

test('splits on sentence-ending punctuation', () => {
  const words = [
    word('Hello', 0, 300, '.'),
    word('How', 400, 600),
    word('are', 620, 800),
    word('you', 820, 1000, '?')
  ];
  const segments = segmentsFromWords(words, profile);
  assert.deepEqual(segments.map((s) => s.text), ['Hello.', 'How are you?']);
  assert.deepEqual(segments[0].words.map((w) => w.text), ['Hello']);
  assert.deepEqual(segments[1].words.map((w) => w.text), ['How', 'are', 'you']);
});

test('splits on clause punctuation when packing a long run', () => {
  const tokens: Array<[string, string?]> = [
    ['We'], ['discussed'], ['several'], ['important'],
    ['topics', ','], ['including'], ['budget'], ['planning'],
    ['timeline'], ['risks'], ['and'], ['staffing'],
    ['changes'], ['across'], ['teams'], ['worldwide', '.']
  ];
  const words: TranscriptWord[] = [];
  let cursor = 0;
  for (const [text, punct] of tokens) {
    words.push(word(text, cursor, cursor + 500, punct));
    cursor += 520; // ~8.3s total → over the 7s max
  }
  const segments = segmentsFromWords(words, profile);
  assert.ok(segments.length > 1);
  assert.ok(segments.some((s) => s.text.endsWith(',') || s.text.includes('topics,')));
  assertWordPreservation(words, segments);
});

test('splits on a strong 700ms pause', () => {
  const words = [
    word('First', 0, 400),
    word('part', 420, 800),
    word('Second', 1600, 2000),
    word('part', 2020, 2400)
  ];
  const segments = segmentsFromWords(words, profile);
  assert.equal(segments.length, 2);
  assert.equal(segments[0].text, 'First part');
  assert.equal(segments[1].text, 'Second part');
  assert.equal(segments[1].startMS, 1600);
});

test('soft pause preferred over zero-gap when forced', () => {
  const words: TranscriptWord[] = [];
  let cursor = 0;
  for (let index = 0; index < 8; index += 1) {
    words.push(word(`alpha${index}`, cursor, cursor + 900));
    cursor += 920;
  }
  const mid = 4;
  for (let index = mid; index < words.length; index += 1) {
    words[index].startMS += 300;
    words[index].endMS += 300;
  }
  const segments = segmentsFromWords(words, profile);
  assert.ok(segments.length > 1);
  assert.equal(segments[0].words.length, mid);
  assertWordPreservation(words, segments);
});

test('force splits when exceeding max duration', () => {
  const words: TranscriptWord[] = [];
  let cursor = 0;
  for (let index = 0; index < 20; index += 1) {
    words.push(word(`word${index}`, cursor, cursor + 400));
    cursor += 420; // ~8.4s
  }
  const segments = segmentsFromWords(words, profile);
  assert.ok(segments.length > 1);
  for (const segment of segments) {
    if (segment.words.length > 1) {
      assert.ok(segment.endMS - segment.startMS <= profile.maxDurationMS);
    }
  }
  assertWordPreservation(words, segments);
});

test('force splits when exceeding max weighted length', () => {
  const words = Array.from({ length: 12 }, (_, index) =>
    word('x'.repeat(10) + index, index * 50, index * 50 + 40)
  );
  const segments = segmentsFromWords(words, profile);
  assert.ok(segments.length > 1);
  for (const segment of segments) {
    if (segment.words.length > 1) {
      assert.ok(weightedLength(segment.text) <= profile.maxWeightedLength);
    }
  }
  assertWordPreservation(words, segments);
});

test('a single oversized word is kept unsplittable', () => {
  const words = [word('supercalifragilistic'.repeat(6), 0, 500)];
  const segments = segmentsFromWords(words, profile);
  assert.equal(segments.length, 1);
  assert.equal(segments[0].words.length, 1);
  assert.ok(weightedLength(segments[0].text) > profile.maxWeightedLength);
});

test('continuous zero-pause input still segments', () => {
  const words = Array.from({ length: 16 }, (_, index) =>
    word(`token${index}`, index * 500, (index + 1) * 500)
  );
  const segments = segmentsFromWords(words, profile);
  assert.ok(segments.length > 1);
  assertMonotonic(segments);
  assertWordPreservation(words, segments);
});

test('overlapping timestamps treat the gap as zero', () => {
  const words = [
    word('One', 0, 1000),
    word('two', 800, 1600),
    word('three', 1500, 2200),
    word('four', 2100, 3000),
    word('five', 2900, 4000),
    word('six', 3900, 5000),
    word('seven', 4900, 6000),
    word('eight', 5900, 7500),
    word('nine', 7400, 8500),
    word('ten', 8400, 9500)
  ];
  const segments = segmentsFromWords(words, profile);
  assert.ok(segments.length > 0);
  assertWordPreservation(words, segments);
  assertMonotonic(segments);
});

test('empty word stream returns empty', () => {
  assert.deepEqual(segmentsFromWords([], profile), []);
  assert.equal(bestBinarySplit([], profile), null);
});

test('deterministic tie-break is stable across runs', () => {
  const words = Array.from({ length: 10 }, (_, index) =>
    word(`even${index}`, index * 800, index * 800 + 700)
  );
  const first = segmentsFromWords(words, profile);
  const second = segmentsFromWords(words, profile);
  assert.deepEqual(first.map((s) => s.text), second.map((s) => s.text));
  assert.deepEqual(first.map((s) => s.startMS), second.map((s) => s.startMS));
});

test('avoids breaking after English function words when possible', () => {
  const tokens = [
    'Discussing', 'major', 'organizational', 'changes',
    'the', 'board', 'approved', 'yesterday',
    'after', 'careful', 'review', 'process',
    'completed', 'last', 'quarter', 'finally'
  ];
  const words: TranscriptWord[] = [];
  let cursor = 0;
  for (const text of tokens) {
    words.push(word(text, cursor, cursor + 500));
    cursor += 520;
  }
  const cut = bestBinarySplit(words, profile);
  assert.ok(cut !== null);
  const leftLast = words[cut - 1].text.toLowerCase();
  assert.ok(!['the', 'of', 'a', 'an', 'and', 'or', 'to', 'for'].includes(leftLast));
});

test('bestBinarySplit prefers sentence end', () => {
  const words = [
    word('Hello', 0, 400, '.'),
    word('Friends', 500, 900),
    word('gather', 920, 1300),
    word('here', 1320, 1700)
  ];
  assert.equal(bestBinarySplit(words, profile), 1);
});

test('bestBinarySplit prefers strong pause', () => {
  const words = [
    word('Left', 0, 400),
    word('side', 420, 800),
    word('Right', 1700, 2100),
    word('side', 2120, 2500)
  ];
  assert.equal(bestBinarySplit(words, profile), 2);
});

test('bestBinarySplit returns null for a single word', () => {
  assert.equal(bestBinarySplit([word('Only', 0, 300)], profile), null);
});

test('preserves all words once with a monotonic timeline', () => {
  const words: TranscriptWord[] = [];
  let cursor = 0;
  for (let index = 0; index < 24; index += 1) {
    const punct = index === 7 || index === 15 ? '.' : undefined;
    words.push(word(`w${index}`, cursor, cursor + 280, punct));
    cursor += index === 7 ? 900 : 300;
  }
  const segments = segmentsFromWords(words, profile);
  assertWordPreservation(words, segments);
  assertMonotonic(segments);
  assert.equal(segments[0].startMS, words[0].startMS);
  assert.equal(segments[segments.length - 1].endMS, words[words.length - 1].endMS);
  for (const segment of segments) {
    assert.equal(segment.timingSource, 'wordTimeline');
    assert.notEqual(segment.text, '');
    assert.equal(segment.learningText, segment.text);
  }
});

test('resegment is purely local and preserves metadata', () => {
  const asr: LearningSegment[] = [
    {
      sequence: 1,
      startMS: 0,
      endMS: 2400,
      text: 'Hello. How are you?',
      learningText: 'Hello. How are you?',
      translation: '',
      speaker: 'host',
      notes: '',
      words: [
        word('Hello', 0, 300, '.'),
        word('How', 400, 600),
        word('are', 620, 800),
        word('you', 820, 1000, '?')
      ],
      timingSource: 'wordTimeline'
    },
    {
      sequence: 2,
      startMS: 3000,
      endMS: 3500,
      text: 'Legacy sentence without words',
      learningText: 'Legacy sentence without words',
      translation: '',
      speaker: 'guest',
      notes: '',
      words: [],
      timingSource: 'legacy'
    }
  ];
  const resegmented = resegmentLearningSegments(asr, profile);
  assert.equal(resegmented.length, 3);
  assert.equal(resegmented[0].text, 'Hello.');
  assert.equal(resegmented[1].text, 'How are you?');
  assert.equal(resegmented[2].text, 'Legacy sentence without words');
  assert.equal(resegmented[2].speaker, 'guest');
  assert.equal(resegmented[0].speaker, 'host');
  assert.equal(resegmented[1].speaker, 'host');
  assert.ok(resegmented.every((s) => s.translation === ''));
  assert.deepEqual(resegmented.map((s) => s.sequence), [1, 2, 3]);
});

test('resegment returns the identical list when no split is needed', () => {
  const words = [word('Short', 0, 200), word('one', 220, 400, '.')];
  const original: LearningSegment[] = [
    {
      sequence: 1,
      startMS: 0,
      endMS: 400,
      text: 'Short one.',
      learningText: 'Short one.',
      translation: '',
      notes: '',
      words,
      timingSource: 'wordTimeline'
    }
  ];
  assert.deepEqual(resegmentLearningSegments(original, profile), original);
});

test('display binary split pieces concatenate back to the original text', () => {
  const words = [
    word('This', 0, 300),
    word('overflowing', 320, 800),
    word('display', 820, 1200),
    word('line', 1220, 1600),
    word('continues', 1620, 2200),
    word('further', 2220, 2800, '.')
  ];
  const cut = bestBinarySplit(words, profile);
  assert.ok(cut !== null && cut > 0 && cut < words.length);
  const left = renderText(words.slice(0, cut));
  const right = renderText(words.slice(cut));
  assert.notEqual(left, '');
  assert.notEqual(right, '');
  assert.equal(`${left} ${right}`, renderText(words));
});

test('weighted length matches the CJK/full-width weighting rules', () => {
  assert.equal(weightedLength('abc'), 3);
  assert.equal(weightedLength('你好'), 3.5);
  assert.equal(weightedLength('あ'), 1.75);
  assert.equal(weightedLength('한'), 1.5);
  assert.equal(weightedLength('สวัสดี'), 6); // Thai (6 scalars) stays at default weight
  assert.equal(weightedLength('！'), 1.75); // full-width punctuation
});
