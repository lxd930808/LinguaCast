import assert from 'node:assert/strict';
import { existsSync, lstatSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { DomainError } from '../../src/domain/types.js';
import {
  assertResearchId,
  buildInitialManifest,
  createLayout,
  DIR_MODE,
  encodeManifest,
  FILE_MODE,
  hasCompleteLayout,
  isOfficialDirName,
  isTempDirName,
  officialPath,
  parseManifest,
  RESEARCH_ID_PATTERN,
  tempDirName,
  tempPath,
  WORKSPACE_SUBDIRS
} from '../../src/workspace/layout.js';

const RESEARCH_ID = '01ARZ3NDEKTSV4RRFFQ69G5FAV';

test('research directory names are ULID identities and ignore titles', () => {
  assert.equal(RESEARCH_ID_PATTERN.test(RESEARCH_ID), true);
  assert.equal(isOfficialDirName(RESEARCH_ID), true);
  assert.equal(isOfficialDirName('AI and accounting'), false);
  assert.equal(isTempDirName(`.tmp-${RESEARCH_ID}`), true);
  assert.equal(tempDirName(RESEARCH_ID), `.tmp-${RESEARCH_ID}`);
  const root = '/workspaces';
  assert.equal(officialPath(root, RESEARCH_ID), join(root, RESEARCH_ID));
  assert.equal(tempPath(root, RESEARCH_ID), join(root, `.tmp-${RESEARCH_ID}`));
  assert.doesNotMatch(officialPath(root, RESEARCH_ID), /accounting|title|\.\./);
  assert.throws(() => assertResearchId('../etc'), (error: unknown) => {
    return error instanceof DomainError && error.code === 'WORKSPACE_PATH_UNSAFE';
  });
});

test('createLayout writes the frozen subtree and initial manifest is complete', () => {
  const root = mkdtempSync(join(tmpdir(), 'ws-layout-'));
  const dir = join(root, RESEARCH_ID);
  createLayout(dir);
  assert.equal(hasCompleteLayout(dir), false);
  const manifest = buildInitialManifest(RESEARCH_ID, '2026-09-03T01:00:00Z');
  writeFileSync(join(dir, 'manifest.json'), encodeManifest(manifest), { mode: FILE_MODE });
  assert.equal(hasCompleteLayout(dir), true);
  for (const relative of WORKSPACE_SUBDIRS) {
    const path = join(dir, relative);
    assert.equal(existsSync(path), true, relative);
    assert.equal(lstatSync(path).isDirectory(), true);
  }
  const parsed = parseManifest(encodeManifest(manifest));
  assert.equal(parsed.schemaVersion, 1);
  assert.equal(parsed.researchId, RESEARCH_ID);
  assert.deepEqual(parsed.artifacts, []);
  assert.equal(DIR_MODE, 0o750);
  assert.equal(FILE_MODE, 0o640);
});
