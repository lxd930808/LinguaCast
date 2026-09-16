import { nowIso } from '../domain/ids.js';
import { DomainError } from '../domain/types.js';
import type { NormalizedSearchHit, ProviderStatus, RankedSearchHit, SearchPlan } from './contracts.js';
import { dedupeHits } from './identity.js';
import { clipDescriptionForModel, boundToolPayload } from './normalize.js';
import { applyHardFilters, rankHits } from './ranking.js';
import type { SearchCache } from './cache.js';
import { cacheKey, ttlForStatus } from './cache.js';
import type { PodcastSearchOrchestrator } from './podcast/orchestrator.js';
import { YtDlpSearchProvider } from './youtube/ytdlp-discovery.js';
import { needsOfficialFilters, YouTubeDataApiProvider } from './youtube/data-api.js';
import { hydrateYouTubeHits } from './youtube/hydrator.js';
import {
  buildSearchRunDocument,
  type SearchArtifactSink,
  type SearchRunContext
} from './artifact-sink.js';

export interface SearchOrchestratorDeps {
  youtube: YtDlpSearchProvider;
  youtubeApi: YouTubeDataApiProvider | null;
  podcast: PodcastSearchOrchestrator | null;
  cache: SearchCache;
  searchV2: boolean;
  hydrationEnabled: boolean;
  successTtlMs: number;
  emptyTtlMs: number;
  artifactSink?: SearchArtifactSink;
}

export interface AggregateSearchOutcome {
  hits: RankedSearchHit[];
  providerStatus: ProviderStatus[];
  warnings: string[];
  nextCursor: string | null;
}

export class SearchOrchestrator {
  constructor(private readonly deps: SearchOrchestratorDeps) {}

  async search(
    plan: SearchPlan,
    limit: number,
    signal?: AbortSignal,
    context?: SearchRunContext
  ): Promise<AggregateSearchOutcome> {
    const statuses: ProviderStatus[] = [];
    const warnings: string[] = [];
    const buckets: NormalizedSearchHit[] = [];
    const tasks: Array<Promise<void>> = [];
    if (plan.media.includes('youtube')) {
      tasks.push(
        (async () => {
          const startedAt = nowIso();
          const startedMs = Date.now();
          const part = await this.searchYouTube(plan, limit, signal);
          this.persistPlatformRun({
            platform: 'youtube',
            plan,
            hits: part.hits,
            providerStatus: part.providerStatus,
            warnings: part.warnings,
            startedAt,
            startedMs,
            context
          });
          buckets.push(...part.hits);
          statuses.push(...part.providerStatus);
          warnings.push(...part.warnings);
        })()
      );
    }
    if (plan.media.includes('podcast') && this.deps.podcast) {
      tasks.push(
        (async () => {
          const startedAt = nowIso();
          const startedMs = Date.now();
          const part = await this.deps.podcast!.search(plan, limit);
          this.persistPlatformRun({
            platform: 'podcast',
            plan,
            hits: part.hits,
            providerStatus: part.providerStatus,
            warnings: part.warnings,
            startedAt,
            startedMs,
            context
          });
          buckets.push(...part.hits);
          statuses.push(...part.providerStatus);
          warnings.push(...part.warnings);
        })()
      );
    }
    await Promise.all(tasks);
    const merged = dedupeHits(buckets);
    const { accepted, filtered } = applyHardFilters(merged, plan);
    const ranked = rankHits(accepted, plan);
    if (filtered > 0 && ranked.filter((hit) => hit.qualified).length === 0) {
      warnings.push('SEARCH_FILTERED_EMPTY');
    }
    return { hits: ranked, providerStatus: statuses, warnings, nextCursor: null };
  }

