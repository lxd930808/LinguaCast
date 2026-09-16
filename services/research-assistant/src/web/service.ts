import { ArtifactWriter } from '../artifacts/writer.js';
import { nowIso } from '../domain/ids.js';
import { DomainError } from '../domain/types.js';
import { newArtifactId } from '../research-v2/state.js';
import { WebCache, webCacheKey } from './cache.js';
import { EXTRACTOR_VERSION, extractPage } from './extractor.js';
import { fetchAllowedPage, type PageFetch } from './fetch-client.js';
import { assertHttpUrl, assertPublicResolvedUrl, canonicalUrl, type DnsLookup } from './policy.js';
import type { WebHit, WebSearchProvider } from './search-client.js';

export interface WebSearchArtifact {
  schemaVersion: 1;
  runId: string;
  researchId: string;
  turnId: string | null;
  query: string;
  locale: string | null;
  provider: string;
  startedAt: string;
  finishedAt: string;
  latencyMs: number;
  cacheHit: boolean;
  status: 'success' | 'empty' | 'failure' | 'partial';
  results: Array<{ title: string; url: string; snippet: string; publishedAt: string | null; site: string; rank: number }>;
  error: { code: string } | null;
}

export interface WebResearchOptions {
  enabled: boolean;
  provider: WebSearchProvider | null;
  writer: ArtifactWriter;
  lookup: DnsLookup;
  fetchImpl: PageFetch;
  maxPageBytes: number;
  cache?: WebCache;
}

export class WebResearch {
  private readonly allowedByResearch = new Map<string, Set<string>>();
  private readonly cache: WebCache;

  constructor(private readonly options: WebResearchOptions) {
    this.cache = options.cache ?? new WebCache();
  }

  allowUserUrl(researchId: string, raw: string): string {
    const url = assertHttpUrl(raw);
    const canonical = canonicalUrl(url.toString());
    this.urlsFor(researchId).add(canonical);
    return canonical;
  }

  async search(input: {
    researchId: string;
    turnId?: string | null;
    query: string;
    locale?: string;
    limit?: number;
  }): Promise<{ artifactId: string; run: WebSearchArtifact }> {
    this.assertEnabled();
    const startedAt = nowIso();
    const startedMs = Date.now();
    const runId = newArtifactId();
    const providerName = this.options.provider?.name ?? 'unconfigured';
    const cacheKey = webCacheKey({
      kind: 'search',
      provider: providerName,
      urlOrQuery: `${input.query}|${input.locale ?? ''}`,
      extractor: EXTRACTOR_VERSION
    });
    const cached = this.cache.get<WebHit[]>(cacheKey);
    let hits: WebHit[] = [];
    let status: WebSearchArtifact['status'] = 'success';
    let error: { code: string } | null = null;
    let cacheHit = false;
    try {
      if (!this.options.provider) {
        throw new DomainError('WEB_SEARCH_FAILED', 'web search provider is not configured', true, 503);
      }
      if (cached) {
        hits = cached;
        cacheHit = true;
      } else {
        hits = await this.options.provider.search(input.query, { locale: input.locale, limit: input.limit ?? 5 });
        this.cache.set(cacheKey, hits, hits.length ? 30 * 60 * 1000 : 60 * 1000);
      }
      status = hits.length ? 'success' : 'empty';
    } catch (caught) {
      status = 'failure';
      error = { code: caught instanceof DomainError ? caught.code : 'WEB_SEARCH_FAILED' };
      this.cache.set(cacheKey, [], 60 * 1000);
    }
    for (const hit of hits) {
      try {
        this.urlsFor(input.researchId).add(canonicalUrl(hit.url));
      } catch {
        // skip unparseable provider URLs
      }
    }
    const run: WebSearchArtifact = {
      schemaVersion: 1,
      runId,
      researchId: input.researchId,
      turnId: input.turnId ?? null,
      query: input.query,
      locale: input.locale ?? null,
      provider: providerName,
      startedAt,
      finishedAt: nowIso(),
      latencyMs: Date.now() - startedMs,
      cacheHit,
      status,
      results: hits.map((hit, index) => ({
        title: hit.title,
        url: hit.url,
        snippet: hit.snippet,
        publishedAt: hit.publishedAt,
        site: hit.site,
        rank: index + 1
      })),
      error
    };
    redactSecrets(run);
    const saved = this.options.writer.save({
      kind: 'web_search',
      contents: `${JSON.stringify(run, null, 2)}\n`,
      producer: 'web_search',
      evidenceLevel: 'search_metadata'
    });
    if (status === 'failure') {
      throw new DomainError(error?.code ?? 'WEB_SEARCH_FAILED', 'configured provider failed; failure artifact is saved', true, 503);
    }
    return { artifactId: saved.artifactId, run };
  }

  async fetchPage(input: { researchId: string; url: string }): Promise<{ artifactId: string }> {
    this.assertEnabled();
    let canonical: string;
    try {
      canonical = canonicalUrl(input.url);
    } catch {
      throw new DomainError('WEB_URL_BLOCKED', 'URL is not valid', false, 400);
    }
    if (!this.urlsFor(input.researchId).has(canonical)) {
      throw new DomainError('WEB_URL_NOT_ALLOWED', 'URL is not a saved search result or a policy-passed user URL', false, 400);
    }
    await assertPublicResolvedUrl(input.url, this.options.lookup);
    const page = await fetchAllowedPage(input.url, {
      lookup: this.options.lookup,
      fetchImpl: this.options.fetchImpl,
      maxBytes: this.options.maxPageBytes
    });
    const extracted = extractPage({
      html: page.body.toString('utf8'),
      originalUrl: page.requestedUrl,
      finalUrl: page.finalUrl,
      mime: page.mime
    });
    const saved = this.options.writer.save({
      kind: 'web_page',
      contents: extracted.markdown,
      producer: 'fetch_web_page',
      evidenceLevel: 'primary_content',
      sourceURL: page.finalUrl
    });
    return { artifactId: saved.artifactId };
  }

  private assertEnabled(): void {
    if (!this.options.enabled) {
      throw new DomainError('WEB_DISABLED', 'web search and fetch are disabled', false, 503);
    }
  }

  private urlsFor(researchId: string): Set<string> {
    const existing = this.allowedByResearch.get(researchId);
    if (existing) return existing;
    const created = new Set<string>();
    this.allowedByResearch.set(researchId, created);
    return created;
  }
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
