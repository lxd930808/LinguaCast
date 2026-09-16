import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { V1_CONTRACT_SHA256, sha256File } from '../evaluation/v15-baseline-replay.js';
import { validate, type SchemaNode } from './support/json-schema-lite.js';

const FIXTURES = new URL('../fixtures/v2-contract/', import.meta.url);
const IOS_FIXTURES = new URL(
  '../../../ios/PodcastEnglishStudio/PodcastEnglishStudioTests/Fixtures/AssistantV2/',
  import.meta.url
);
const CONTRACTS = new URL('../../../docs/contracts/', import.meta.url);

const PATH_KEYS = ['path', 'relativePath', 'uri', 'fileName', 'filename', 'realPath', 'absolutePath'];

const EXPECTED_V2_PATHS = [
  '/v2/assistant/researches',
  '/v2/assistant/researches/{researchId}',
  '/v2/assistant/researches/{researchId}/turns',
  '/v2/assistant/turns/{turnId}/events',
  '/v2/assistant/turns/{turnId}/cancel',
  '/v2/assistant/researches/{researchId}/artifacts',
  '/v2/assistant/researches/{researchId}/artifacts/{artifactId}',
  '/v2/assistant/researches/{researchId}/sources/{sourceId}/transcription',
  '/v2/assistant/researches/{researchId}/transcriptions/{transcriptJobId}',
  '/v2/assistant/researches/{researchId}/memory',
  '/v2/assistant/memory-proposals/{proposalId}/confirm',
  '/v2/assistant/memory-proposals/{proposalId}/reject'
];

function loadJson(url: URL): unknown {
  return JSON.parse(readFileSync(url, 'utf8'));
}

const wireSchema = loadJson(new URL('assistant-v2.wire.schema.json', CONTRACTS)) as SchemaNode;
const manifestSchema = loadJson(
  new URL('assistant-workspace-manifest-v1.schema.json', CONTRACTS)
) as SchemaNode;

function fixture(name: string): unknown {
  return loadJson(new URL(name, FIXTURES));
}

function expectValid(def: string, value: unknown, label: string): void {
  const errors = validate({ $ref: `#/definitions/${def}`, definitions: wireSchema.definitions }, value);
  assert.deepEqual(errors, [], `${label} must validate against ${def}:\n${errors.join('\n')}`);
}

function collectObjects(value: unknown, found: Record<string, unknown>[] = []): Record<string, unknown>[] {
  if (Array.isArray(value)) {
    for (const item of value) collectObjects(item, found);
  } else if (value && typeof value === 'object') {
    found.push(value as Record<string, unknown>);
    for (const nested of Object.values(value)) collectObjects(nested, found);
  }
  return found;
}

test('V1 contracts are unchanged after freezing V2', () => {
  for (const [name, expected] of Object.entries(V1_CONTRACT_SHA256)) {
    assert.equal(sha256File(fileURLToPath(new URL(name, CONTRACTS))), expected, name);
  }
});

test('OpenAPI lists the frozen V2 routes and no artifact path parameters', () => {
  const openapi = readFileSync(new URL('assistant-v2.openapi.yaml', CONTRACTS), 'utf8');
  for (const path of EXPECTED_V2_PATHS) {
    assert.match(openapi, new RegExp(`^  ${path.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}:`, 'm'), path);
  }
  assert.doesNotMatch(openapi, /^\s+- name: path$/m);
  assert.doesNotMatch(openapi, /in: query\n\s+schema:\n\s+type: string\n\s+description:.*path/s);
  assert.match(openapi, /GrepFilesRequest/);
  assert.match(openapi, /GrepFilesResult/);
});

test('research, turn, and snapshot fixtures validate', () => {
  expectValid('ResearchCreateRequest', fixture('research-create-request.json'), 'create request');
  expectValid('Research', fixture('research-created.json'), 'created');
  expectValid('ResearchListResponse', fixture('research-list.json'), 'list');
  expectValid('ResearchSnapshot', fixture('research-snapshot-happy.json'), 'happy snapshot');
  expectValid('ResearchSnapshot', fixture('research-snapshot-partial.json'), 'partial snapshot');
  expectValid('TurnCreateRequest', fixture('turn-create-research.json'), 'turn create');
  expectValid('TurnAcceptedResponse', fixture('turn-accepted-research.json'), 'turn accepted');
});

