import type { ArtifactWriter } from '../artifacts/writer.js';
import type { V2MemoryEntryRecord, V2Store } from '../db/v2/store.js';
import { nowIso } from '../domain/ids.js';
import { DomainError } from '../domain/types.js';
import { newMemoryEntryId } from '../research-v2/state.js';
import { MEMORY_CONTENT_MAX, type MemoryEntry, type MemorySnapshot } from './types.js';
import { expireDueProposals, toProposal } from './proposals.js';

export interface ResearchMemoryOptions {
  store: V2Store;
  writerFor: (researchId: string) => ArtifactWriter | null;
}

export class ResearchMemory {
  constructor(private readonly options: ResearchMemoryOptions) {}

  snapshot(researchId: string): MemorySnapshot {
    this.assertResearch(researchId);
    expireDueProposals(this.options.store, researchId);
    return {
      researchId,
      entries: this.options.store.listMemoryEntries(researchId).map(toEntry),
      proposals: this.options.store.listMemoryProposals(researchId).map(toProposal)
    };
  }

  upsert(
    researchId: string,
    input: {
      type: string;
      content: string;
      sourceArtifactId?: string | null;
      hypothesis?: boolean;
      memoryEntryId?: string;
    }
  ): MemoryEntry {
    const writer = this.writer(researchId);
    const now = nowIso();
    const sourceArtifactId = input.sourceArtifactId ?? null;
    const hypothesis = sourceArtifactId ? Boolean(input.hypothesis) : true;
    const content = clip(input.content, MEMORY_CONTENT_MAX);
    const existing = this.loadEntries(researchId, writer);
    const index = input.memoryEntryId
      ? existing.findIndex((entry) => entry.memoryEntryId === input.memoryEntryId)
      : -1;
    const next: MemoryEntry =
      index >= 0
        ? {
            ...existing[index]!,
            type: input.type,
            content,
            sourceArtifactId,
            hypothesis,
            confirmedAt: now
          }
        : {
            memoryEntryId: input.memoryEntryId ?? newMemoryEntryId(),
            scope: 'research',
            type: input.type,
            content,
            status: 'active',
            sourceArtifactId,
            hypothesis,
            createdAt: now,
            confirmedAt: now
          };
    const entries = index >= 0 ? existing.map((entry, i) => (i === index ? next : entry)) : [...existing, next];
    writer.save({
      kind: 'research_memory',
      contents: encodeResearchMemory(researchId, entries, now),
      producer: 'write_research_memory',
      evidenceLevel: 'research_note'
    });
    this.options.store.replaceResearchMemoryEntries(researchId, entries.map((entry) => toRecord(researchId, entry)));
    return next;
  }

  private loadEntries(researchId: string, writer: ArtifactWriter): MemoryEntry[] {
    const ready = this.options.store
      .listArtifacts(researchId, 'research_memory')
      .find((item) => item.status === 'ready');
    if (!ready) return [];
    try {
      return parseResearchMemory(writer.get(ready.artifactId).text);
    } catch {
      return this.options.store.listMemoryEntries(researchId).map(toEntry);
    }
  }

  private writer(researchId: string): ArtifactWriter {
    this.assertResearch(researchId);
    const writer = this.options.writerFor(researchId);
    if (!writer) {
      throw new DomainError('MEMORY_SCOPE_DENIED', 'research memory is not available for this research', false, 403);
    }
    return writer;
  }

  private assertResearch(researchId: string): void {
    if (!this.options.store.getResearch(researchId)) {
      throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    }
  }
}

export function encodeResearchMemory(researchId: string, entries: MemoryEntry[], updatedAt: string): string {
  const parts = [
    '---',
    'schemaVersion: 1',
    `researchId: ${JSON.stringify(researchId)}`,
    `updatedAt: ${JSON.stringify(updatedAt)}`,
    '---',
    ''
  ];
  for (const entry of entries) {
    parts.push(`### ${entry.memoryEntryId}`);
    parts.push(`type: ${entry.type}`);
    parts.push(`status: ${entry.status}`);
    parts.push(`sourceArtifactId: ${entry.sourceArtifactId ?? 'null'}`);
    parts.push(`hypothesis: ${entry.hypothesis ? 'true' : 'false'}`);
    parts.push(`createdAt: ${entry.createdAt}`);
    parts.push(`confirmedAt: ${entry.confirmedAt ?? 'null'}`);
    parts.push('');
    parts.push(entry.content.trim());
    parts.push('');
  }
  return parts.join('\n');
}

export function parseResearchMemory(markdown: string): MemoryEntry[] {
  const blocks = markdown.split(/^### /m).slice(1);
  const entries: MemoryEntry[] = [];
  for (const block of blocks) {
    const [header, ...rest] = block.split(/\n\n/);
    const lines = (header ?? '').split('\n');
    const memoryEntryId = lines[0]?.trim();
    if (!memoryEntryId) continue;
    const fields = Object.fromEntries(
      lines.slice(1).map((line) => {
        const idx = line.indexOf(':');
        return [line.slice(0, idx).trim(), line.slice(idx + 1).trim()];
      })
    );
    entries.push({
      memoryEntryId,
      scope: 'research',
      type: fields.type || 'note',
      content: rest.join('\n\n').trim(),
      status: fields.status || 'active',
      sourceArtifactId: fields.sourceArtifactId && fields.sourceArtifactId !== 'null' ? fields.sourceArtifactId : null,
      hypothesis: fields.hypothesis === 'true',
      createdAt: fields.createdAt || nowIso(),
      confirmedAt: fields.confirmedAt && fields.confirmedAt !== 'null' ? fields.confirmedAt : null
    });
  }
  return entries;
}

function toEntry(record: V2MemoryEntryRecord): MemoryEntry {
  return {
    memoryEntryId: record.memoryEntryId,
    scope: record.scope,
    type: record.type,
    content: record.content,
    status: record.status,
    sourceArtifactId: record.sourceArtifactId,
    hypothesis: record.hypothesis,
    createdAt: record.createdAt,
    confirmedAt: record.confirmedAt
  };
}

function toRecord(researchId: string, entry: MemoryEntry): V2MemoryEntryRecord {
  return {
    memoryEntryId: entry.memoryEntryId,
    researchId,
    sourceResearchId: researchId,
    scope: 'research',
    type: entry.type,
    content: entry.content,
    status: entry.status,
    sourceArtifactId: entry.sourceArtifactId,
    hypothesis: entry.hypothesis,
    createdAt: entry.createdAt,
    confirmedAt: entry.confirmedAt
  };
}

function clip(value: string, max: number): string {
  const text = value.normalize('NFC').trim();
  if (!text) {
    throw new DomainError('INVALID_REQUEST', 'memory content is required', false, 400);
  }
  return text.slice(0, max);
}
