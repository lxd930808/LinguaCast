import type { V2Store } from '../db/v2/store.js';
import { DomainError } from '../domain/types.js';
import {
  GLOBAL_RECALL_CHAR_BUDGET,
  RESEARCH_RECALL_CHAR_BUDGET,
  type MemoryRecallHit
} from './types.js';

export interface QmdAdapter {
  search(
    query: string,
    corpus: Array<{ memoryEntryId: string; text: string }>
  ): Promise<Array<{ memoryEntryId: string; score: number }>>;
}

export interface RecallOptions {
  query: string;
  researchId: string;
  qmd?: QmdAdapter | null;
  researchBudget?: number;
  globalBudget?: number;
}

export async function recallMemory(store: V2Store, options: RecallOptions): Promise<MemoryRecallHit[]> {
  const owning = store.getResearch(options.researchId);
  if (!owning) {
    throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
  }
  const query = options.query.normalize('NFC').trim();
  if (!query) return [];
  const researchBudget = options.researchBudget ?? RESEARCH_RECALL_CHAR_BUDGET;
  const globalBudget = options.globalBudget ?? GLOBAL_RECALL_CHAR_BUDGET;
  const research = store.listMemoryEntries(options.researchId).filter((entry) => entry.status === 'active');
  const global = store.listConfirmedGlobalMemory(owning.ownerScope);
  const corpus = [
    ...research.map((entry) => ({
      memoryEntryId: entry.memoryEntryId,
      scope: 'research' as const,
      content: entry.content,
      hypothesis: entry.hypothesis
    })),
    ...global.map((entry) => ({
      memoryEntryId: entry.memoryEntryId,
      scope: 'global' as const,
      content: entry.content,
      hypothesis: entry.hypothesis
    }))
  ];

  let mode: MemoryRecallHit['mode'] = 'keyword';
  let scored: Array<{ memoryEntryId: string; score: number }> = keywordScore(query, corpus);
  if (options.qmd) {
    try {
      scored = await options.qmd.search(
        query,
        corpus.map((item) => ({ memoryEntryId: item.memoryEntryId, text: item.content }))
      );
      mode = 'qmd';
    } catch {
      mode = 'keyword';
      scored = keywordScore(query, corpus);
    }
  }
  if (mode === 'keyword') {
    try {
      const fts = store.searchPassages(options.researchId, sanitizeFts(query));
      if (fts.length > 0) {
        const byId = new Map(scored.map((row) => [row.memoryEntryId, row.score]));
        for (const passage of fts) {
          const match = research.find((entry) => entry.content.includes(passage.text.slice(0, 80)) || passage.text.includes(entry.content.slice(0, 80)));
          if (!match) continue;
          byId.set(match.memoryEntryId, Math.max(byId.get(match.memoryEntryId) ?? 0, 0.6));
        }
        if ([...byId.values()].some((score) => score >= 0.6)) mode = 'fts';
        scored = [...byId.entries()].map(([memoryEntryId, score]) => ({ memoryEntryId, score }));
      }
    } catch {
      // FTS syntax or missing table is not fatal; keyword hits remain
    }
  }

  const lookup = new Map(corpus.map((item) => [item.memoryEntryId, item]));
  const ranked = scored
    .map((row) => {
      const item = lookup.get(row.memoryEntryId);
      if (!item) return null;
      return { ...item, mode, score: row.score };
    })
    .filter((row): row is MemoryRecallHit => row != null && row.score > 0)
    .sort((left, right) => right.score - left.score);

  return budget(ranked, researchBudget, globalBudget);
}

function keywordScore(
  query: string,
  corpus: Array<{ memoryEntryId: string; content: string }>
): Array<{ memoryEntryId: string; score: number }> {
  const terms = tokenize(query);
  if (terms.length === 0) return [];
  return corpus.map((item) => {
    const hay = new Set(tokenize(item.content));
    const hits = terms.filter((term) => hay.has(term)).length;
    return { memoryEntryId: item.memoryEntryId, score: hits / terms.length };
  });
}

function tokenize(text: string): string[] {
  return text
    .normalize('NFC')
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((token) => token.length > 1);
}

function sanitizeFts(query: string): string {
  return tokenize(query).join(' ');
}

function budget(hits: MemoryRecallHit[], researchBudget: number, globalBudget: number): MemoryRecallHit[] {
  const out: MemoryRecallHit[] = [];
  let researchUsed = 0;
  let globalUsed = 0;
  for (const hit of hits) {
    const cap = hit.scope === 'global' ? globalBudget : researchBudget;
    const used = hit.scope === 'global' ? globalUsed : researchUsed;
    if (used >= cap) continue;
    const remaining = cap - used;
    const content = hit.content.slice(0, remaining);
    if (hit.scope === 'global') globalUsed += content.length;
    else researchUsed += content.length;
    out.push({ ...hit, content });
  }
  return out;
}
