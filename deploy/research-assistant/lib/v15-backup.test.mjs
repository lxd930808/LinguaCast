import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';

import { packBackup, verifyBackupRoot, verifyWorkspaces } from './v15-backup.mjs';

const RESEARCH_ID = '01HQK0ABCDEFGHJKMNPQRSTVWX';

function sha256(text) {
  return createHash('sha256').update(text).digest('hex');
}

function writeV1Db(path) {
  const db = new DatabaseSync(path);
  db.exec(`
    CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);
    CREATE TABLE sessions (
      session_id TEXT PRIMARY KEY, title TEXT NOT NULL, phase TEXT NOT NULL,
      output_language TEXT NOT NULL, storefront TEXT NOT NULL, target_language TEXT NOT NULL,
      translation_quality TEXT NOT NULL, active_turn_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
    );
    CREATE TABLE turns (
      turn_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL,
      user_text TEXT NOT NULL, error_code TEXT, error_message TEXT, created_at TEXT NOT NULL
    );
    CREATE TABLE messages (
      message_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, turn_id TEXT NOT NULL, role TEXT NOT NULL,
      markdown TEXT NOT NULL, created_at TEXT NOT NULL
    );
    CREATE TABLE reports (report_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, markdown TEXT NOT NULL, created_at TEXT NOT NULL);
    INSERT INTO schema_migrations (version, applied_at) VALUES (1, 1), (2, 2), (3, 3);
    INSERT INTO sessions (session_id, title, phase, output_language, storefront, target_language, translation_quality, created_at, updated_at)
    VALUES ('s1', 'legacy', 'ready', 'zh-Hans', 'US', 'zh-Hans', 'quality', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
  `);
  db.close();
}

test('pack and verify keep V1 rows and ready artifact hashes', () => {
  const root = mkdtempSync(join(tmpdir(), 'v15-backup-'));
  const dbPath = join(root, 'live.db');
  writeV1Db(dbPath);
  const body = 'Firms are piloting document review.\n';
  const workspace = join(root, 'workspaces', RESEARCH_ID, 'reports');
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(workspace, 'r1.md'), body);
  writeFileSync(
    join(root, 'workspaces', RESEARCH_ID, 'manifest.json'),
    JSON.stringify({
      schemaVersion: 1,
      researchId: RESEARCH_ID,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      artifacts: [
        {
          artifactId: RESEARCH_ID,
          kind: 'report',
          status: 'ready',
          relativePath: 'reports/r1.md',
          mediaType: 'text/markdown',
          bytes: Buffer.byteLength(body),
          sha256: sha256(body),
          createdAt: '2026-01-01T00:00:00Z',
          producer: 'test',
          evidenceLevel: 'research_note'
        }
      ]
    })
  );
  mkdirSync(join(root, 'global-memory'));
  writeFileSync(join(root, 'global-memory', 'prefs.md'), 'language: zh-Hans\n');
  const outDir = join(root, 'pack');
  const packed = packBackup({
    stamp: '20260101T000000Z',
    databasePath: dbPath,
    workspaceRoot: join(root, 'workspaces'),
    globalMemoryRoot: join(root, 'global-memory'),
    sharedVersionRoot: join(root, 'missing-shared'),
    outDir
  });
  assert.equal(packed.sqlite.sessionCount, 1);
  assert.equal(packed.workspaceVerify.artifactsReady, 1);
  const verified = verifyBackupRoot(outDir);
  assert.equal(verified.ok, true);
  assert.equal(verified.sqlite.sessionCount, 1);
  assert.equal(verified.workspaces.artifactsReady, 1);
  assert.equal(verified.meta.counts.globalMemoryFiles, 1);

  const tarPath = join(root, 'assistant.tar');
  const packedTar = spawnSync('tar', ['-C', outDir, '-cf', tarPath, '.'], { encoding: 'utf8' });
  assert.equal(packedTar.status, 0);
  const script = join(dirname(fileURLToPath(import.meta.url)), '..', 'restore-verify.sh');
  const cli = spawnSync('bash', [script, tarPath], { encoding: 'utf8' });
  assert.equal(cli.status, 0, cli.stderr);
  assert.match(cli.stdout, /restore-verify ok/);
  assert.equal(cli.stdout.includes(root), false);
  assert.equal(/Bearer\s+\S+|X-Amz-|api[_-]?key=/i.test(cli.stdout), false);
});

test('ready artifact hash mismatch fails verify without printing file bytes', () => {
  const root = mkdtempSync(join(tmpdir(), 'v15-backup-bad-'));
  const workspaceDir = join(root, RESEARCH_ID);
  mkdirSync(join(workspaceDir, 'reports'), { recursive: true });
  writeFileSync(join(workspaceDir, 'reports', 'r1.md'), 'tampered\n');
  writeFileSync(
    join(workspaceDir, 'manifest.json'),
    JSON.stringify({
      schemaVersion: 1,
      researchId: RESEARCH_ID,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      artifacts: [
        {
          artifactId: RESEARCH_ID,
          kind: 'report',
          status: 'ready',
          relativePath: 'reports/r1.md',
          mediaType: 'text/markdown',
          bytes: 8,
          sha256: 'a'.repeat(64),
          createdAt: '2026-01-01T00:00:00Z',
          producer: 'test',
          evidenceLevel: 'research_note'
        }
      ]
    })
  );
  const result = verifyWorkspaces(root);
  assert.equal(result.ok, false);
  assert.equal(result.hashMismatch, 1);
});

test('pending artifacts do not fail restore-verify', () => {
  const root = mkdtempSync(join(tmpdir(), 'v15-backup-pending-'));
  const workspaceDir = join(root, RESEARCH_ID);
  mkdirSync(workspaceDir, { recursive: true });
  writeFileSync(
    join(workspaceDir, 'manifest.json'),
    JSON.stringify({
      schemaVersion: 1,
      researchId: RESEARCH_ID,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      artifacts: [
        {
          artifactId: RESEARCH_ID,
          kind: 'web_page',
          status: 'pending',
          relativePath: 'sources/web/pages/p1.md',
          mediaType: 'text/markdown',
          bytes: 1,
          sha256: 'b'.repeat(64),
          createdAt: '2026-01-01T00:00:00Z',
          producer: 'test',
          evidenceLevel: 'primary_content'
        }
      ]
    })
  );
  const result = verifyWorkspaces(root);
  assert.equal(result.ok, true);
  assert.equal(result.artifactsPending, 1);
  assert.equal(result.artifactsReady, 0);
});