test('artifact, memory, transcript, and grep fixtures validate', () => {
  expectValid('ArtifactListResponse', fixture('artifact-list.json'), 'artifact list');
  expectValid('ArtifactBody', fixture('artifact-body-web-page.json'), 'artifact body');
  expectValid('WorkspaceArtifact', fixture('artifact-corrupt.json'), 'corrupt artifact');
  expectValid('WorkspaceGrant', fixture('workspace-grant.json'), 'grant');
  expectValid('MemorySnapshot', fixture('memory-snapshot.json'), 'memory');
  expectValid('MemoryEntry', fixture('memory-proposal-confirmed.json'), 'confirmed preference');
  expectValid('TranscriptionCreateRequest', fixture('transcription-create-request.json'), 'confirm transcription');
  expectValid('TranscriptJob', fixture('transcript-job-ready.json'), 'transcript job');
  expectValid('EvidenceCitation', fixture('citation-transcript.json'), 'citation');
  expectValid('GrepFilesRequest', fixture('grep-files-request.json'), 'grep request');
  expectValid('GrepFilesResult', fixture('grep-files-result.json'), 'grep result');
});

test('error and sse fixtures validate', () => {
  for (const name of [
    'error-envelope-unauthorized.json',
    'error-envelope-idempotency-conflict.json',
    'error-envelope-event-cursor-expired.json',
    'error-envelope-workspace-path-unsafe.json',
    'error-envelope-grant-denied.json',
    'error-envelope-artifact-corrupt.json',
    'error-envelope-legacy-session-read-only.json'
  ]) {
    expectValid('ErrorEnvelope', fixture(name), name);
  }
  for (const name of ['sse-replay-events.json', 'sse-partial-web-failed.json', 'sse-turn-work-events.json']) {
    const wrapped = fixture(name) as { events: Array<{ data: unknown }> };
    for (const event of wrapped.events) {
      expectValid('SseEventData', event.data, name);
    }
  }
});

test('turn work fixture validates against the snapshot turnWork schema', () => {
  const snapshot = fixture('research-snapshot-happy.json') as { turnWork: unknown };
  assert.ok(Array.isArray(snapshot.turnWork) && snapshot.turnWork.length > 0);
  for (const work of snapshot.turnWork) {
    expectValid('TurnWork', work, 'turnWork entry');
  }
});

test('workspace manifests validate against the on-disk schema', () => {
  for (const name of ['workspace-manifest-initial.json', 'workspace-manifest-with-artifacts.json']) {
    const errors = validate(manifestSchema, fixture(name));
    assert.deepEqual(errors, [], `${name}:\n${errors.join('\n')}`);
  }
});

test('REST artifact fixtures never include path fields', () => {
  const names = [
    'research-snapshot-happy.json',
    'artifact-list.json',
    'artifact-body-web-page.json',
    'artifact-corrupt.json'
  ];
  for (const name of names) {
    for (const obj of collectObjects(fixture(name))) {
      if (!('artifactId' in obj && 'sha256' in obj && 'kind' in obj)) continue;
      for (const key of PATH_KEYS) {
        assert.equal(obj[key], undefined, `${name} artifact must not expose ${key}`);
      }
    }
  }
});

test('server and iOS V2 fixtures are byte-identical', () => {
  const serverDir = fileURLToPath(FIXTURES);
  const iosDir = fileURLToPath(IOS_FIXTURES);
  const names = readdirSync(serverDir).filter((name) => name.endsWith('.json')).sort();
  const iosNames = readdirSync(iosDir).filter((name) => name.endsWith('.json')).sort();
  assert.deepEqual(iosNames, names);
  for (const name of names) {
    const left = createHash('sha256').update(readFileSync(join(serverDir, name))).digest('hex');
    const right = createHash('sha256').update(readFileSync(join(iosDir, name))).digest('hex');
    assert.equal(left, right, name);
  }
});
