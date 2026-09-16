import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { ArtifactWriter, MAX_ARTIFACT_BYTES } from '../../src/artifacts/writer.js';
import { decodeManifest, encodeManifest, readManifest, sha256Bytes } from '../../src/artifacts/manifest.js';
import { openDatabase } from '../../src/db/migrations.js';
import { V2Store } from '../../src/db/v2/store.js';
import { nowIso } from '../../src/domain/ids.js';
import { DomainError } from '../../src/domain/types.js';
import { newArtifactId, newOperationId } from '../../src/research-v2/state.js';
import { WorkspaceManager } from '../../src/workspace/manager.js';

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), '../../migrations');

function harness() {
  const dir = mkdtempSync(join(tmpdir(), 'artifacts-'));
  const db = openDatabase(join(dir, 'a.db'), MIGRATIONS);
  const store = new V2Store(db);
  const workspaceRoot = join(dir, 'workspaces');
  mkdirSync(workspaceRoot);
  const manager = new WorkspaceManager({
    root: workspaceRoot,
    store,
    diskFreeBytes: () => 8 * 1024 * 1024 * 1024
  });
  const research = manager.create({
    ownerScope: 'selfhost',
    title: 'artifacts',
    outputLanguage: 'zh-Hans',
    storefront: 'US',
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality'
  });
  const writer = new ArtifactWriter(store, research.researchId, manager.internalPath(research.researchId));
  return { dir, store, manager, research, writer, workspace: manager.internalPath(research.researchId), close: () => store.close() };
}

test('manifest encode is stably sorted and round-trips', () => {
  const encoded = encodeManifest({
    schemaVersion: 1,
    researchId: '01ARZ3NDEKTSV4RRFFQ69G5FAV',
    createdAt: '2026-09-03T01:00:00Z',
    updatedAt: '2026-09-03T01:08:00Z',
    artifacts: [
      {
        artifactId: '01ARZ3NDEKTSV4RRFFQ69G5FD1',
        kind: 'report',
        status: 'ready',
        relativePath: 'reports/01ARZ3NDEKTSV4RRFFQ69G5FD1.md',
        mediaType: 'text/markdown',
        bytes: 2,
        sha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        createdAt: '2026-09-03T01:09:00Z',
        producer: 'report-writing',
        sourceURL: null,
        contentKey: null,
        evidenceLevel: 'research_note'
      },
      {
        artifactId: '01ARZ3NDEKTSV4RRFFQ69G5FD0',
        kind: 'web_page',
        status: 'ready',
        relativePath: 'sources/web/pages/01ARZ3NDEKTSV4RRFFQ69G5FD0.md',
        mediaType: 'text/markdown',
        bytes: 1,
        sha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        createdAt: '2026-09-03T01:08:00Z',
        producer: 'fetch_web_page',
        sourceURL: 'https://example.com/ai-accounting',
        contentKey: null,
        evidenceLevel: 'primary_content'
      }
    ]
  });
  const decoded = decodeManifest(encoded);
  assert.equal(decoded.artifacts[0]?.artifactId, '01ARZ3NDEKTSV4RRFFQ69G5FD0');
  assert.equal(decoded.artifacts[1]?.artifactId, '01ARZ3NDEKTSV4RRFFQ69G5FD1');
});

test('save then get keeps bytes and sha256 aligned with the file', () => {
  const { writer, workspace, close } = harness();
  const saved = writer.save({
    kind: 'web_page',
    contents: 'Firms are piloting document review tools.\n',
    producer: 'fetch_web_page',
    evidenceLevel: 'primary_content',
    sourceURL: 'https://example.com/ai-accounting'
  });
  const body = writer.get(saved.artifactId);
  const file = readFileSync(join(workspace, saved.relativePath));
  assert.equal(body.sha256, sha256Bytes(file));
  assert.equal(body.bytes, file.length);
  assert.equal(saved.status, 'ready');
  assert.equal(body.text.includes('Firms'), true);
  const manifest = readManifest(workspace);
  assert.equal(manifest.artifacts.some((item) => item.artifactId === saved.artifactId && item.status === 'ready'), true);
  close();
});

