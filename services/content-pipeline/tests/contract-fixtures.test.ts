import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { validate, type SchemaNode } from './support/json-schema-lite.js';

const FIXTURES = new URL('../fixtures/contract/', import.meta.url);
const CONTRACTS = new URL('../../../docs/contracts/', import.meta.url);

function loadJson(url: URL): unknown {
  return JSON.parse(readFileSync(url, 'utf8'));
}

const wireSchema = loadJson(new URL('content-job-v1.wire.schema.json', CONTRACTS)) as SchemaNode;
const manifestSchema = loadJson(new URL('content-artifact-v1.schema.json', CONTRACTS)) as SchemaNode;

function fixture(name: string): unknown {
  return loadJson(new URL(name, FIXTURES));
}

function expectValid(schema: SchemaNode, def: string, value: unknown, label: string): void {
  const errors = validate({ $ref: `#/definitions/${def}`, definitions: schema.definitions }, value);
  assert.deepEqual(errors, [], `${label} must validate against ${def}:\n${errors.join('\n')}`);
}

const JOB_FIXTURES = [
  'job-queued.json',
  'job-running-fetching-audio.json',
  'job-running-transcribing.json',
  'job-running-translating.json',
  'job-ready-podcast.json',
  'job-ready-video.json',
  'job-ready-partial-optional-artifact.json',
  'job-failed-retryable.json',
  'job-failed-non-retryable.json',
  'job-cancelled.json',
  'job-expired.json',
  'job-unknown-field.json',
  'job-unknown-enum.json',
  'job-schema-too-new.json'
];

test('all job fixtures validate against ContentJobResponse', () => {
  for (const name of JOB_FIXTURES) {
    expectValid(wireSchema, 'ContentJobResponse', fixture(name), name);
  }
});

test('create request fixtures validate', () => {
  expectValid(wireSchema, 'ContentJobCreateRequest', fixture('create-request-podcast.json'), 'podcast create');
  expectValid(wireSchema, 'ContentJobCreateRequest', fixture('create-request-video.json'), 'video create');
});

test('lookup fixtures validate', () => {
  expectValid(wireSchema, 'ContentJobLookupResponse', fixture('lookup-response-hit.json'), 'lookup hit');
  expectValid(wireSchema, 'ContentJobLookupResponse', fixture('lookup-response-miss.json'), 'lookup miss');
});

test('audio playback url fixture validates', () => {
  expectValid(wireSchema, 'AudioPlaybackUrlResponse', fixture('audio-playback-url-response.json'), 'audio playback url');
});

test('video playback url request and ready response validate', () => {
  expectValid(
    wireSchema,
    'VideoPlaybackUrlRequest',
    fixture('video-playback-url-request.json'),
    'video playback url request'
  );
  expectValid(
    wireSchema,
    'VideoPlaybackUrlResponse',
    fixture('video-playback-url-response.json'),
    'video playback url response'
  );
});

test('video playback url unknown optional fields remain valid', () => {
  const unknown = fixture('video-playback-url-unknown-field.json') as Record<string, unknown>;
  expectValid(wireSchema, 'VideoPlaybackUrlResponse', unknown, 'video playback url unknown field');
  assert.equal(unknown.futureOptionalHint, 'clients must ignore unknown optional fields');
});

test('content media error envelopes validate', () => {
  expectValid(wireSchema, 'ErrorEnvelope', fixture('error-envelope-media-not-found.json'), 'media not found');
  expectValid(wireSchema, 'ErrorEnvelope', fixture('error-envelope-media-not-ready.json'), 'media not ready');
  expectValid(
    wireSchema,
    'ErrorEnvelope',
    fixture('error-envelope-media-integrity-failed.json'),
    'media integrity failed'
  );
});

test('error envelope fixture validates', () => {
  expectValid(wireSchema, 'ErrorEnvelope', fixture('error-envelope-invalid-request.json'), 'error envelope');
});

test('artifact manifest fixtures validate against content-artifact-v1 schema', () => {
  for (const name of ['artifact-manifest-podcast.json', 'artifact-manifest-video.json']) {
    const errors = validate(manifestSchema, fixture(name));
    assert.deepEqual(errors, [], `${name} must validate:\n${errors.join('\n')}`);
  }
});

test('artifact-manifest-video.json remains byte-identical for schema v1', () => {
  const bytes = readFileSync(new URL('artifact-manifest-video.json', FIXTURES));
  assert.equal(
    createHash('sha256').update(bytes).digest('hex'),
    'd95b2562d39956130cef821b0b2e926af737ba7122ec035475ea7c55eb1e6c7a'
  );
});

test('fixtures cover the required golden scenarios', () => {
  const required = new Set([
    'job-queued.json',
    'job-ready-podcast.json',
    'job-ready-video.json',
    'job-ready-partial-optional-artifact.json',
    'job-failed-retryable.json',
    'job-failed-non-retryable.json',
    'job-cancelled.json',
    'job-expired.json',
    'job-unknown-field.json',
    'job-unknown-enum.json',
    'job-schema-too-new.json'
  ]);
  for (const name of required) {
    assert.ok(JOB_FIXTURES.includes(name), `missing golden fixture ${name}`);
  }
  assert.ok(JOB_FIXTURES.length >= 12, 'at least 12 job-state fixtures required');
});

test('ready fixture requires all required files ready', () => {
  const ready = fixture('job-ready-podcast.json') as {
    artifacts: { files: Array<{ required: boolean; status: string }> };
  };
  for (const file of ready.artifacts.files) {
    if (file.required) assert.equal(file.status, 'ready', 'required artifact must be ready');
  }
});

test('learning segments fixture matches Swift LearningSegment wire layout', () => {
  const doc = fixture('learning-segments-bilingual.json') as {
    segments: Array<Record<string, unknown>>;
  };
  const allowedKeys = new Set([
    'sequence',
    'startMS',
    'endMS',
    'text',
    'learningText',
    'translation',
    'speaker',
    'notes',
    'words',
    'playbackSentence',
    'timingSource'
  ]);
  for (const segment of doc.segments) {
    for (const key of Object.keys(segment)) {
      assert.ok(allowedKeys.has(key), `unexpected LearningSegment key ${key}`);
    }
    assert.ok(Number.isInteger(segment.sequence));
    assert.ok(Number.isInteger(segment.startMS));
    assert.ok(Number.isInteger(segment.endMS));
    assert.equal(typeof segment.text, 'string');
    assert.equal(typeof segment.learningText, 'string');
    assert.equal(typeof segment.translation, 'string');
  }
  const timingSources = new Set(doc.segments.map((s) => s.timingSource));
  assert.ok(timingSources.has('wordTimeline'));
});
