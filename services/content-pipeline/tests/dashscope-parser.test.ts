import assert from 'node:assert/strict';
import { test } from 'node:test';

import { extractSegments } from '../src/providers/asr/dashscope-parser.js';

// DashScope result parser tests (WP5). Payloads mirror real Paraformer
// recorded-transcription shapes plus the legacy fallback path.

const WORD_PAYLOAD = {
  transcripts: [
    {
      sentences: [
        {
          begin_time: 100,
          end_time: 1400,
          text: 'Hello world.',
          speaker: '0',
          words: [
            { text: 'Hello', begin_time: 100, end_time: 400 },
            { text: 'world', begin_time: 420, end_time: 900, punctuation: '.' }
          ]
        },
        {
          begin_time: 2000,
          end_time: 3100,
          text: 'How are you?',
          speaker_id: '1',
          words: [
            { word: 'How', begin_time: 2000, end_time: 2300 },
            { word: 'are', begin_time: 2320, end_time: 2600 },
            { word: 'you', begin_time: 2620, end_time: 3000, punctuation: '?' }
          ]
        }
      ]
    }
  ]
};

test('preferred path expands words with punctuation and wordTimeline', () => {
  const segments = extractSegments(WORD_PAYLOAD);
  assert.equal(segments.length, 2);
  assert.deepEqual(
    segments.map((s) => [s.sequence, s.startMS, s.endMS, s.text, s.timingSource]),
    [
      [1, 100, 1400, 'Hello world.', 'wordTimeline'],
      [2, 2000, 3100, 'How are you?', 'wordTimeline']
    ]
  );
  assert.equal(segments[0].speaker, '0');
  assert.equal(segments[1].speaker, '1');
  assert.deepEqual(segments[0].words, [
    { text: 'Hello', startMS: 100, endMS: 400 },
    { text: 'world', startMS: 420, endMS: 900, punctuation: '.' }
  ]);
  assert.deepEqual(segments[1].words.map((w) => w.text), ['How', 'are', 'you']);
  assert.equal(segments[1].words[2].punctuation, '?');
});

test('sentences nested one level deeper under results are found', () => {
  const payload = { results: [WORD_PAYLOAD] };
  const segments = extractSegments(payload);
  assert.equal(segments.length, 2);
  assert.equal(segments[0].timingSource, 'wordTimeline');
});

test('sentences without words keep legacy timing', () => {
  const payload = {
    transcripts: [
      {
        sentences: [
          { begin_time: 0, end_time: 1500, text: 'No word stream here.' }
        ]
      }
    ]
  };
  const segments = extractSegments(payload);
  assert.equal(segments.length, 1);
  assert.equal(segments[0].timingSource, 'legacy');
  assert.deepEqual(segments[0].words, []);
  assert.equal(segments[0].text, 'No word stream here.');
});

test('legacy fallback scans for the largest sentence-like array', () => {
  const payload = {
    something: {
      segments: [
        { text: 'First chunk', start_time: 0, end_time: 900 },
        { text: 'Second chunk', start_time: 1000, end_time: 1800, speaker: 'host' }
      ]
    }
  };
  const segments = extractSegments(payload);
  assert.equal(segments.length, 2);
  assert.equal(segments[0].timingSource, 'legacy');
  assert.equal(segments[1].speaker, 'host');
});

test('empty payloads produce no segments (the stage reports empty recognition)', () => {
  assert.deepEqual(extractSegments({}), []);
  assert.deepEqual(extractSegments({ transcripts: [] }), []);
  assert.deepEqual(extractSegments('nonsense'), []);
  assert.deepEqual(extractSegments(null), []);
});

test('numeric fields as strings and end clamping match the Swift side', () => {
  const payload = {
    transcripts: [
      {
        sentences: [
          {
            begin_time: '500',
            end_time: '499', // regresses → clamped to start+1
            text: '  Padded text  ',
            words: [
              { text: 'Padded', begin_time: '500', end_time: '480' },
              { text: 'text', begin_time: 500, end_time: 900, punctuation: '  ' }
            ]
          }
        ]
      }
    ]
  };
  const segments = extractSegments(payload);
  assert.equal(segments.length, 1);
  assert.equal(segments[0].startMS, 500);
  assert.equal(segments[0].endMS, 501);
  assert.equal(segments[0].text, 'Padded text');
  // Blank punctuation is dropped like Swift's isEmpty check.
  assert.equal(segments[0].words[1].punctuation, undefined);
  assert.equal(segments[0].words[0].endMS, 501);
});