test('memory overwrite keeps one live file plus version history', () => {
  const { writer, workspace, store, research, close } = harness();
  const first = writer.save({
    kind: 'research_memory',
    contents: 'first note',
    producer: 'memory',
    evidenceLevel: 'research_note'
  });
  const second = writer.save({
    kind: 'research_memory',
    contents: 'second note',
    producer: 'memory',
    evidenceLevel: 'research_note'
  });
  assert.equal(readFileSync(join(workspace, 'memory/research.md'), 'utf8'), 'second note');
  assert.equal(store.getArtifact(research.researchId, first.artifactId)?.status, 'superseded');
  assert.equal(store.getArtifact(research.researchId, second.artifactId)?.status, 'ready');
  const versions = readdirSync(join(workspace, '.versions', first.artifactId));
  assert.equal(versions.length, 1);
  close();
});

test('pending_file failpoint recovers to a single ready body and manifest', () => {
  const { writer, workspace, store, research, close } = harness();
  const artifactId = newArtifactId();
  const relativePath = `sources/web/pages/${artifactId}.md`;
  const contents = Buffer.from('recovered page\n');
  const digest = sha256Bytes(contents);
  const now = nowIso();
  store.insertArtifact({
    artifactId,
    researchId: research.researchId,
    kind: 'web_page',
    status: 'pending',
    relativePath,
    mediaType: 'text/markdown',
    bytes: contents.length,
    sha256: digest,
    producer: 'fetch_web_page',
    evidenceLevel: 'primary_content',
    sourceReference: null,
    createdAt: now,
    updatedAt: now
  });
  const tempName = `.tmp-artifact-${artifactId}`;
  writeFileSync(join(workspace, 'sources/web/pages', tempName), contents);
  store.insertOperation({
    operationId: newOperationId(),
    researchId: research.researchId,
    artifactId,
    tempName,
    targetRelativePath: relativePath,
    expectedSha256: digest,
    stage: 'pending_file',
    errorCode: null,
    createdAt: now,
    updatedAt: now
  });
  const report = writer.recover();
  assert.equal(report.completed.length, 1);
  assert.equal(store.getArtifact(research.researchId, artifactId)?.status, 'ready');
  assert.equal(existsSync(join(workspace, 'sources/web/pages', tempName)), false);
  assert.equal(readFileSync(join(workspace, relativePath), 'utf8'), 'recovered page\n');
  assert.equal(readManifest(workspace).artifacts.filter((item) => item.relativePath === relativePath).length, 1);
  close();
});

test('hash mismatch marks corrupt without deleting the file', () => {
  const { writer, workspace, store, research, close } = harness();
  const saved = writer.save({
    kind: 'report',
    contents: 'report body',
    producer: 'report-writing',
    evidenceLevel: 'research_note'
  });
  writeFileSync(join(workspace, saved.relativePath), 'tampered');
  assert.throws(
    () => writer.get(saved.artifactId),
    (error: unknown) => error instanceof DomainError && error.code === 'ARTIFACT_CORRUPT'
  );
  assert.equal(existsSync(join(workspace, saved.relativePath)), true);
  assert.equal(store.getArtifact(research.researchId, saved.artifactId)?.status, 'corrupt');
  close();
});

test('sqlite projections can be rebuilt from the manifest', () => {
  const { writer, store, research, close } = harness();
  const saved = writer.save({
    kind: 'report',
    contents: 'report body',
    producer: 'report-writing',
    evidenceLevel: 'research_note'
  });
  store.getDb().prepare('DELETE FROM v2_passages WHERE artifact_id = ?').run(saved.artifactId);
  store.getDb().prepare('DELETE FROM v2_artifacts WHERE artifact_id = ?').run(saved.artifactId);
  const restored = writer.rebuildFromManifest();
  assert.equal(restored, 1);
  assert.equal(store.getArtifact(research.researchId, saved.artifactId)?.status, 'ready');
  assert.equal(writer.get(saved.artifactId).text, 'report body');
  close();
});

