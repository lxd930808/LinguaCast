import type { ServiceConfig } from '../../config/index.js';
import { DomainError } from '../../domain/types.js';
import type { NormalizedSearchHit, SearchPlan } from '../contracts.js';
import { defaultHttpGet, type HttpGet } from '../http.js';
import { assignStableIdentity } from '../identity.js';
import { normalizeHit } from '../normalize.js';

export function needsOfficialFilters(plan?: SearchPlan): boolean {
  if (!plan) return false;
  return Boolean(
    plan.publishedAfter ||
      (plan.duration && plan.duration !== 'any') ||
      plan.intent === 'recent'
  );
}

export class YouTubeDataApiProvider {
  readonly name = 'youtube_api';

  constructor(
    private readonly config: ServiceConfig,
    private readonly httpGet: HttpGet = defaultHttpGet
  ) {}

  async search(query: string, limit: number): Promise<NormalizedSearchHit[]> {
    return this.searchWithPlan(query, limit);
  }

  async searchWithPlan(query: string, limit: number, plan?: SearchPlan): Promise<NormalizedSearchHit[]> {
    if (!this.config.youtubeApiKey) {
      throw new DomainError('YOUTUBE_SEARCH_UNAVAILABLE', 'YouTube Data API key is not configured', true, 503);
    }
    const url = new URL(`${this.config.youtubeApiBaseUrl}/search`);
    url.searchParams.set('part', 'snippet');
    url.searchParams.set('type', 'video');
    url.searchParams.set('maxResults', String(Math.min(10, Math.max(1, limit))));
    url.searchParams.set('q', query.normalize('NFC').trim());
    url.searchParams.set('key', this.config.youtubeApiKey);
    if (plan?.publishedAfter) url.searchParams.set('publishedAfter', plan.publishedAfter);
    if (plan?.region) url.searchParams.set('regionCode', plan.region.slice(0, 2));
    if (plan?.language) url.searchParams.set('relevanceLanguage', plan.language.slice(0, 2));
    if (plan?.duration && plan.duration !== 'any') {
      url.searchParams.set('videoDuration', plan.duration === 'short' ? 'short' : plan.duration === 'long' ? 'long' : 'medium');
    }
    if (plan?.intent === 'recent') url.searchParams.set('order', 'date');
    const response = await this.httpGet(url);
    if (response.status === 429 || response.status === 403) {
      throw new DomainError('YOUTUBE_QUOTA_EXCEEDED', 'YouTube API quota exceeded', true, 429, {
        retryAfterSeconds: response.retryAfterSeconds ?? 60
      });
    }
    if (response.status >= 400) {
      throw new DomainError('YOUTUBE_SEARCH_UNAVAILABLE', 'YouTube API search failed', true, 503);
    }
    const items = ((response.json as { items?: Array<Record<string, unknown>> })?.items ?? []).filter(
      (item) => typeof (item.id as { videoId?: string } | undefined)?.videoId === 'string'
    );
    const nextPageToken = (response.json as { nextPageToken?: string })?.nextPageToken;
    return items.map((item, index) => {
      const videoId = String((item.id as { videoId: string }).videoId);
      const snippet = (item.snippet ?? {}) as Record<string, unknown>;
      const thumbs = snippet.thumbnails as Record<string, { url?: string }> | undefined;
      return normalizeHit(
        assignStableIdentity({
          platform: 'youtube',
          sourceType: 'video',
          sourceId: videoId,
          canonicalURL: `https://www.youtube.com/watch?v=${videoId}`,
          title: String(snippet.title ?? videoId),
          publisher: snippet.channelTitle ? String(snippet.channelTitle) : null,
          publishedAt: snippet.publishedAt ? String(snippet.publishedAt) : null,
          durationSeconds: null,
          description: snippet.description ? String(snippet.description).slice(0, 2000) : null,
          thumbnailURL: thumbs?.high?.url ?? thumbs?.default?.url ?? null,
          availability: 'public',
          provider: 'youtube_api',
          fallback: true,
          provenance: { title: 'youtube_api', nextPageToken: nextPageToken ?? null },
          fieldProvenance: { title: 'youtube_api' },
          deepResearchAvailability: 'available',
          warnings: ['youtube_search_used_data_api'],
          channelId: snippet.channelId ? String(snippet.channelId) : null,
          providerRank: index + 1
        })
      );
    });
  }

  async videosList(ids: string[]): Promise<Map<string, Record<string, unknown>>> {
    const map = new Map<string, Record<string, unknown>>();
    if (!this.config.youtubeApiKey || ids.length === 0) return map;
    const url = new URL(`${this.config.youtubeApiBaseUrl}/videos`);
    url.searchParams.set('part', 'contentDetails,snippet,statistics,status');
    url.searchParams.set('id', ids.slice(0, 10).join(','));
    url.searchParams.set('key', this.config.youtubeApiKey);
    const response = await this.httpGet(url);
    if (response.status >= 400) return map;
    for (const item of ((response.json as { items?: Array<Record<string, unknown>> })?.items ?? [])) {
      const id = String(item.id ?? '');
      if (id) map.set(id, item);
    }
    return map;
  }
}
