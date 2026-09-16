import assert from 'node:assert/strict';
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  writeFileSync
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { openDatabase } from '../../src/db/migrations.js';
import { V2Store } from '../../src/db/v2/store.js';
import { nowIso } from '../../src/domain/ids.js';
import { DomainError } from '../../src/domain/types.js';
import { newResearchId } from '../../src/research-v2/state.js';
import {
  DIR_MODE,
  FILE_MODE,
  WORKSPACE_SUBDIRS,
  buildInitialManifest,
  createLayout,
  encodeManifest,
  hasCompleteLayout,
  officialPath,
  readManifestFile,
  tempPath
} from '../../src/workspace/layout.js';
import {
  DEFAULT_HARD_FREE_BYTES,
  WorkspaceManager,
  type CreateWorkspaceInput
} from '../../src/workspace/manager.js';

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), '../../migrations');

function openHarness(diskFreeBytes = 8 * 1024 * 1024 * 1024) {
  const dir = mkdtempSync(join(tmpdir(), 'ws-manager-'));
  const db = openDatabase(join(dir, 'a.db'), MIGRATIONS);
  const store = new V2Store(db);
  const root = join(dir, 'workspaces');
  mkdirSync(root, { recursive: true });
  const manager = new WorkspaceManager({
    root,
    store,
    diskFreeBytes: () => diskFreeBytes,
    quota: { maxResearchBytes: 1024 }
  });
  return { dir, store, manager, root, close: () => store.close() };
}

function input(overrides: Partial<CreateWorkspaceInput> = {}): CreateWorkspaceInput {
  return {
    ownerScope: 'selfhost',
    title: 'AI and ../accounting/报告',
    outputLanguage: 'zh-Hans',
    storefront: 'US',
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    ...overrides
  };
}

function seedCreating(store: V2Store, researchId: string): void {
  const now = nowIso();
  store.createResearch(
    {
      researchId,
      ownerScope: 'selfhost',
      title: 'interrupted',
      status: 'creating',
      workspaceStatus: 'pending',
      outputLanguage: 'zh-Hans',
      storefront: 'US',
      targetLanguage: 'zh-Hans',
      translationQuality: 'quality',
      activeTurnId: null,
      createdAt: now,
      updatedAt: now,
      deletedAt: null
    },
    {
      researchId,
      directoryId: researchId,
      manifestVersion: 1,
      manifestSha256: null,
      integrityStatus: 'pending',
      lastRecoveredAt: null,
      createdAt: now,
      updatedAt: now
    }
  );
}

function isDomain(code: string) {
  return (error: unknown) => error instanceof DomainError && error.code === code;
}

function modeOf(path: string): number {
  return lstatSync(path).mode & 0o777;
}

test('create commits directory, permissions, and initial manifest before returning', () => {
  const { manager, root, store, close } = openHarness();
  const handle = manager.create(input());
  const dest = officialPath(root, handle.researchId);
  assert.equal(existsSync(dest), true);
  assert.equal(existsSync(tempPath(root, handle.researchId)), false);
  assert.equal(hasCompleteLayout(dest), true);
  assert.equal(handle.status, 'ready');
  const manifest = readManifestFile(dest);
  assert.equal(manifest.researchId, handle.researchId);
  assert.deepEqual(manifest.artifacts, []);
  assert.equal(store.getResearch(handle.researchId)?.status, 'ready');
  assert.ok(store.getWorkspace(handle.researchId)?.manifestSha256);
  assert.equal(modeOf(dest), DIR_MODE);
  assert.equal(modeOf(join(dest, 'manifest.json')), FILE_MODE);
  for (const relative of WORKSPACE_SUBDIRS) {
    assert.equal(modeOf(join(dest, relative)), DIR_MODE);
  }
  const names = readdirSync(root);
  assert.deepEqual(names, [handle.researchId]);
  assert.equal(names.some((name) => name.includes('accounting') || name.includes('报告')), false);
  close();
});

test('retrying the same researchId does not create a second directory', () => {
  const { manager, root, close } = openHarness();
  const researchId = newResearchId();
  const first = manager.create(input({ researchId }));
  const second = manager.create(input({ researchId, title: 'other title' }));
  assert.equal(first.researchId, second.researchId);
  assert.deepEqual(readdirSync(root), [researchId]);
  assert.equal(existsSync(tempPath(root, researchId)), false);
  close();
});

test('hard watermark blocks new research while reads and deletes stay available', () => {
  const { manager, store, root, close } = openHarness();
  const handle = manager.create(input());
  const full = new WorkspaceManager({
    root,
    store,
    diskFreeBytes: () => DEFAULT_HARD_FREE_BYTES - 1
  });
  assert.throws(() => full.create(input()), isDomain('STORAGE_FULL'));
  assert.equal(full.open(handle.researchId).status, 'ready');
  full.delete(handle.researchId);
  assert.equal(store.getResearch(handle.researchId, true)?.status, 'deleted');
  close();
});

