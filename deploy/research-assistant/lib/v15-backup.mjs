#!/usr/bin/env node
/**
 * V15 assistant backup pack/verify helpers.
 * Never prints host secrets, shared grant roots, or workspace real paths.
 */
import { createHash } from 'node:crypto';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync
} from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { spawnSync } from 'node:child_process';

export const BACKUP_SCHEMA = 'linguacast-assistant-backup-v15';
export const RESEARCH_ID_PATTERN = /^[0-9A-HJKMNP-TV-Z]{26}$/;
export const RELATIVE_PATH_PATTERN =
  /^(manifest\.json|sources|transcripts|memory|reports)(\/[A-Za-z0-9._-]+)*$/;
const REQUIRED_TABLES = ['schema_migrations', 'sessions', 'turns', 'messages', 'reports'];

function die(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function sha256File(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function isInside(root, candidate) {
  const base = resolve(root);
  const target = resolve(candidate);
  return target === base || target.startsWith(`${base}${sep}`);
}

function listFiles(root) {
  if (!existsSync(root)) return [];
  const out = [];
  const stack = [root];
  while (stack.length > 0) {
    const current = stack.pop();
    for (const name of readdirSync(current)) {
      const full = join(current, name);
      const st = statSync(full);
      if (st.isDirectory()) stack.push(full);
      else if (st.isFile()) out.push(full);
    }
  }
  return out;
}

function copyTree(src, dest) {
  mkdirSync(dest, { recursive: true });
  if (!existsSync(src)) return { files: 0, bytes: 0 };
  let files = 0;
  let bytes = 0;
  for (const full of listFiles(src)) {
    const rel = relative(src, full);
    if (rel.split(/[/\\]/).includes('..')) continue;
    const target = join(dest, rel);
    mkdirSync(dirname(target), { recursive: true });
    copyFileSync(full, target);
    files += 1;
    bytes += statSync(full).size;
  }
  return { files, bytes };
}

export function vacuumSqlite(sourceDb, destDb) {
  mkdirSync(dirname(destDb), { recursive: true });
  const db = new DatabaseSync(sourceDb, { readOnly: true });
  try {
    db.exec('PRAGMA wal_checkpoint(FULL)');
  } catch {
    // Read-only connections may not checkpoint; VACUUM INTO is still consistent.
  }
  db.exec(`VACUUM INTO '${destDb.replaceAll("'", "''")}'`);
  db.close();
}

export function verifySqlite(dbPath) {
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try {
    const check = db.prepare('PRAGMA integrity_check').get();
    const integrity = check ? String(Object.values(check)[0]) : '';
    if (integrity !== 'ok') {
      return { ok: false, error: 'sqlite_integrity_failed', integrity };
    }
    const tables = new Set(
      db.prepare(`SELECT name FROM sqlite_master WHERE type = 'table'`).all().map((row) => row.name)
    );
    for (const name of REQUIRED_TABLES) {
      if (!tables.has(name)) {
        return { ok: false, error: 'v1_table_missing', table: name };
      }
    }
    const sessionCount = db.prepare('SELECT COUNT(*) AS n FROM sessions').get().n;
    const messageCount = db.prepare('SELECT COUNT(*) AS n FROM messages').get().n;
    const migrations = db
      .prepare('SELECT version FROM schema_migrations ORDER BY version')
      .all()
      .map((row) => row.version);
    const v2 = tables.has('v2_researches');
    const researchCount = v2 ? db.prepare('SELECT COUNT(*) AS n FROM v2_researches').get().n : 0;
    const artifactCount = v2 ? db.prepare('SELECT COUNT(*) AS n FROM v2_artifacts').get().n : 0;
    return {
      ok: true,
      sessionCount,
      messageCount,
      migrations,
      v2,
      researchCount,
      artifactCount
    };
  } finally {
    db.close();
  }
}

export function verifyWorkspaces(workspaceRoot) {
  const summary = {
    ok: true,
    workspaces: 0,
    artifactsReady: 0,
    artifactsPending: 0,
    artifactsCorrupt: 0,
    artifactsSuperseded: 0,
    hashMismatch: 0,
    missingReady: 0,
    invalidManifest: 0
  };
  if (!existsSync(workspaceRoot)) return summary;
  for (const name of readdirSync(workspaceRoot)) {
    const dir = join(workspaceRoot, name);
    if (!statSync(dir).isDirectory()) continue;
    if (name.startsWith('.tmp-')) continue;
    if (!RESEARCH_ID_PATTERN.test(name)) continue;
    const manifestPath = join(dir, 'manifest.json');
    if (!existsSync(manifestPath)) {
      summary.invalidManifest += 1;
      summary.ok = false;
      continue;
    }
    let manifest;
    try {
      manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
    } catch {
      summary.invalidManifest += 1;
      summary.ok = false;
      continue;
    }
    if (manifest.schemaVersion !== 1 || manifest.researchId !== name || !Array.isArray(manifest.artifacts)) {
      summary.invalidManifest += 1;
      summary.ok = false;
      continue;
    }
    summary.workspaces += 1;
    for (const item of manifest.artifacts) {
      if (!item || typeof item !== 'object') continue;
      if (item.status === 'pending') {
        summary.artifactsPending += 1;
        continue;
      }
      if (item.status === 'corrupt') {
        summary.artifactsCorrupt += 1;
        continue;
      }
      if (item.status === 'superseded') {
        summary.artifactsSuperseded += 1;
      }
      if (item.status !== 'ready') continue;
      summary.artifactsReady += 1;
      if (
        typeof item.relativePath !== 'string' ||
        item.relativePath.includes('..') ||
        !RELATIVE_PATH_PATTERN.test(item.relativePath)
      ) {
        summary.hashMismatch += 1;
        summary.ok = false;
        continue;
      }
      const filePath = join(dir, item.relativePath);
      if (!isInside(dir, filePath) || !existsSync(filePath)) {
        summary.missingReady += 1;
        summary.ok = false;
        continue;
      }
      const bytes = readFileSync(filePath);
      if (sha256File(filePath) !== item.sha256 || bytes.length !== item.bytes) {
        summary.hashMismatch += 1;
        summary.ok = false;
      }
    }
  }
  return summary;
}

export function packBackup(options) {
  const outDir = options.outDir;
  mkdirSync(outDir, { recursive: true });
  const dbDest = join(outDir, 'assistant.db');
  vacuumSqlite(options.databasePath, dbDest);
  const sqlite = verifySqlite(dbDest);
  if (!sqlite.ok) throw new Error(sqlite.error || 'sqlite verify failed');
  const workspaces = copyTree(options.workspaceRoot, join(outDir, 'workspaces'));
  const globalMemory = copyTree(options.globalMemoryRoot, join(outDir, 'global-memory'));
  const sharedVersions = copyTree(options.sharedVersionRoot, join(outDir, 'shared-versions'));
  const workspaceVerify = verifyWorkspaces(join(outDir, 'workspaces'));
  const meta = {
    schema: BACKUP_SCHEMA,
    stamp: options.stamp,
    sqliteSha256: sha256File(dbDest),
    includes: ['sqlite', 'workspaces', 'global-memory', 'shared-versions'],
    counts: {
      v1Sessions: sqlite.sessionCount,
      v1Messages: sqlite.messageCount,
      v2: sqlite.v2,
      researches: sqlite.researchCount,
      workspaceFiles: workspaces.files,
      globalMemoryFiles: globalMemory.files,
      sharedVersionFiles: sharedVersions.files,
      artifactsReady: workspaceVerify.artifactsReady,
      artifactsPending: workspaceVerify.artifactsPending,
      artifactsCorrupt: workspaceVerify.artifactsCorrupt
    }
  };
  writeFileSync(join(outDir, 'backup-meta.json'), `${JSON.stringify(meta, null, 2)}\n`);
  return { meta, sqlite, workspaceVerify };
}

export function verifyBackupRoot(root) {
  const dbPath = join(root, 'assistant.db');
  if (!existsSync(dbPath)) {
    return { ok: false, error: 'assistant.db missing' };
  }
  const sqlite = verifySqlite(dbPath);
  if (!sqlite.ok) return { ok: false, sqlite };
  const workspaces = verifyWorkspaces(join(root, 'workspaces'));
  const metaPath = join(root, 'backup-meta.json');
  let meta = null;
  if (existsSync(metaPath)) {
    meta = JSON.parse(readFileSync(metaPath, 'utf8'));
    if (meta.schema !== BACKUP_SCHEMA) {
      return { ok: false, error: 'unknown_backup_schema' };
    }
    if (meta.sqliteSha256 && meta.sqliteSha256 !== sha256File(dbPath)) {
      return { ok: false, error: 'sqlite_hash_mismatch' };
    }
  }
  const ok = sqlite.ok && workspaces.ok;
  return { ok, sqlite, workspaces, meta };
}

function printVerify(result) {
  if (!result.ok) {
    const code = result.error || result.sqlite?.error || 'verify_failed';
    process.stdout.write(
      `restore-verify failed code=${code} hash_mismatch=${result.workspaces?.hashMismatch ?? 0} missing_ready=${result.workspaces?.missingReady ?? 0} invalid_manifest=${result.workspaces?.invalidManifest ?? 0}\n`
    );
    process.exit(1);
  }
  process.stdout.write(
    [
      'restore-verify ok',
      `sqlite=ok`,
      `v1_sessions=${result.sqlite.sessionCount}`,
      `v2=${result.sqlite.v2 ? '1' : '0'}`,
      `workspaces=${result.workspaces.workspaces}`,
      `artifacts_ready=${result.workspaces.artifactsReady}`,
      `artifacts_pending=${result.workspaces.artifactsPending}`,
      `artifacts_corrupt=${result.workspaces.artifactsCorrupt}`,
      `hash_mismatch=${result.workspaces.hashMismatch}`
    ].join(' ') + '\n'
  );
}

function parseArgs(argv) {
  const args = { command: argv[2], rest: {} };
  for (let i = 3; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith('--')) continue;
    args.rest[key.slice(2)] = argv[i + 1];
    i += 1;
  }
  return args;
}

function archiveDir(dir, tarPath) {
  const result = spawnSync('tar', ['-C', dir, '-cf', tarPath, '.'], { stdio: 'inherit' });
  if (result.status !== 0) die('tar pack failed');
}

function extractArchive(archive, dest) {
  mkdirSync(dest, { recursive: true });
  const result = spawnSync('tar', ['-C', dest, '-xf', archive], { stdio: 'inherit' });
  if (result.status !== 0) die('tar extract failed');
}

function isCli() {
  const invoked = process.argv[1] ? resolve(process.argv[1]) : '';
  return invoked.endsWith(`${sep}v15-backup.mjs`);
}

if (isCli()) {
  const args = parseArgs(process.argv);
  if (args.command === 'pack') {
    const stamp = args.rest.stamp || new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
    const outDir = args.rest.out;
    if (!outDir || !args.rest.database) die('usage: v15-backup.mjs pack --database FILE --out DIR');
    const packed = packBackup({
      stamp,
      databasePath: args.rest.database,
      workspaceRoot: args.rest.workspaces || '',
      globalMemoryRoot: args.rest['global-memory'] || '',
      sharedVersionRoot: args.rest['shared-versions'] || '',
      outDir
    });
    if (args.rest.tar) archiveDir(outDir, args.rest.tar);
    process.stdout.write(
      `backup packed v1_sessions=${packed.sqlite.sessionCount} workspaces=${packed.workspaceVerify.workspaces} artifacts_ready=${packed.workspaceVerify.artifactsReady}\n`
    );
  } else if (args.command === 'verify') {
    const root = args.rest.root;
    const archive = args.rest.archive;
    if (!root && !archive) die('usage: v15-backup.mjs verify --root DIR | --archive FILE');
    let verifyRoot = root;
    if (archive) {
      const tmp = args.rest.tmp || join(dirname(archive), `.verify-${process.pid}`);
      extractArchive(archive, tmp);
      verifyRoot = tmp;
    }
    printVerify(verifyBackupRoot(verifyRoot));
  } else if (args.command === 'verify-db') {
    if (!args.rest.database) die('usage: v15-backup.mjs verify-db --database FILE');
    const sqlite = verifySqlite(args.rest.database);
    printVerify({
      ok: sqlite.ok,
      sqlite,
      workspaces: {
        workspaces: 0,
        artifactsReady: 0,
        artifactsPending: 0,
        artifactsCorrupt: 0,
        hashMismatch: 0,
        missingReady: 0,
        invalidManifest: 0,
        ok: true
      }
    });
  } else {
    die('usage: v15-backup.mjs pack|verify|verify-db');
  }
}
