#!/usr/bin/env node
/**
 * Self-host backup helpers (V18): consistent SQLite snapshots of the account,
 * content and assistant databases, the assistant workspace trees, and account
 * deletion tombstones. Never prints secrets, tokens or host paths.
 *
 * Commands:
 *   pack --out <dir> --stamp <stamp> --account-db <db> --content-db <db>
 *        --assistant-db <db> --workspaces <dir> --global-memory <dir> --shared-versions <dir>
 *        [--r2-bucket <name>] [--r2-prefix <prefix>] [--r2-environment <env>]
 *   verify --root <dir>
 *   tombstones-export --database <account.db> --out <file>
 *   tombstones-apply --database <restored account.db> --in <file> [--purge-targets content,assistant,media]
 */
import { createHash, randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

import { packBackup as packAssistant, verifyBackupRoot as verifyAssistant, vacuumSqlite } from '../../research-assistant/lib/v15-backup.mjs';

export const BACKUP_SCHEMA = 'linguacast-selfhost-backup-v1';
export const TOMBSTONE_SCHEMA = 'linguacast-account-tombstones-v1';
const ACCOUNT_TABLES = ['accounts', 'account_deletions', 'sessions', 'quota_reservations', 'quota_ledger'];
const CONTENT_TABLES = ['content_job', 'artifact_manifest', 'quota_settlement_outbox'];
const DEFAULT_PURGE_TARGETS = ['content', 'assistant', 'media'];

function sha256File(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function checkSqlite(path, requiredTables) {
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    const row = db.prepare('PRAGMA integrity_check').get();
    const integrity = row ? String(Object.values(row)[0]) : '';
    if (integrity !== 'ok') return { ok: false, error: 'sqlite_integrity_failed' };
    const tables = new Set(db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all().map((r) => r.name));
    const missing = requiredTables.filter((name) => !tables.has(name));
    if (missing.length > 0) return { ok: false, error: 'table_missing', tables: missing };
    return { ok: true, db };
  } catch (error) {
    db.close();
    throw error;
  }
}

function count(db, sql) {
  return Number(db.prepare(sql).get().n);
}

/** Consistent snapshot plus integrity and schema check; returns row counts. */
function snapshot(source, dest, requiredTables, counts) {
  if (!existsSync(source)) throw new Error(`database missing: ${requiredTables[0]}`);
  vacuumSqlite(source, dest);
  const result = checkSqlite(dest, requiredTables);
  if (!result.ok) throw new Error(result.error);
  try {
    return Object.fromEntries(Object.entries(counts).map(([key, sql]) => [key, count(result.db, sql)]));
  } finally {
    result.db.close();
  }
}

export function exportTombstones(accountDb) {
  const db = new DatabaseSync(accountDb, { readOnly: true });
  try {
    const rows = db
      .prepare('SELECT account_id, status, requested_at, completed_at FROM account_deletions ORDER BY requested_at')
      .all();
    return {
      schema: TOMBSTONE_SCHEMA,
      tombstones: rows.map((row) => ({
        accountId: String(row.account_id),
        status: String(row.status),
        requestedAt: Number(row.requested_at),
        completedAt: row.completed_at == null ? null : Number(row.completed_at)
      }))
    };
  } finally {
    db.close();
  }
}

export function packSelfHost(options) {
  const out = options.outDir;
  mkdirSync(join(out, 'account'), { recursive: true });
  mkdirSync(join(out, 'content'), { recursive: true });
  const account = snapshot(options.accountDb, join(out, 'account', 'account.db'), ACCOUNT_TABLES, {
    accounts: 'SELECT COUNT(*) AS n FROM accounts',
    deletions: 'SELECT COUNT(*) AS n FROM account_deletions',
    openReservations: "SELECT COUNT(*) AS n FROM quota_reservations WHERE status NOT IN ('consumed', 'released')"
  });
  const content = snapshot(options.contentDb, join(out, 'content', 'content.db'), CONTENT_TABLES, {
    jobs: 'SELECT COUNT(*) AS n FROM content_job',
    artifactManifests: 'SELECT COUNT(*) AS n FROM artifact_manifest'
  });
  const assistant = packAssistant({
    outDir: join(out, 'assistant'),
    stamp: options.stamp,
    databasePath: options.assistantDb,
    workspaceRoot: options.workspaces,
    globalMemoryRoot: options.globalMemory,
    sharedVersionRoot: options.sharedVersions
  });
  // Tombstones are also stored separately so a restore can replay deletions that
  // happened after an older backup was taken.
  const tombstones = exportTombstones(join(out, 'account', 'account.db'));
  writeFileSync(join(out, 'tombstones.json'), `${JSON.stringify(tombstones, null, 2)}\n`);
  const meta = {
    schema: BACKUP_SCHEMA,
    stamp: options.stamp,
    sha256: {
      'account/account.db': sha256File(join(out, 'account', 'account.db')),
      'content/content.db': sha256File(join(out, 'content', 'content.db')),
      'tombstones.json': sha256File(join(out, 'tombstones.json'))
    },
    counts: { account, content, assistant: assistant.meta.counts, tombstones: tombstones.tombstones.length },
    // Artifacts live in object storage and are not copied; restores need the same bucket and prefix.
    objectStorage: {
      provider: 'cloudflare-r2',
      bucket: options.r2Bucket || null,
      prefix: options.r2Prefix || null,
      environment: options.r2Environment || null,
      copied: false
    },
    // Media files are a short-lived download cache (JOB_TTL_MS) and are rebuilt on demand.
    mediaCache: 'not-included'
  };
  writeFileSync(join(out, 'backup-meta.json'), `${JSON.stringify(meta, null, 2)}\n`);
  return meta;
}

export function verifySelfHost(root) {
  const metaPath = join(root, 'backup-meta.json');
  if (!existsSync(metaPath)) return { ok: false, error: 'backup_meta_missing' };
  const meta = JSON.parse(readFileSync(metaPath, 'utf8'));
  if (meta.schema !== BACKUP_SCHEMA) return { ok: false, error: 'unknown_backup_schema' };
  for (const [relative, expected] of Object.entries(meta.sha256 ?? {})) {
    const path = join(root, relative);
    if (!existsSync(path)) return { ok: false, error: 'file_missing', file: relative };
    if (sha256File(path) !== expected) return { ok: false, error: 'hash_mismatch', file: relative };
  }
  for (const [relative, tables] of [
    ['account/account.db', ACCOUNT_TABLES],
    ['content/content.db', CONTENT_TABLES]
  ]) {
    const result = checkSqlite(join(root, relative), tables);
    if (!result.ok) return { ok: false, error: result.error, file: relative };
    result.db.close();
  }
  const assistant = verifyAssistant(join(root, 'assistant'));
  if (!assistant.ok) return { ok: false, error: 'assistant_verify_failed' };
  const tombstones = JSON.parse(readFileSync(join(root, 'tombstones.json'), 'utf8'));
  if (tombstones.schema !== TOMBSTONE_SCHEMA || tombstones.tombstones.length !== meta.counts.tombstones) {
    return { ok: false, error: 'tombstones_invalid' };
  }
  return { ok: true, meta, assistant };
}

const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
function ulid(now = Date.now()) {
  let time = '';
  let value = now;
  for (let i = 0; i < 10; i += 1) {
    time = CROCKFORD[value % 32] + time;
    value = Math.floor(value / 32);
  }
  const random = [...randomBytes(16)].map((byte) => CROCKFORD[byte % 32]).join('');
  return time + random;
}

/**
 * Re-applies deletions recorded in a newer (live) account database to a restored
 * one: affected accounts return to `deleting` with pending purge steps, their
 * sessions are revoked and Apple identities removed, so the account service's
 * deletion worker purges any data the restore brought back. Mirrors
 * AuthService.requestDeletion; accounts absent from the restore are skipped.
 */
export function applyTombstones(restoredDb, tombstoneFile, purgeTargets = DEFAULT_PURGE_TARGETS, now = Date.now()) {
  const { schema, tombstones } = JSON.parse(readFileSync(tombstoneFile, 'utf8'));
  if (schema !== TOMBSTONE_SCHEMA) throw new Error('unknown tombstone schema');
  const db = new DatabaseSync(restoredDb);
  const summary = { replayed: 0, alreadyDeleted: 0, alreadyPending: 0, notInBackup: 0 };
  const steps = JSON.stringify(purgeTargets.map((name) => ({ name: `purge:${name}`, status: 'pending', attempts: 0 })));
  try {
    db.exec('BEGIN IMMEDIATE');
    for (const tombstone of tombstones) {
      const account = db.prepare('SELECT status FROM accounts WHERE account_id = ?').get(tombstone.accountId);
      if (!account) {
        summary.notInBackup += 1;
        continue;
      }
      if (account.status === 'deleted') {
        summary.alreadyDeleted += 1;
        continue;
      }
      const deletion = db.prepare('SELECT status FROM account_deletions WHERE account_id = ?').get(tombstone.accountId);
      if (deletion && deletion.status !== 'completed') {
        summary.alreadyPending += 1;
        continue;
      }
      if (deletion) {
        db.prepare(
          `UPDATE account_deletions
              SET status = 'pending', steps_json = ?, attempts = 0, next_attempt_at = ?, last_error_code = NULL,
                  apple_client_id = NULL, apple_refresh_token_enc = NULL, completed_at = NULL
            WHERE account_id = ?`
        ).run(steps, now, tombstone.accountId);
      } else {
        db.prepare(
          `INSERT INTO account_deletions (deletion_id, account_id, status, steps_json, apple_client_id,
             apple_refresh_token_enc, attempts, next_attempt_at, last_error_code, requested_at, completed_at)
           VALUES (?, ?, 'pending', ?, NULL, NULL, 0, ?, NULL, ?, NULL)`
        ).run(`del_${ulid(now)}`, tombstone.accountId, steps, now, tombstone.requestedAt || now);
      }
      db.prepare("UPDATE accounts SET status = 'deleting', updated_at = ? WHERE account_id = ?").run(now, tombstone.accountId);
      const sessions = db.prepare('SELECT session_id FROM sessions WHERE account_id = ? AND revoked_at IS NULL').all(tombstone.accountId);
      for (const session of sessions) {
        db.prepare('UPDATE sessions SET revoked_at = ?, revoke_reason = ? WHERE session_id = ? AND revoked_at IS NULL').run(
          now,
          'account_deleted',
          session.session_id
        );
        db.prepare("UPDATE refresh_tokens SET status = 'revoked' WHERE session_id = ? AND status = 'active'").run(session.session_id);
      }
      db.prepare('DELETE FROM apple_identities WHERE account_id = ?').run(tombstone.accountId);
      summary.replayed += 1;
    }
    db.exec('COMMIT');
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  } finally {
    db.close();
  }
  return summary;
}

function parseArgs(argv) {
  const args = {};
  for (let i = 3; i < argv.length; i += 1) {
    if (!argv[i].startsWith('--')) continue;
    args[argv[i].slice(2)] = argv[i + 1];
    i += 1;
  }
  return { command: argv[2], args };
}

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function main() {
  const { command, args } = parseArgs(process.argv);
  switch (command) {
    case 'pack': {
      const meta = packSelfHost({
        outDir: resolve(args.out ?? fail('--out is required')),
        stamp: args.stamp ?? new Date().toISOString(),
        accountDb: args['account-db'],
        contentDb: args['content-db'],
        assistantDb: args['assistant-db'],
        workspaces: args.workspaces,
        globalMemory: args['global-memory'],
        sharedVersions: args['shared-versions'],
        r2Bucket: args['r2-bucket'],
        r2Prefix: args['r2-prefix'],
        r2Environment: args['r2-environment']
      });
      const c = meta.counts;
      process.stdout.write(
        `backup packed accounts=${c.account.accounts} deletions=${c.account.deletions} content_jobs=${c.content.jobs} ` +
          `v2_researches=${c.assistant.researches} workspace_files=${c.assistant.workspaceFiles} tombstones=${c.tombstones}\n`
      );
      return;
    }
    case 'verify': {
      const result = verifySelfHost(resolve(args.root ?? fail('--root is required')));
      if (!result.ok) {
        process.stdout.write(`restore-verify failed code=${result.error}${result.file ? ` file=${result.file}` : ''}\n`);
        process.exit(1);
      }
      const c = result.meta.counts;
      process.stdout.write(
        `restore-verify ok accounts=${c.account.accounts} content_jobs=${c.content.jobs} ` +
          `v2_researches=${c.assistant.researches} tombstones=${c.tombstones} object_storage_copied=false\n`
      );
      return;
    }
    case 'tombstones-export': {
      const data = exportTombstones(args.database ?? fail('--database is required'));
      writeFileSync(args.out ?? fail('--out is required'), `${JSON.stringify(data, null, 2)}\n`);
      process.stdout.write(`tombstones exported count=${data.tombstones.length}\n`);
      return;
    }
    case 'tombstones-apply': {
      const targets = (args['purge-targets'] ?? DEFAULT_PURGE_TARGETS.join(',')).split(',').filter(Boolean);
      const summary = applyTombstones(args.database ?? fail('--database is required'), args.in ?? fail('--in is required'), targets);
      process.stdout.write(
        `tombstones applied replayed=${summary.replayed} already_deleted=${summary.alreadyDeleted} ` +
          `already_pending=${summary.alreadyPending} not_in_backup=${summary.notInBackup}\n`
      );
      return;
    }
    default:
      fail('usage: selfhost-backup.mjs pack|verify|tombstones-export|tombstones-apply');
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}