test('corrupt manifest is not silently overwritten', () => {
  const { writer, workspace, close } = harness();
  writeFileSync(join(workspace, 'manifest.json'), '{not json');
  assert.throws(
    () =>
      writer.save({
        kind: 'report',
        contents: 'nope',
        producer: 'report-writing',
        evidenceLevel: 'research_note'
      }),
    (error: unknown) => error instanceof DomainError && error.code === 'WORKSPACE_CORRUPT'
  );
  assert.equal(readFileSync(join(workspace, 'manifest.json'), 'utf8'), '{not json');
  close();
});

test('long transcript artifacts above the former 2 MiB cap round-trip intact', () => {
  const { writer, close } = harness();
  const contents = 'Long podcast transcript.\n'.repeat(140_000);
  assert.ok(Buffer.byteLength(contents) > 2 * 1024 * 1024);
  const artifact = writer.save({
    kind: 'transcript', contents, producer: 'transcript-installer',
    evidenceLevel: 'transcript', mediaType: 'text/markdown', relativePath: 'transcripts/long.md'
  });
  assert.equal(writer.get(artifact.artifactId).text, contents);
  close();
});

test('artifact size cap rejects oversized bodies before commit', () => {
  const { writer, store, research, close } = harness();
  assert.throws(
    () =>
      writer.save({
        kind: 'report',
        contents: 'x'.repeat(MAX_ARTIFACT_BYTES + 1),
        producer: 'report-writing',
        evidenceLevel: 'research_note'
      }),
    (error: unknown) => error instanceof DomainError && error.code === 'ARTIFACT_WRITE_FAILED'
  );
  assert.equal(store.listArtifacts(research.researchId, 'report', 'ready').length, 0);
  close();
});

test('pending_manifest failpoint recovers without a second body', () => {
  const { writer, workspace, store, research, close } = harness();
  const artifactId = newArtifactId();
  const relativePath = `reports/${artifactId}.md`;
  const contents = Buffer.from('manifest pending recovery\n');
  const digest = sha256Bytes(contents);
  const now = nowIso();
  store.insertArtifact({
    artifactId,
    researchId: research.researchId,
    kind: 'report',
    status: 'pending',
    relativePath,
    mediaType: 'text/markdown',
    bytes: contents.length,
    sha256: digest,
    producer: 'report-writing',
    evidenceLevel: 'research_note',
    sourceReference: null,
    createdAt: now,
    updatedAt: now
  });
  writeFileSync(join(workspace, relativePath), contents);
  store.insertOperation({
    operationId: newOperationId(),
    researchId: research.researchId,
    artifactId,
    tempName: `.tmp-artifact-${artifactId}`,
    targetRelativePath: relativePath,
    expectedSha256: digest,
    stage: 'pending_manifest',
    errorCode: null,
    createdAt: now,
    updatedAt: now
  });
  const report = writer.recover();
  assert.equal(report.completed.length, 1);
  assert.equal(store.getArtifact(research.researchId, artifactId)?.status, 'ready');
  assert.equal(readManifest(workspace).artifacts.filter((item) => item.artifactId === artifactId).length, 1);
  close();
});

test('ready row with missing file is marked corrupt instead of remaining ready', () => {
  const { writer, workspace, store, research, close } = harness();
  const saved = writer.save({
    kind: 'report',
    contents: 'ready then missing',
    producer: 'report-writing',
    evidenceLevel: 'research_note'
  });
  unlinkSync(join(workspace, saved.relativePath));
  const report = writer.recover();
  assert.equal(report.corrupt.includes(saved.artifactId), true);
  assert.equal(store.getArtifact(research.researchId, saved.artifactId)?.status, 'corrupt');
  assert.throws(
    () => writer.get(saved.artifactId),
    (error: unknown) => error instanceof DomainError && error.code === 'ARTIFACT_CORRUPT'
  );
  close();
});
