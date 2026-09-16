import { DomainError } from '../../domain/types.js';
import type { ServiceConfig } from '../../config/index.js';
import { defaultHttpGet, type HttpGet } from '../http.js';
import type { NormalizedSearchHit } from '../contracts.js';
import { assignStableIdentity } from '../identity.js';
import { normalizeHit } from '../normalize.js';

export class ApplePodcastSearchProvider {
  readonly name = 'apple_search';

  constructor(
    private readonly config: ServiceConfig,
    private readonly httpGet: HttpGet = defaultHttpGet
  ) {}

  async search(query: string, limit: number, locale?: string): Promise<NormalizedSearchHit[]> {
    const results = await this.itunesSearch(query, limit, locale, 'podcast');
    return results.flatMap((item, index) => {
      const collectionId = String(item.collectionId ?? '');
      if (!collectionId) return [];
      const feedURL = item.feedUrl ? String(item.feedUrl) : null;
      return [
        normalizeHit(
          assignStableIdentity({
            platform: 'podcast',
            sourceType: 'podcast_show',
            sourceId: collectionId,
            canonicalURL: String(item.collectionViewUrl ?? `https://podcasts.apple.com/podcast/id${collectionId}`),
            feedURL,
            title: String(item.collectionName ?? collectionId),
            publisher: item.artistName ? String(item.artistName) : null,
            publishedAt: null,
            durationSeconds: null,
            description: null,
            thumbnailURL: item.artworkUrl600 ? String(item.artworkUrl600) : null,
            availability: 'public',
            provider: 'apple_search',
            fallback: false,
            provenance: { title: 'apple_search', feedURL: feedURL ? 'apple_search' : 'missing' },
            fieldProvenance: { title: 'apple_search', canonicalURL: 'apple_search' },
            deepResearchAvailability: 'unavailable',
            warnings: feedURL ? ['show_only_select_an_episode'] : ['show_only_select_an_episode', 'missing_feed_url'],
            itunesId: collectionId,
            providerRank: index + 1
          })
        )
      ];
    });
  }

  /** iTunes `podcastEpisode` search — used when Podcast Index is off. */
  async searchEpisodes(query: string, limit: number, locale?: string): Promise<NormalizedSearchHit[]> {
    const results = await this.itunesSearch(query, limit, locale, 'podcastEpisode');
    const hits: NormalizedSearchHit[] = [];
    for (const [index, item] of results.entries()) {
      const trackId = String(item.trackId ?? '');
      const feedURL = item.feedUrl ? String(item.feedUrl) : null;
      if (!trackId || !feedURL) continue;
      const enclosure = item.episodeUrl ? String(item.episodeUrl) : item.previewUrl ? String(item.previewUrl) : null;
      const millis = Number(item.trackTimeMillis);
      try {
        hits.push(
          normalizeHit(
            assignStableIdentity({
              platform: 'podcast',
              sourceType: 'podcast_episode',
              sourceId: trackId,
              canonicalURL: String(
                item.trackViewUrl ?? item.collectionViewUrl ?? `https://podcasts.apple.com/podcast/id${item.collectionId}`
              ),
              feedURL,
              title: String(item.trackName ?? trackId),
              publisher: item.collectionName ? String(item.collectionName) : item.artistName ? String(item.artistName) : null,
              publishedAt: item.releaseDate ? String(item.releaseDate) : null,
              durationSeconds: Number.isFinite(millis) && millis > 0 ? Math.round(millis / 1000) : null,
              description: item.description ? String(item.description) : item.shortDescription ? String(item.shortDescription) : null,
              thumbnailURL: item.artworkUrl600 ? String(item.artworkUrl600) : null,
              availability: 'public',
              provider: 'apple_search',
              fallback: true,
              provenance: { title: 'apple_search', enclosureUrl: enclosure ? 'apple_search' : 'missing' },
              fieldProvenance: { title: 'apple_search', feedURL: 'apple_search' },
              deepResearchAvailability: enclosure ? 'available' : 'unavailable',
              warnings: enclosure ? [] : ['missing_enclosure'],
              itunesId: item.collectionId ? String(item.collectionId) : null,
              guid: trackId,
              enclosureUrl: enclosure,
              enclosureType: enclosure?.includes('.mp3') ? 'audio/mpeg' : null,
              providerRank: index + 1
            })
          )
        );
      } catch {
        continue;
      }
    }
    return hits;
  }

  private async itunesSearch(
    query: string,
    limit: number,
    locale: string | undefined,
    entity: 'podcast' | 'podcastEpisode'
  ): Promise<Array<Record<string, unknown>>> {
    const country = (locale || this.config.appleSearchCountry || 'US').slice(0, 2).toUpperCase();
    const url = new URL(`${this.config.appleSearchBaseUrl}/search`);
    url.searchParams.set('media', 'podcast');
    url.searchParams.set('entity', entity);
    url.searchParams.set('limit', String(Math.min(10, Math.max(1, limit))));
    url.searchParams.set('term', query.normalize('NFC').trim());
    url.searchParams.set('country', country);
    const response = await this.httpGet(url);
    if (response.status === 429) {
      throw new DomainError('APPLE_SEARCH_UNAVAILABLE', 'Apple Search rate limited', true, 429);
    }
    if (response.status >= 400) {
      throw new DomainError('APPLE_SEARCH_UNAVAILABLE', 'Apple Search failed', true, 503);
    }
    return ((response.json as { results?: Array<Record<string, unknown>> })?.results ?? []).slice(0, 10);
  }
}
