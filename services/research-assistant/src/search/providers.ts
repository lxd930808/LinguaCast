import { DomainError } from '../domain/types.js';
import type { NormalizedSearchHit, SearchProvider } from './contracts.js';
import { defaultHttpGet, defaultProcessRunner, type HttpGet, type ProcessRunner } from './http.js';
import { YtDlpSearchProvider } from './youtube/ytdlp-discovery.js';
import { YouTubeDataApiProvider } from './youtube/data-api.js';
import { ApplePodcastSearchProvider } from './podcast/apple-search.js';
import { assertPublicHttpsUrl, fetchRssEpisodes } from './podcast/rss.js';

export type { NormalizedSearchHit, SearchProvider, HttpGet, ProcessRunner };
export {
  defaultHttpGet,
  defaultProcessRunner,
  YtDlpSearchProvider,
  YouTubeDataApiProvider,
  ApplePodcastSearchProvider,
  assertPublicHttpsUrl,
  fetchRssEpisodes
};

const SEARCH_CACHE_TTL_MS = 60_000;
const SEARCH_EMPTY_TTL_MS = 10_000;

export class CompositeSearchService {
  private readonly cache = new Map<string, { expiresAt: number; hits: NormalizedSearchHit[] }>();

  constructor(
    private readonly ytdlp: SearchProvider,
    private readonly youtubeApi: SearchProvider | null,
    private readonly apple: SearchProvider
  ) {}

  async searchYouTube(query: string, limit: number): Promise<NormalizedSearchHit[]> {
    const key = cacheKey('youtube', query, limit);
    const cached = this.readCache(key);
    if (cached) return cached;
    let hits: NormalizedSearchHit[] = [];
    try {
      hits = await this.ytdlp.search(query, limit);
      if (hits.length > 0) {
        this.writeCache(key, hits, SEARCH_CACHE_TTL_MS);
        return hits;
      }
    } catch (error) {
      if (!this.youtubeApi) throw error;
    }
    if (!this.youtubeApi) {
      throw new DomainError('YOUTUBE_SEARCH_UNAVAILABLE', 'yt-dlp returned no usable videos', true, 503);
    }
    hits = await this.youtubeApi.search(query, limit);
    this.writeCache(key, hits, hits.length ? SEARCH_CACHE_TTL_MS : SEARCH_EMPTY_TTL_MS);
    return hits;
  }

  async searchApple(query: string, limit: number, locale?: string): Promise<NormalizedSearchHit[]> {
    const key = cacheKey('apple', query, limit, locale);
    const cached = this.readCache(key);
    if (cached) return cached;
    const hits = await this.apple.search(query, limit, locale);
    this.writeCache(key, hits, hits.length ? SEARCH_CACHE_TTL_MS : SEARCH_EMPTY_TTL_MS);
    return hits;
  }

  private readCache(key: string): NormalizedSearchHit[] | null {
    const row = this.cache.get(key);
    if (!row) return null;
    if (row.expiresAt < Date.now()) {
      this.cache.delete(key);
      return null;
    }
    return row.hits;
  }

  private writeCache(key: string, hits: NormalizedSearchHit[], ttlMs: number): void {
    this.cache.set(key, { hits, expiresAt: Date.now() + ttlMs });
  }
}

function cacheKey(provider: string, query: string, limit: number, locale?: string): string {
  return `${provider}|${query.normalize('NFC').trim().toLowerCase()}|${limit}|${(locale ?? '').toLowerCase()}`;
}
