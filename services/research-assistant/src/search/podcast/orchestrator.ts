import { DomainError } from '../../domain/types.js';
import type { NormalizedSearchHit, ProviderStatus, SearchPlan } from '../contracts.js';
import { dedupeHits } from '../identity.js';
import { applyHardFilters, rankHits } from '../ranking.js';
import { PodcastIndexClient, PodcastIndexError } from './podcast-index-client.js';
import {
  episodesFromResponse,
  feedsFromResponse,
  normalizePodcastIndexEpisode,
  normalizePodcastIndexFeed
} from './podcast-index-normalize.js';
import { ApplePodcastSearchProvider } from './apple-search.js';
import { fetchRssEpisodes } from './rss.js';
import type { HttpGet } from '../http.js';

export interface PodcastSearchDeps {
  index: PodcastIndexClient | null;
  apple: ApplePodcastSearchProvider;
  rssFetch?: typeof fetchRssEpisodes;
  httpGet: HttpGet;
  enabled: boolean;
}

export interface PodcastSearchOutcome {
  hits: NormalizedSearchHit[];
  ranked: ReturnType<typeof rankHits>;
  providerStatus: ProviderStatus[];
  warnings: string[];
}

export class PodcastSearchOrchestrator {
  constructor(private readonly deps: PodcastSearchDeps) {}

  async search(plan: SearchPlan, limit: number): Promise<PodcastSearchOutcome> {
    const mode = plan.intent === 'person' ? 'person' : plan.intent === 'show' ? 'title' : plan.intent === 'recent' ? 'recent' : 'term';
    const query = plan.person || plan.showOrChannel || plan.queries[0] || '';
    const statuses: ProviderStatus[] = [];
    const warnings: string[] = [];
    let hits: NormalizedSearchHit[] = [];

    if (this.deps.enabled && this.deps.index) {
      try {
        hits = await this.fromIndex(mode, query, plan, limit);
        statuses.push({
          provider: 'podcastindex',
          status: hits.length ? 'success' : 'empty',
          rawCount: hits.length,
          acceptedCount: hits.length
        });
      } catch (error) {
        statuses.push(statusFromError('podcastindex', error));
        warnings.push(error instanceof DomainError ? error.code : 'PODCASTINDEX_UNAVAILABLE');
      }
    } else if (this.deps.enabled && !this.deps.index) {
      statuses.push({ provider: 'podcastindex', status: 'misconfigured', errorCode: 'PODCASTINDEX_NOT_CONFIGURED' });
      warnings.push('PODCASTINDEX_NOT_CONFIGURED');
    }

    if (hits.length === 0 || statuses.some((row) => row.provider === 'podcastindex' && row.status !== 'success')) {
      try {
        const appleHits = await this.appleHits(query, limit, plan.region);
        hits = dedupeHits([...hits, ...appleHits]);
        statuses.push({
          provider: 'apple_search',
          status: appleHits.length ? 'success' : 'empty',
          acceptedCount: appleHits.length
        });
      } catch (error) {
        statuses.push(statusFromError('apple_search', error));
        warnings.push(error instanceof DomainError ? error.code : 'APPLE_SEARCH_UNAVAILABLE');
      }
    } else {
      try {
        const appleHits = await this.appleHits(query, Math.min(5, limit), plan.region);
        hits = dedupeHits([...hits, ...appleHits]);
        statuses.push({ provider: 'apple_search', status: 'success', acceptedCount: appleHits.length });
      } catch {
        statuses.push({ provider: 'apple_search', status: 'unavailable' });
      }
    }

    const { accepted, filtered } = applyHardFilters(hits, plan);
    const ranked = rankHits(accepted, plan);
    if (filtered > 0 && ranked.every((hit) => !hit.qualified)) {
      warnings.push('SEARCH_FILTERED_EMPTY');
    }
    return { hits: accepted, ranked, providerStatus: statuses, warnings };
  }

  private async appleHits(query: string, limit: number, region?: string): Promise<NormalizedSearchHit[]> {
    const [shows, episodes] = await Promise.all([
      this.deps.apple.search(query, limit, region),
      this.deps.apple.searchEpisodes(query, limit, region)
    ]);
    return dedupeHits([...episodes, ...shows]);
  }

  async episodesForShow(show: NormalizedSearchHit, limit: number, plan: SearchPlan): Promise<NormalizedSearchHit[]> {
    void plan;
    if (this.deps.index && show.podcastIndexFeedId) {
      const payload = await this.deps.index.episodesByFeedId(show.podcastIndexFeedId, Math.min(10, limit));
      return episodesFromResponse(payload)
        .map((item, index) => normalizePodcastIndexEpisode(item, index + 1))
        .filter((item): item is NormalizedSearchHit => Boolean(item));
    }
    if (!show.feedURL) throw new DomainError('RSS_UNAVAILABLE', 'feed URL missing', true, 400);
    return (this.deps.rssFetch ?? fetchRssEpisodes)(show.feedURL, limit, this.deps.httpGet);
  }

  private async fromIndex(
    mode: 'person' | 'title' | 'term' | 'recent',
    query: string,
    plan: SearchPlan,
    limit: number
  ): Promise<NormalizedSearchHit[]> {
    const index = this.deps.index!;
    if (mode === 'person') {
      const payload = await index.searchByPerson(query, limit);
      return episodesFromResponse(payload)
        .map((item, i) => normalizePodcastIndexEpisode(item, i + 1))
        .filter((item): item is NormalizedSearchHit => Boolean(item));
    }
    if (mode === 'recent') {
      const payload = await index.recentEpisodes(limit, plan.language);
      return episodesFromResponse(payload)
        .map((item, i) => normalizePodcastIndexEpisode(item, i + 1))
        .filter((item): item is NormalizedSearchHit => Boolean(item));
    }
    const search = mode === 'title' ? index.searchByTitle(query, limit) : index.searchByTerm(query, limit);
    const payload = await search;
    const feeds = feedsFromResponse(payload)
      .map((item, i) => normalizePodcastIndexFeed(item, i + 1))
      .filter((item): item is NormalizedSearchHit => Boolean(item));
    if (mode === 'title') return feeds;
    const extras: NormalizedSearchHit[] = [];
    for (const feed of feeds.slice(0, 3)) {
      if (!feed.podcastIndexFeedId) continue;
      const episodes = await index.episodesByFeedId(feed.podcastIndexFeedId, 10);
      extras.push(
        ...episodesFromResponse(episodes)
          .map((item, i) => normalizePodcastIndexEpisode(item, i + 1))
          .filter((item): item is NormalizedSearchHit => Boolean(item))
      );
    }
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    const matched = extras.filter((episode) => {
      const blob = `${episode.title} ${episode.description ?? ''}`.toLowerCase();
      return terms.some((term) => blob.includes(term));
    });
    return matched.length
      ? [...feeds, ...matched]
      : feeds.map((feed) => ({
          ...feed,
          warnings: [...feed.warnings, 'no_episode_title_match']
        }));
  }
}

function statusFromError(provider: string, error: unknown): ProviderStatus {
  const code = error instanceof DomainError ? error.code : 'INTERNAL_ERROR';
  let status: ProviderStatus['status'] = 'unavailable';
  if (code.endsWith('NOT_CONFIGURED')) status = 'misconfigured';
  else if (code.includes('RATE_LIMIT')) status = 'rate_limited';
  else if (error instanceof PodcastIndexError && error.code === 'PODCASTINDEX_NOT_CONFIGURED') status = 'misconfigured';
  return { provider, status, errorCode: code };
}