  async searchYouTube(plan: SearchPlan, limit: number, signal?: AbortSignal): Promise<{
    hits: NormalizedSearchHit[];
    providerStatus: ProviderStatus[];
    warnings: string[];
  }> {
    const query = plan.showOrChannel || plan.queries[0] || '';
    const key = cacheKey({
      provider: 'youtube',
      query,
      intent: plan.intent,
      publishedAfter: plan.publishedAfter,
      duration: plan.duration,
      region: plan.region,
      language: plan.language,
      limit
    });
    const cached = this.deps.cache.get<{ hits: NormalizedSearchHit[]; status: string }>(key);
    if (cached) {
      return {
        hits: cached.hits,
        providerStatus: [{ provider: 'ytdlp', status: cached.hits.length ? 'success' : 'empty', cacheHit: true }],
        warnings: []
      };
    }
    const warnings: string[] = [];
    const statuses: ProviderStatus[] = [];
    let hits: NormalizedSearchHit[] = [];
    const official = needsOfficialFilters(plan) && Boolean(this.deps.youtubeApi);
    try {
      if (official && this.deps.youtubeApi) {
        hits = await this.deps.youtubeApi.searchWithPlan(query, limit, plan);
        statuses.push({ provider: 'youtube_api', status: hits.length ? 'success' : 'empty', acceptedCount: hits.length });
      } else {
        hits = await this.deps.youtube.discover({ query, limit, plan });
        statuses.push({ provider: 'ytdlp', status: hits.length ? 'success' : 'empty', acceptedCount: hits.length });
        if (needsOfficialFilters(plan) && !this.deps.youtubeApi) {
          warnings.push('filter_best_effort');
          warnings.push('YOUTUBE_FILTER_UNSUPPORTED');
        }
      }
    } catch (error) {
      statuses.push({
        provider: official ? 'youtube_api' : 'ytdlp',
        status: error instanceof DomainError && error.code === 'YOUTUBE_QUOTA_EXCEEDED' ? 'rate_limited' : 'unavailable',
        errorCode: error instanceof DomainError ? error.code : 'YOUTUBE_SEARCH_UNAVAILABLE'
      });
      if (official) {
        try {
          hits = await this.deps.youtube.discover({ query, limit, plan });
          statuses.push({ provider: 'ytdlp', status: hits.length ? 'success' : 'empty', acceptedCount: hits.length });
        } catch (fallbackError) {
          statuses.push({
            provider: 'ytdlp',
            status: 'unavailable',
            errorCode: fallbackError instanceof DomainError ? fallbackError.code : 'YTDLP_INVALID_OUTPUT'
          });
        }
      }
    }
    if (hits.length) {
      hits = await hydrateYouTubeHits(hits, {
        api: this.deps.youtubeApi,
        ytdlp: this.deps.youtube,
        hydrationEnabled: this.deps.hydrationEnabled,
        hasApiKey: Boolean(this.deps.youtubeApi),
        signal
      });
    }
    const ttl = ttlForStatus(hits.length ? 'success' : 'empty', this.deps.successTtlMs, this.deps.emptyTtlMs);
    if (ttl && !statuses.some((row) => row.status === 'unavailable' || row.status === 'rate_limited')) {
      this.deps.cache.set(key, 'youtube', { hits, status: hits.length ? 'success' : 'empty' }, ttl);
    }
    return { hits, providerStatus: statuses, warnings };
  }

  async hydrateHits(hits: NormalizedSearchHit[], signal?: AbortSignal): Promise<NormalizedSearchHit[]> {
    return hydrateYouTubeHits(hits, {
      api: this.deps.youtubeApi,
      ytdlp: this.deps.youtube,
      hydrationEnabled: this.deps.hydrationEnabled,
      hasApiKey: Boolean(this.deps.youtubeApi),
      signal
    });
  }

  async podcastEpisodes(show: NormalizedSearchHit, limit: number, plan: SearchPlan): Promise<NormalizedSearchHit[]> {
    if (!this.deps.podcast) {
      throw new DomainError('RSS_UNAVAILABLE', 'podcast search is not configured', true, 503);
    }
    return this.deps.podcast.episodesForShow(show, limit, plan);
  }

  private persistPlatformRun(input: {
    platform: 'youtube' | 'podcast';
    plan: SearchPlan;
    hits: NormalizedSearchHit[];
    providerStatus: ProviderStatus[];
    warnings: string[];
    startedAt: string;
    startedMs: number;
    context?: SearchRunContext;
  }): void {
    const sink = this.deps.artifactSink;
    if (!sink || !input.context) return;
    sink.persist(
      buildSearchRunDocument({
        context: input.context,
        platform: input.platform,
        plan: input.plan,
        hits: input.hits,
        providerStatus: input.providerStatus,
        warnings: input.warnings,
        startedAt: input.startedAt,
        startedMs: input.startedMs
      })
    );
  }
}

export function toolSearchResponse(input: {
  searchRunId: string;
  plan: SearchPlan;
  ranked: RankedSearchHit[];
  providerStatus: ProviderStatus[];
  warnings: string[];
}): unknown {
  const results = input.ranked.slice(0, 10).map((hit) => ({
    searchResultId: (hit as RankedSearchHit & { searchResultId?: string }).searchResultId,
    rank: hit.rank,
    relevanceScore: hit.relevanceScore,
    matchReason: hit.matchReason,
    platform: hit.platform === 'apple_podcasts' ? 'podcast' : hit.platform,
    sourceType: hit.sourceType,
    sourceId: hit.sourceId,
    title: hit.title,
    publisher: hit.publisher,
    publishedAt: hit.publishedAt,
    durationSeconds: hit.durationSeconds,
    description: clipDescriptionForModel(hit.description),
    canonicalURL: hit.canonicalURL,
    deepResearchAvailability: hit.deepResearchAvailability,
    provider: hit.provider,
    warnings: hit.warnings,
    qualified: hit.qualified
  }));
  return boundToolPayload({
    searchRunId: input.searchRunId,
    providerStatus: input.providerStatus,
    query: input.plan.queries[0],
    intent: input.plan.intent,
    results,
    nextCursor: null,
    warnings: input.warnings
  });
}
