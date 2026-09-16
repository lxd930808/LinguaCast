import { mkdirSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

/**
 * Versioned, upgrade-only migration runner. Migrations live in migrations/
 * as NNNN_name.sql files applied in order; applied versions are recorded in
 * schema_migration. Downgrades are never attempted.
 */
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
    'CREATE TABLE IF NOT EXISTS schema_migration (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)'
  );
  const applied = new Set(
    (db.prepare('SELECT version FROM schema_migration').all() as Array<{ version: number }>).map(
      (row) => row.version
    )
  );
  const files = readdirSync(migrationsDir)
    .filter((name) => /^\d{4}_.*\.sql$/.test(name))
    .sort();
  for (const file of files) {
    const version = Number(file.slice(0, 4));
    if (applied.has(version)) continue;
    const sql = readFileSync(join(migrationsDir, file), 'utf8');
    db.exec('BEGIN IMMEDIATE');
    try {
      db.exec(sql);
      db.prepare('INSERT INTO schema_migration (version, applied_at) VALUES (?, ?)').run(
        version,
        Date.now()
      );
      db.exec('COMMIT');
    } catch (error) {
      db.exec('ROLLBACK');
      throw new Error(`migration ${file} failed: ${String(error)}`);
    }
  }
}
