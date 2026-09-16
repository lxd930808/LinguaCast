import {
  chmodSync,
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  writeFileSync
} from 'node:fs';
import { join } from 'node:path';

import type { V2MemoryEntryRecord, V2Store } from '../db/v2/store.js';
import { nowIso } from '../domain/ids.js';
import { DomainError } from '../domain/types.js';
import { DIR_MODE, FILE_MODE } from '../workspace/layout.js';
import { newMemoryEntryId } from '../research-v2/state.js';
import { MEMORY_CONTENT_MAX, type MemoryEntry } from './types.js';

const PREFERENCES_FILE = 'preferences.json';
const ACCOUNT_OWNER = /^acc_[0-9A-HJKMNP-TV-Z]{26}$/;

export class GlobalMemory {
  constructor(
    private readonly store: V2Store,
    private readonly root: string
  ) {}

  /** Confirmed preferences of one account ("global" never crosses accounts). */
  listConfirmed(ownerScope: string): MemoryEntry[] {
    return this.store.listConfirmedGlobalMemory(ownerScope).map(toEntry);
  }

  writeConfirmed(input: {
    content: string;
    type?: string;
    sourceResearchId: string;
    memoryEntryId?: string;
    /** Defaults to the owner of the source research. */
    ownerScope?: string;
  }): MemoryEntry {
    this.assertRoot();
    const ownerScope = input.ownerScope ?? this.store.getResearch(input.sourceResearchId, true)?.ownerScope;
    if (!ownerScope) {
      throw new DomainError('RESEARCH_NOT_FOUND', 'source research for the preference is unknown', false, 404);
    }
    const now = nowIso();
    const content = input.content.normalize('NFC').trim().slice(0, MEMORY_CONTENT_MAX);
    const entry: MemoryEntry = {
      memoryEntryId: input.memoryEntryId ?? newMemoryEntryId(),
      scope: 'global',
      type: input.type ?? 'preference',
      content,
      status: 'confirmed',
      sourceArtifactId: null,
      hypothesis: false,
      createdAt: now,
      confirmedAt: now
    };
    this.store.insertMemoryEntry({
      memoryEntryId: entry.memoryEntryId,
      researchId: null,
      sourceResearchId: input.sourceResearchId,
      scope: 'global',
      type: entry.type,
      content: entry.content,
      status: 'confirmed',
      sourceArtifactId: null,
      hypothesis: false,
      createdAt: now,
      confirmedAt: now,
      ownerScope
    });
    this.persist(entry, ownerScope);
    return entry;
  }

  forget(memoryEntryId: string): MemoryEntry {
    const entry = this.requireGlobal(memoryEntryId);
    if (entry.status === 'forgotten') return toEntry(entry);
    if (entry.status !== 'confirmed') {
      throw new DomainError('MEMORY_PROPOSAL_NOT_CONFIRMED', 'only confirmed global preferences can be forgotten', false, 409);
    }
    this.store.setMemoryEntryStatus(memoryEntryId, 'confirmed', 'forgotten');
    const forgotten = { ...toEntry(entry), status: 'forgotten' };
    this.persist(forgotten, entry.ownerScope ?? 'selfhost');
    return forgotten;
  }

  restore(memoryEntryId: string): MemoryEntry {
    const entry = this.requireGlobal(memoryEntryId);
    if (entry.status === 'confirmed') return toEntry(entry);
    if (entry.status !== 'forgotten') {
      throw new DomainError('MEMORY_PROPOSAL_NOT_CONFIRMED', 'only forgotten global preferences can be restored', false, 409);
    }
    this.store.setMemoryEntryStatus(memoryEntryId, 'forgotten', 'confirmed');
    const restored = { ...toEntry(entry), status: 'confirmed', confirmedAt: nowIso() };
    this.persist(restored, entry.ownerScope ?? 'selfhost');
    return restored;
  }

  private requireGlobal(memoryEntryId: string): V2MemoryEntryRecord {
    const entry = this.store.getMemoryEntry(memoryEntryId);
    if (!entry || entry.scope !== 'global') {
      throw new DomainError('MEMORY_SCOPE_DENIED', 'global preference is unknown', false, 403);
    }
    return entry;
  }

  /**
   * Directory holding one account's preferences file. Signed-in accounts use
   * <root>/accounts/<accountId>; the selfhost owner keeps the pre-V18 root file.
   */
  rootFor(ownerScope: string): string {
    return ACCOUNT_OWNER.test(ownerScope) ? join(this.root, 'accounts', ownerScope) : this.root;
  }

  private persist(entry: MemoryEntry, ownerScope: string): void {
    const dir = this.rootFor(ownerScope);
    const current = this.readFile(dir);
    const next = current.filter((item) => item.memoryEntryId !== entry.memoryEntryId);
    next.push(entry);
    const body = `${JSON.stringify({ schemaVersion: 1, updatedAt: nowIso(), entries: next }, null, 2)}\n`;
    mkdirSync(dir, { recursive: true, mode: DIR_MODE });
    const dest = join(dir, PREFERENCES_FILE);
    const temp = join(dir, `.tmp-${PREFERENCES_FILE}`);
    writeFileSync(temp, body, { mode: FILE_MODE });
    chmodSync(temp, FILE_MODE);
    fsyncNamed(temp);
    renameSync(temp, dest);
    chmodSync(dest, FILE_MODE);
    fsyncNamed(dest);
  }

  private readFile(dir: string): MemoryEntry[] {
    const dest = join(dir, PREFERENCES_FILE);
    if (!existsSync(dest)) return [];
    try {
      const parsed = JSON.parse(readFileSync(dest, 'utf8')) as { entries?: MemoryEntry[] };
      return Array.isArray(parsed.entries) ? parsed.entries : [];
    } catch {
      return [];
    }
  }

  private assertRoot(): void {
    if (!this.root) {
      throw new DomainError('MEMORY_SCOPE_DENIED', 'global memory root is not configured', false, 403);
    }
  }
}

function toEntry(record: V2MemoryEntryRecord): MemoryEntry {
  return {
    memoryEntryId: record.memoryEntryId,
    scope: 'global',
    type: record.type,
    content: record.content,
    status: record.status,
    sourceArtifactId: record.sourceArtifactId,
    hypothesis: record.hypothesis,
    createdAt: record.createdAt,
    confirmedAt: record.confirmedAt
  };
}

function fsyncNamed(path: string): void {
  const fd = openSync(path, 'r');
  try {
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
}
