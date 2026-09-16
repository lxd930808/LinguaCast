import { createHash } from 'node:crypto';

import type { DatabaseSync } from 'node:sqlite';

import { SEARCH_SCHEMA_VERSION } from './contracts.js';

export interface SearchCache {
  get<T>(key: string): T | null;
  set<T>(key: string, provider: string, value: T, ttlMs: number): void;
}

export function cacheKey(parts: Record<string, unknown>): string {
  const normalized = Object.keys(parts)
    .sort()
    .map((key) => `${key}=${stable(parts[key])}`)
    .join('|');
  return createHash('sha256').update(`${SEARCH_SCHEMA_VERSION}|${normalized}`).digest('hex');
}

function stable(value: unknown): string {
  if (value == null) return '';
  if (typeof value === 'string') return value.normalize('NFC').trim().toLowerCase();
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  return JSON.stringify(value);
}

export class MemorySearchCache implements SearchCache {
  private readonly data = new Map<string, { expiresAt: number; value: unknown }>();

  get<T>(key: string): T | null {
    const row = this.data.get(key);
    if (!row || row.expiresAt < Date.now()) {
      if (row) this.data.delete(key);
      return null;
    }
    return row.value as T;
  }

  set<T>(key: string, _provider: string, value: T, ttlMs: number): void {
    this.data.set(key, { value, expiresAt: Date.now() + ttlMs });
  }
}

export class SqliteSearchCache implements SearchCache {
  private readonly l1 = new MemorySearchCache();

  constructor(private readonly db: DatabaseSync) {}

  get<T>(key: string): T | null {
    const warm = this.l1.get<T>(key);
    if (warm) return warm;
    const row = this.db.prepare('SELECT payload_json, expires_at FROM search_cache WHERE cache_key = ?').get(key) as
      | { payload_json: string; expires_at: number }
      | undefined;
    if (!row || Number(row.expires_at) < Date.now()) return null;
    const stored = JSON.parse(row.payload_json) as T;
    this.l1.set(key, 'sqlite', stored, 15_000);
    return stored;
  }

  set<T>(key: string, provider: string, value: T, ttlMs: number): void {
    this.l1.set(key, provider, value, Math.min(ttlMs, 15_000));
    this.db
      .prepare(
        `INSERT INTO search_cache (cache_key, provider, payload_json, expires_at) VALUES (?, ?, ?, ?)
         ON CONFLICT(cache_key) DO UPDATE SET payload_json=excluded.payload_json, expires_at=excluded.expires_at`
      )
      .run(key, provider, JSON.stringify(value), Date.now() + ttlMs);
  }
}

export const SUCCESS_TTL_MS = 30 * 60 * 1000;
export const EMPTY_TTL_MS = 5 * 60 * 1000;

export function ttlForStatus(status: 'success' | 'empty' | string, successTtl = SUCCESS_TTL_MS, emptyTtl = EMPTY_TTL_MS): number | null {
  if (status === 'success') return successTtl;
  if (status === 'empty') return emptyTtl;
  return null;
}
