import { createHash } from 'node:crypto';

import type { ArtifactWriter } from '../artifacts/writer.js';
import type { V2ArtifactRecord, V2PassageRecord, V2Store } from '../db/v2/store.js';
import { DomainError } from '../domain/types.js';
import { recallMemory } from '../memory/retrieval.js';
import type { FileTools } from '../workspace/file-tools.js';
import {
  clipExcerpt,
  detectConflicts,
  evidenceGaps,
  rankEvidence,
  type EvidenceItem,
  type EvidenceLevelName,
  type EvidencePack
} from './pack.js';

export interface RetrieveEvidenceInput {
  researchId: string;
  query: string;
  limit?: number;
}

export interface EvidenceIndex {
  retrieve(input: RetrieveEvidenceInput): Promise<EvidencePack>;
}

const FACT_LEVELS = new Set<EvidenceLevelName>([
  'primary_content',
  'transcript',
  'search_metadata',
  'research_note'
]);

export class EvidenceService implements EvidenceIndex {
  constructor(
    private readonly options: {
      store: V2Store;
      writerFor: (researchId: string) => ArtifactWriter | null;
      fileToolsFor?: (researchId: string) => FileTools | null;
    }
  ) {}

  async retrieve(input: RetrieveEvidenceInput): Promise<EvidencePack> {
    const research = this.options.store.getResearch(input.researchId);
    if (!research || research.status === 'deleted' || research.status === 'deleting') {
      throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    }
    const query = input.query.normalize('NFC').trim();
    const limit = Math.min(40, Math.max(1, input.limit ?? 12));
    const items: EvidenceItem[] = [];
    items.push(...this.fromPassages(input.researchId, query));
    items.push(...this.fromSharedFiles(input.researchId, query));
    const unique = dedupe(items).sort(rankEvidence).slice(0, limit);
    const facts = unique.filter((item) => FACT_LEVELS.has(item.evidenceLevel));
    const preferences = await this.fromPreferences(input.researchId, query);
    return {
      researchId: input.researchId,
      query,
      items: facts,
      preferences,
      conflicts: detectConflicts(facts),
      gaps: evidenceGaps(facts, query)
    };
  }

  private fromPassages(researchId: string, query: string): EvidenceItem[] {
    const terms = tokenize(query);
    const fts = this.searchFts(researchId, query);
    const all = this.options.store.listPassages(researchId);
    const byId = new Map(all.map((row) => [row.passageId, row]));
    for (const hit of fts) byId.set(hit.passageId, hit);
    const items: EvidenceItem[] = [];
    for (const passage of byId.values()) {
      const artifact = this.options.store.getArtifact(researchId, passage.artifactId);
      if (!artifact || artifact.status !== 'ready') continue;
      if (artifact.evidenceLevel === 'user_preference') continue;
      const score = Math.max(ftsScore(fts, passage.passageId), keywordScore(terms, passage.text));
      if (score <= 0) continue;
      items.push(toItem(artifact, passage, score));
    }
    return items;
  }

  private fromSharedFiles(researchId: string, query: string): EvidenceItem[] {
    const tools = this.options.fileToolsFor?.(researchId);
    if (!tools) return [];
    const terms = tokenize(query);
    const grants = this.options.store.listGrants(researchId);
    const items: EvidenceItem[] = [];
    for (const grant of grants) {
      if (grant.status && grant.status !== 'granted' && grant.status !== 'ready' && grant.status !== 'active') {
        continue;
      }
      let entries;
      try {
        entries = tools.listFiles(`shared://${grant.alias}`);
      } catch {
        continue;
      }
      for (const entry of entries) {
        if (entry.kind !== 'file') continue;
        let body;
        try {
          body = tools.readFile(entry.uri);
        } catch {
          continue;
        }
        const score = keywordScore(terms, `${entry.uri}\n${body.text}`);
        if (score <= 0) continue;
        const digest = createHash('sha256').update(body.text, 'utf8').digest('hex');
        const chunks = body.text.split(/\n{2,}/).map((part) => part.trim()).filter(Boolean);
        chunks.slice(0, 20).forEach((chunk, index) => {
          if (keywordScore(terms, chunk) <= 0 && index > 0) return;
          items.push({
            artifactId: null,
            sha256: digest,
            passageId: `shared-${grant.alias}-${index + 1}`,
            evidenceLevel: 'primary_content',
            kind: 'shared_file',
            excerpt: clipExcerpt(chunk),
            locator: { virtualUri: entry.uri, sourceURL: null, contentKey: null, startMs: null, endMs: null },
            score
          });
        });
      }
    }
    return items;
  }

  private async fromPreferences(researchId: string, query: string): Promise<EvidenceItem[]> {
    try {
      const hits = await recallMemory(this.options.store, { query, researchId });
      return hits
        .filter((hit) => hit.scope === 'global')
        .map((hit) => ({
          artifactId: null,
          sha256: createHash('sha256').update(hit.content, 'utf8').digest('hex'),
          passageId: hit.memoryEntryId,
          evidenceLevel: 'user_preference' as const,
          kind: 'global_memory',
          excerpt: clipExcerpt(hit.content),
          locator: { virtualUri: null, sourceURL: null, contentKey: null, startMs: null, endMs: null },
          score: hit.score
        }));
    } catch {
      return [];
    }
  }

  private searchFts(researchId: string, query: string): V2PassageRecord[] {
    const sanitized = tokenize(query).join(' ');
    if (!sanitized) return [];
    try {
      return this.options.store.searchPassages(researchId, sanitized, 40);
    } catch {
      return [];
    }
  }
}

function toItem(artifact: V2ArtifactRecord, passage: V2PassageRecord, score: number): EvidenceItem {
  const ref = (artifact.sourceReference ?? {}) as { sourceURL?: string | null; contentKey?: string | null };
  return {
    artifactId: artifact.artifactId,
    sha256: artifact.sha256,
    passageId: passage.passageId,
    evidenceLevel: artifact.evidenceLevel as EvidenceLevelName,
    kind: artifact.kind,
    excerpt: clipExcerpt(passage.text),
    locator: {
      sourceURL: ref.sourceURL ?? null,
      contentKey: ref.contentKey ?? null,
      startMs: passage.startMs,
      endMs: passage.endMs,
      virtualUri: null
    },
    score
  };
}

function tokenize(text: string): string[] {
  return text
    .normalize('NFC')
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((token) => token.length > 1);
}

function keywordScore(terms: string[], text: string): number {
  if (terms.length === 0) return 0;
  const hay = new Set(tokenize(text));
  const hits = terms.filter((term) => hay.has(term)).length;
  return hits / terms.length;
}

function ftsScore(hits: V2PassageRecord[], passageId: string): number {
  const index = hits.findIndex((hit) => hit.passageId === passageId);
  if (index < 0) return 0;
  return Math.max(0.2, 1 - index / 40);
}

function dedupe(items: EvidenceItem[]): EvidenceItem[] {
  const seen = new Set<string>();
  const out: EvidenceItem[] = [];
  for (const item of items) {
    const key = `${item.artifactId ?? item.locator.virtualUri ?? ''}:${item.passageId}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(item);
  }
  return out;
}

export { validateCitations, toCitationRecords } from './citations.js';
export type { EvidencePack, EvidenceItem, EvidenceGap, EvidenceConflict } from './pack.js';