test('soft watermark and per-research quota are enforced', () => {
  const { manager, store, root, close } = openHarness();
  const handle = manager.create(input());
  const paused = new WorkspaceManager({
    root,
    store,
    diskFreeBytes: () => 512 * 1024 * 1024
  });
  assert.throws(() => paused.assertCanWriteLarge(), isDomain('WORKSPACE_QUOTA_EXCEEDED'));
  writeFileSync(join(officialPath(root, handle.researchId), 'reports', 'big.bin'), Buffer.alloc(2048));
  assert.throws(() => manager.stats(handle.researchId), isDomain('WORKSPACE_QUOTA_EXCEEDED'));
  const measured = new WorkspaceManager({
    root,
    store,
    quota: { maxResearchBytes: 10 * 1024 },
    diskFreeBytes: () => 8 * 1024 * 1024 * 1024
  }).stats(handle.researchId);
  assert.equal(measured.researchId, handle.researchId);
  assert.ok(measured.bytes >= 2048);
  close();
});

test('delete tombstones first, refuses reads, then converges on retry', () => {
  const { manager, store, root, close } = openHarness();
  const handle = manager.create(input());
  manager.delete(handle.researchId);
  assert.equal(existsSync(officialPath(root, handle.researchId)), false);
  assert.equal(store.getResearch(handle.researchId), null);
  assert.equal(store.getResearch(handle.researchId, true)?.status, 'deleted');
  assert.throws(() => manager.open(handle.researchId), isDomain('RESEARCH_NOT_FOUND'));
  manager.delete(handle.researchId);
  assert.equal(store.getResearch(handle.researchId, true)?.status, 'deleted');
  close();
});

test('reconcile recovers a complete staging directory after a create crash', () => {
  const { manager, store, root, close } = openHarness();
  const researchId = newResearchId();
  seedCreating(store, researchId);
  const staging = tempPath(root, researchId);
  createLayout(staging);
  writeFileSync(join(staging, 'manifest.json'), encodeManifest(buildInitialManifest(researchId, nowIso())), {
    mode: FILE_MODE
  });
  const report = manager.reconcile();
  assert.deepEqual(report.recovered, [researchId]);
  assert.equal(existsSync(staging), false);
  assert.equal(hasCompleteLayout(officialPath(root, researchId)), true);
  assert.equal(store.getResearch(researchId)?.status, 'ready');
  close();
});

test('reconcile finishes a renamed directory when SQLite is still creating', () => {
  const { manager, store, root, close } = openHarness();
  const handle = manager.create(input());
  store
    .getDb()
    .prepare(`UPDATE v2_researches SET status = 'creating', workspace_status = 'pending' WHERE research_id = ?`)
    .run(handle.researchId);
  const report = manager.reconcile();
  assert.ok(report.recovered.includes(handle.researchId));
  assert.equal(store.getResearch(handle.researchId)?.status, 'ready');
  assert.equal(hasCompleteLayout(officialPath(root, handle.researchId)), true);
  close();
});

test('reconcile purges deleting rows, orphans, and missing official directories', () => {
  const { manager, store, root, close } = openHarness();
  const live = manager.create(input());
  const deletingId = newResearchId();
  seedCreating(store, deletingId);
  store.setResearchStatus(deletingId, 'creating', 'failed');
  store.setResearchStatus(deletingId, 'failed', 'deleting');
  mkdirSync(officialPath(root, deletingId), { recursive: true });
  chmodSync(officialPath(root, deletingId), DIR_MODE);

  const orphanOfficial = newResearchId();
  mkdirSync(officialPath(root, orphanOfficial), { recursive: true });
  const orphanTemp = `.tmp-${newResearchId()}`;
  mkdirSync(join(root, orphanTemp), { recursive: true });

  rmSync(officialPath(root, live.researchId), { recursive: true, force: true });

  const report = manager.reconcile();
  assert.ok(report.purgedDeleting.includes(deletingId));
  assert.ok(report.orphanOfficialDirs.includes(orphanOfficial));
  assert.ok(report.orphanTempDirs.includes(orphanTemp));
  assert.ok(report.missingDirs.includes(live.researchId));
  assert.equal(store.getResearch(deletingId, true)?.status, 'deleted');
  assert.equal(existsSync(join(root, orphanTemp)), false);
  assert.equal(existsSync(officialPath(root, orphanOfficial)), true);
  assert.equal(store.getResearch(live.researchId)?.status, 'degraded');
  assert.throws(() => manager.open(deletingId), isDomain('RESEARCH_NOT_FOUND'));
  close();
});

test('incomplete official directory during create fails closed and can be retried by delete', () => {
  const { manager, store, root, close } = openHarness();
  const researchId = newResearchId();
  seedCreating(store, researchId);
  mkdirSync(officialPath(root, researchId), { recursive: true });
  chmodSync(officialPath(root, researchId), DIR_MODE);
  const report = manager.reconcile();
  assert.ok(report.failedCreates.includes(researchId));
  assert.equal(store.getResearch(researchId, true)?.status, 'failed');
  assert.equal(existsSync(officialPath(root, researchId)), false);
  manager.delete(researchId);
  assert.equal(store.getResearch(researchId, true)?.status, 'deleted');
  close();
});

test('open rejects creating and unsafe directory identities', () => {
  const { manager, store, close } = openHarness();
  const researchId = newResearchId();
  seedCreating(store, researchId);
  assert.throws(() => manager.open(researchId), isDomain('WORKSPACE_NOT_READY'));
  assert.throws(() => manager.open('not-a-ulid'), isDomain('WORKSPACE_PATH_UNSAFE'));
  close();
});
