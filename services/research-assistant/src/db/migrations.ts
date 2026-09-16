import { mkdirSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

export function openDatabase(path: string, migrationsDir: string): DatabaseSync {
  if (path !== ':memory:') {
    mkdirSync(dirname(path), { recursive: true });
  }
  const db = new DatabaseSync(path);
  db.exec('PRAGMA journal_mode = WAL');
  db.exec('PRAGMA busy_timeout = 5000');
  db.exec('PRAGMA foreign_keys = ON');
  db.exec('PRAGMA synchronous = NORMAL');
  migrate(db, migrationsDir);
  return db;
}

export function migrate(db: DatabaseSync, migrationsDir: string): void {
  db.exec(
    'CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)'
  );
  const applied = new Set(
    (db.prepare('SELECT version FROM schema_migrations').all() as Array<{ version: number }>).map(
      (row) => row.version
    )
  );
  const files = readdirSync(migrationsDir)
    .filter((name) => /^\d{4}_.*\.sql$/.test(name))
    .sort();
  const versions = files.map((file) => Number(file.slice(0, 4)));
  const maxApplied = applied.size === 0 ? 0 : Math.max(...applied);
  const minFile = versions[0] ?? 0;
  if (maxApplied > 0 && versions.length > 0 && maxApplied < minFile) {
    throw new Error('database schema is newer than available migrations; refusing to start');
  }
  for (const version of applied) {
    if (!versions.includes(version) && version > (versions.at(-1) ?? 0)) {
      throw new Error(`database schema version ${version} is newer than this image; refusing to start`);
    }
  }
  for (const file of files) {
    const version = Number(file.slice(0, 4));
    if (applied.has(version)) continue;
    if (version < maxApplied) {
      throw new Error(`refusing to apply older migration ${file} after version ${maxApplied}`);
    }
    const sql = readFileSync(join(migrationsDir, file), 'utf8');
    db.exec('BEGIN IMMEDIATE');
    try {
      db.exec(sql);
      db.prepare('INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)').run(version, Date.now());
      db.exec('COMMIT');
    } catch (error) {
      db.exec('ROLLBACK');
      throw new Error(`migration ${file} failed: ${String(error)}`);
    }
  }
}

export function withTransaction<T>(db: DatabaseSync, fn: () => T): T {
  db.exec('BEGIN IMMEDIATE');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
}
