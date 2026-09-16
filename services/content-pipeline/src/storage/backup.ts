import { readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { DatabaseSync } from 'node:sqlite';

import type { Logger } from '../observability/logger.js';
import type { KeyLayout } from './keys.js';
import type { ObjectStore } from './object-store.js';

/**
 * SQLite backup to R2. Uses VACUUM INTO for a consistent snapshot, uploads to
 * the backups prefix, and verifies the upload with HEAD. Backups never
 * contain environment secrets (the DB holds no secret columns by design).
 */
export async function backupDatabase(options: {
  db: DatabaseSync;
  objects: ObjectStore;
  keys: KeyLayout;
  logger: Logger;
  now?: Date;
}): Promise<{ key: string; bytes: number }> {
  const { db, objects, keys, logger } = options;
  const stamp = (options.now ?? new Date()).toISOString().replace(/[:.]/g, '-');
  const fileName = `content-db-${stamp}.sqlite3`;
  const tempPath = join(tmpdir(), `content-backup-${process.pid}-${stamp}.sqlite3`);
  try {
    const escaped = tempPath.replace(/'/g, "''");
    db.exec(`VACUUM INTO '${escaped}'`);
    const data = await readFile(tempPath);
    const key = keys.backup(fileName);
    keys.assertAllowed(key);
    await objects.put(key, data, 'application/x-sqlite3');
    const head = await objects.head(key);
    if (!head || head.bytes !== data.length) {
      throw new Error('backup verification failed: uploaded object missing or size mismatch');
    }
    logger.info('database backup uploaded', { key, bytes: data.length });
    return { key, bytes: data.length };
  } finally {
    await rm(tempPath, { force: true });
  }
}
