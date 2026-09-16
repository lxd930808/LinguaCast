import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import {
  V1_CONTRACT_SHA256,
  loadInventory,
  loadSnapshot,
  sha256File,
  snapshotFiles,
  sseSnapshotNames,
  wireDefinitionForSnapshot
} from '../../evaluation/v15-baseline-replay.js';
import { validate, type SchemaNode } from '../support/json-schema-lite.js';

const CONTRACTS = new URL('../../../../docs/contracts/', import.meta.url);
const wireSchema = JSON.parse(
  readFileSync(new URL('assistant-v1.wire.schema.json', CONTRACTS), 'utf8')
) as SchemaNode;

function expectValid(def: string, value: unknown, label: string): void {
  const errors = validate({ $ref: `#/definitions/${def}`, definitions: wireSchema.definitions }, value);
  assert.deepEqual(errors, [], `${label} must validate against ${def}:\n${errors.join('\n')}`);
}

test('V15 baseline inventory is offline and matches snapshot hashes', () => {
  const inventory = loadInventory();
  assert.equal(inventory.schemaVersion, 1);
  assert.equal(inventory.networkRequired, false);
  assert.equal(inventory.gitCommit, '75ab9725fac556bbc4be202f7c5d2a96ad927008');
  const names = snapshotFiles();
  assert.ok(names.length >= 13, 'expected frozen V1 snapshots');
  for (const entry of inventory.files) {
    const path = fileURLToPath(new URL(`../../evaluation/v15-baseline/snapshots/${entry.file}`, import.meta.url));
    assert.equal(sha256File(path), entry.sha256, entry.file);
    assert.equal(readFileSync(path).byteLength, entry.bytes, entry.file);
  }
});

test('V1 contract files remain at the Gate 0 SHA-256 freeze', () => {
  for (const [name, expected] of Object.entries(V1_CONTRACT_SHA256)) {
    assert.equal(sha256File(fileURLToPath(new URL(name, CONTRACTS))), expected, name);
  }
});

test('frozen V1 snapshots replay against the v1 wire schema', () => {
  for (const name of snapshotFiles()) {
    const def = wireDefinitionForSnapshot(name);
    if (!def) continue;
    expectValid(def, loadSnapshot(name), name);
  }
  for (const name of sseSnapshotNames()) {
    const wrapped = loadSnapshot(name) as { events: Array<{ data: unknown }> };
    for (const event of wrapped.events) {
      expectValid('SseEventData', event.data, `${name} event`);
    }
  }
  const transcript = loadSnapshot('learning-segments-bilingual.json') as { segments?: unknown };
  assert.ok(transcript && typeof transcript === 'object');
});
