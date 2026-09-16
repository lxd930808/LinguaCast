import type { NormalizedSearchHit } from '../contracts.js';
import { assignStableIdentity } from '../identity.js';
import { normalizeHit } from '../normalize.js';

function num(value: unknown): number | null {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function str(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value : null;
}

export function normalizePodcastIndexFeed(item: Record<string, unknown>, providerRank: number): NormalizedSearchHit | null {
  const feedId = num(item.id ?? item.feedId);
  const feedURL = str(item.url ?? item.originalUrl);
  if (!feedId && !feedURL) return null;
  const itunesId = str(item.itunesId) ?? (num(item.itunesId) != null ? String(item.itunesId) : null);
  return normalizeHit(
    assignStableIdentity({
      platform: 'podcast',
      sourceType: 'podcast_show',
      sourceId: feedId ? `pi:feed:${feedId}` : feedURL!,
      canonicalURL: str(item.link) || str(item.itunesLink) || feedURL || `https://podcastindex.org/podcast/${feedId}`,
      feedURL,
      title: str(item.title) || `feed-${feedId}`,
      publisher: str(item.author) ?? str(item.ownerName),
      publishedAt: unixToIso(item.lastUpdateTime),
      description: str(item.description),
      thumbnailURL: str(item.artwork) ?? str(item.image),
      availability: item.dead || item.locked ? 'unavailable' : 'public',
      provider: 'podcastindex',
      fallback: false,
      provenance: { title: 'podcastindex', sourceId: 'podcastindex' },
      fieldProvenance: { title: 'podcastindex', feedURL: 'podcastindex' },
      deepResearchAvailability: 'unavailable',
      warnings: ['show_only_select_an_episode'],
      podcastIndexFeedId: feedId,
      itunesId,
      language: str(item.language),
      explicit: item.explicit === 1 || item.explicit === true,
      providerRank
    })
  );
}

export function normalizePodcastIndexEpisode(item: Record<string, unknown>, providerRank: number): NormalizedSearchHit | null {
  const episodeId = num(item.id);
  const feedURL = str(item.feedUrl);
  const guid = str(item.guid);
  if (!episodeId && !(feedURL && guid)) return null;
  const enclosure = str(item.enclosureUrl);
  return normalizeHit(
    assignStableIdentity({
      platform: 'podcast',
      sourceType: 'podcast_episode',
      sourceId: episodeId ? `pi:episode:${episodeId}` : guid!,
      canonicalURL: str(item.link) || str(item.episodeUrl) || enclosure || feedURL || '',
      feedURL,
      title: str(item.title) || guid || `episode-${episodeId}`,
      publisher: str(item.feedTitle) ?? str(item.author),
      publishedAt: unixToIso(item.datePublished),
      durationSeconds: num(item.duration),
      description: str(item.description),
      thumbnailURL: str(item.image) ?? str(item.feedImage),
      availability: 'public',
      provider: 'podcastindex',
      fallback: false,
      provenance: { title: 'podcastindex', sourceId: 'podcastindex' },
      fieldProvenance: { title: 'podcastindex' },
      deepResearchAvailability: enclosure ? 'available' : 'unavailable',
      warnings: enclosure ? [] : ['missing_enclosure'],
      podcastIndexFeedId: num(item.feedId),
      podcastIndexEpisodeId: episodeId,
      guid,
      language: str(item.feedLanguage),
      explicit: item.explicit === 1 || item.explicit === true,
      enclosureUrl: enclosure,
      enclosureType: str(item.enclosureType),
      personTags: Array.isArray(item.persons) ? (item.persons as Array<{ name?: string }>).map((p) => p.name).filter(Boolean) as string[] : [],
      providerRank
    })
  );
}

function unixToIso(value: unknown): string | null {
  const n = num(value);
  if (!n) return null;
  const ms = n > 10_000_000_000 ? n : n * 1000;
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

export function feedsFromResponse(payload: unknown): Record<string, unknown>[] {
  const record = payload as { feeds?: unknown; feed?: unknown };
  if (Array.isArray(record.feeds)) return record.feeds.filter((item) => item && typeof item === 'object') as Record<string, unknown>[];
  if (record.feed && typeof record.feed === 'object') return [record.feed as Record<string, unknown>];
  return [];
}

export function episodesFromResponse(payload: unknown): Record<string, unknown>[] {
  const record = payload as { items?: unknown; episodes?: unknown; episode?: unknown };
  if (Array.isArray(record.items)) return record.items.filter((item) => item && typeof item === 'object') as Record<string, unknown>[];
  if (Array.isArray(record.episodes)) return record.episodes.filter((item) => item && typeof item === 'object') as Record<string, unknown>[];
  if (record.episode && typeof record.episode === 'object') return [record.episode as Record<string, unknown>];
  return [];
}
