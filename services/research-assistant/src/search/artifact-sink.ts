import { newId, nowIso } from '../domain/ids.js';
import type { NormalizedSearchHit, ProviderStatus, SearchPlan } from './contracts.js';

export type SearchRunStatus = 'success' | 'empty' | 'failure' | 'partial';

export interface SearchRunResult {
  sourceId: string;
  title: string;
  canonicalURL: string;
  provider: string;
  publishedAt: string | null;
  assistantSourceId?: string;
  nativeSourceId?: string;
  sourceType?: string;
  feedURL?: string | null;
  enclosureUrl?: string | null;
}

export interface SearchRunDocument {
  schemaVersion: 1;
  runId: string;
  researchId: string;
  turnId: string | null;
  parentRunId: string | null;
  platform: 'youtube' | 'podcast';
  query: string;
  plan: SearchPlan;
  status: SearchRunStatus;
  startedAt: string;
  finishedAt: string;
  latencyMs: number;
  rawCount: number;
  acceptedCount: number;
  providerStatus: ProviderStatus[];
  results: SearchRunResult[];
  warnings: string[];
  error: { code: string } | null;
}

export interface SearchRunContext {
  researchId: string;
  turnId?: string | null;
  parentRunId?: string | null;
}

export interface SearchArtifactSink {
  persist(document: SearchRunDocument): { artifactId: string } | null;
}

export const noopSearchArtifactSink: SearchArtifactSink = {
  persist() {
    return null;
  }
};

export function queryFromPlan(plan: SearchPlan): string {
  return plan.queries[0] || plan.showOrChannel || '';
}

export function classifySearchRunStatus(hits: { length: number }, providerStatus: ProviderStatus[]): SearchRunStatus {
  const degraded = providerStatus.some((row) => row.status === 'unavailable' || row.status === 'rate_limited');
  if (degraded) return hits.length ? 'partial' : 'failure';
  return hits.length ? 'success' : 'empty';
}

export function buildSearchRunDocument(input: {
  context: SearchRunContext;
  platform: 'youtube' | 'podcast';
  plan: SearchPlan;
  hits: NormalizedSearchHit[];
  providerStatus: ProviderStatus[];
  warnings: string[];
  startedAt: string;
  startedMs: number;
}): SearchRunDocument {
  const status = classifySearchRunStatus(input.hits, input.providerStatus);
  const errorCode = input.providerStatus.find((row) => row.errorCode)?.errorCode;
  const rawCount = input.providerStatus.reduce((sum, row) => sum + (row.rawCount ?? 0), 0);
  return {
    schemaVersion: 1,
    runId: newId('srun'),
    researchId: input.context.researchId,
    turnId: input.context.turnId ?? null,
    parentRunId: input.context.parentRunId ?? null,
    platform: input.platform,
    query: queryFromPlan(input.plan),
    plan: input.plan,
    status,
    startedAt: input.startedAt,
    finishedAt: nowIso(),
    latencyMs: Date.now() - input.startedMs,
    rawCount: rawCount || input.hits.length,
    acceptedCount: input.hits.length,
    providerStatus: input.providerStatus.map((row) => ({
      provider: row.provider,
      status: row.status,
      ...(row.latencyMs != null ? { latencyMs: row.latencyMs } : {}),
      ...(row.cacheHit != null ? { cacheHit: row.cacheHit } : {}),
      ...(row.errorCode ? { errorCode: row.errorCode } : {}),
      ...(row.retryAfterSeconds != null ? { retryAfterSeconds: row.retryAfterSeconds } : {}),
      ...(row.rawCount != null ? { rawCount: row.rawCount } : {}),
      ...(row.acceptedCount != null ? { acceptedCount: row.acceptedCount } : {})
    })),
    results: input.hits.map((hit) => ({
      sourceId: hit.sourceId,
      title: hit.title,
      canonicalURL: hit.canonicalURL,
      provider: hit.provider,
      publishedAt: hit.publishedAt ?? null,
      sourceType: hit.sourceType,
      feedURL: hit.feedURL ?? null,
      enclosureUrl: hit.enclosureUrl ?? null
    })),
    warnings: [...input.warnings],
    error: status === 'success' || status === 'empty' ? null : { code: errorCode ?? (status === 'failure' ? 'SEARCH_FAILED' : 'SEARCH_PARTIAL') }
  };
}

export function redactSearchDocument(document: SearchRunDocument): SearchRunDocument {
  const copy = structuredClone(document);
  redactSecrets(copy);
  return copy;
}

function redactSecrets(value: unknown): void {
  if (!value || typeof value !== 'object') return;
  if (Array.isArray(value)) {
    for (const item of value) redactSecrets(item);
    return;
  }
  const record = value as Record<string, unknown>;
  for (const key of Object.keys(record)) {
    if (/key|secret|token|authorization|cookie|header/i.test(key)) {
      delete record[key];
      continue;
    }
    redactSecrets(record[key]);
  }
}
