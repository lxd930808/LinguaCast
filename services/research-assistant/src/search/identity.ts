import { createHash } from 'node:crypto';

import { DomainError } from '../domain/types.js';
import type { CanonicalPlatform, NormalizedSearchHit, SearchIntent, SearchPlan } from './contracts.js';

export const YOUTUBE_VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;

export function youtubeStableId(videoId: string): string {
  return `youtube:video:${videoId}`;
}

export function podcastFeedStableId(feedId?: number | null, feedURL?: string | null): string {
  if (feedId && Number.isFinite(feedId) && feedId > 0) return `podcastindex:feed:${feedId}`;
  if (feedURL) return `feedurl:${hashNormalizedUrl(feedURL)}`;
  throw new DomainError('INVALID_REQUEST', 'podcast show is missing feed identity', false, 400);
}

export function podcastEpisodeStableId(
  episodeId?: number | null,
  feedURL?: string | null,
  guid?: string | null
): string {
  if (episodeId && Number.isFinite(episodeId) && episodeId > 0) return `podcastindex:episode:${episodeId}`;
  if (feedURL && guid) return `episode:${hashNormalizedUrl(feedURL)}:${normalizeGuid(guid)}`;
  throw new DomainError('INVALID_REQUEST', 'podcast episode is missing identity', false, 400);
}

export function itunesAlias(itunesId: string | number | null | undefined): string | null {
  if (itunesId == null) return null;
  const digits = String(itunesId).replace(/\D/g, '');
  return digits ? `itunes:${digits}` : null;
}

export function normalizeGuid(value: string): string {
  return value.normalize('NFC').trim();
}

export function normalizeFeedUrl(raw: string): string {
  const url = new URL(raw);
  url.hash = '';
  url.hostname = url.hostname.toLowerCase();
  if (url.pathname.endsWith('/') && url.pathname.length > 1) {
    url.pathname = url.pathname.slice(0, -1);
  }
  for (const key of [...url.searchParams.keys()]) {
    if (/^utm_/i.test(key) || key === 'fbclid' || key === 'gclid') url.searchParams.delete(key);
  }
  return url.toString();
}

export function hashNormalizedUrl(raw: string): string {
  return createHash('sha256').update(normalizeFeedUrl(raw)).digest('hex').slice(0, 32);
}

export function assignStableIdentity(hit: NormalizedSearchHit): NormalizedSearchHit {
  const aliases = new Set(hit.aliases ?? []);
  let stableId = hit.stableId;
  if (hit.platform === 'youtube') {
    if (!YOUTUBE_VIDEO_ID.test(hit.sourceId)) {
      throw new DomainError('YTDLP_INVALID_OUTPUT', 'YouTube video id is not 11 characters', true, 400);
    }
    stableId = youtubeStableId(hit.sourceId);
  } else if (hit.sourceType === 'podcast_show') {
    stableId = podcastFeedStableId(hit.podcastIndexFeedId, hit.feedURL ?? hit.canonicalURL);
    const itunes = itunesAlias(hit.itunesId);
    if (itunes) aliases.add(itunes);
    if (hit.feedURL) aliases.add(`feedurl:${hashNormalizedUrl(hit.feedURL)}`);
  } else {
    stableId = podcastEpisodeStableId(hit.podcastIndexEpisodeId, hit.feedURL, hit.guid ?? hit.sourceId);
    if (hit.guid) aliases.add(`guid:${normalizeGuid(hit.guid)}`);
  }
  return { ...hit, stableId, aliases: [...aliases].sort() };
}

export function mergeHits(existing: NormalizedSearchHit, incoming: NormalizedSearchHit): NormalizedSearchHit {
  const priority = providerPriority(incoming.provider) - providerPriority(existing.provider);
  const winner = priority > 0 ? incoming : existing;
  const other = winner === incoming ? existing : incoming;
  const fieldProvenance: Record<string, string> = {
    ...(other.fieldProvenance ?? {}),
    ...(winner.fieldProvenance ?? {})
  };
  const merged: NormalizedSearchHit = { ...other, ...winner };
  for (const field of [
    'title',
    'publisher',
    'description',
    'canonicalURL',
    'feedURL',
    'thumbnailURL',
    'publishedAt',
    'durationSeconds',
    'enclosureUrl',
    'itunesId',
    'guid'
  ] as const) {
    const winnerHas = hasValue(winner[field]);
    const otherHas = hasValue(other[field]);
    if (winnerHas) {
      merged[field] = winner[field] as never;
      fieldProvenance[field] = winner.provider;
    } else if (otherHas) {
      merged[field] = other[field] as never;
      fieldProvenance[field] = other.provider;
    }
  }
  const warnings = [...new Set([...(existing.warnings ?? []), ...(incoming.warnings ?? [])])];
  if (existing.provider !== incoming.provider) warnings.push('merged_providers');
  return {
    ...merged,
    aliases: [...new Set([...(existing.aliases ?? []), ...(incoming.aliases ?? [])])].sort(),
    fieldProvenance,
    warnings,
    fallback: Boolean(existing.fallback || incoming.fallback)
  };
}

function hasValue(value: unknown): boolean {
  return value != null && value !== '';
}

function providerPriority(provider: string): number {
  switch (provider) {
    case 'podcastindex':
      return 30;
    case 'youtube_api':
      return 25;
    case 'ytdlp':
      return 20;
    case 'apple_search':
      return 10;
    case 'rss':
      return 5;
    default:
      return 0;
  }
}

export function identityKey(hit: NormalizedSearchHit): string {
  return hit.stableId ?? `${canonicalMedia(hit.platform)}:${hit.sourceType}:${hit.sourceId}`;
}

export function dedupeHits(hits: NormalizedSearchHit[]): NormalizedSearchHit[] {
  const byKey = new Map<string, NormalizedSearchHit>();
  const aliasToKey = new Map<string, string>();
  for (const hit of hits) {
    const primary = identityKey(hit);
    const aliases = [primary, ...(hit.aliases ?? [])];
    let existingKey: string | undefined;
    for (const alias of aliases) {
      existingKey = aliasToKey.get(alias);
      if (existingKey) break;
    }
    if (existingKey) {
      const merged = mergeHits(byKey.get(existingKey)!, hit);
      byKey.set(existingKey, merged);
      for (const alias of [identityKey(merged), ...(merged.aliases ?? [])]) {
        aliasToKey.set(alias, existingKey);
      }
    } else {
      byKey.set(primary, hit);
      for (const alias of aliases) aliasToKey.set(alias, primary);
    }
  }
  return [...byKey.values()];
}

export function canonicalMedia(platform: string): CanonicalPlatform {
  return platform === 'youtube' ? 'youtube' : 'podcast';
}

export function defaultPlan(partial: Partial<SearchPlan> & { queries: string[] }, now = new Date()): SearchPlan {
  return validateSearchPlan(partial, now);
}

export function validateSearchPlan(
  input: Partial<SearchPlan> & { queries?: string[] },
  now = new Date(),
  defaults: { language?: string; region?: string } = {}
): SearchPlan {
  const intent = (input.intent ?? 'topic') as SearchIntent;
  if (!['topic', 'person', 'show', 'channel', 'recent'].includes(intent)) {
    throw new DomainError('INVALID_REQUEST', 'intent is invalid', false, 400, { field: 'intent' });
  }
  const queries = (input.queries ?? []).map((query) => query.normalize('NFC').trim()).filter(Boolean);
  if (queries.length < 1 || queries.length > 3) {
    throw new DomainError('INVALID_REQUEST', 'queries must contain 1-3 items', false, 400, { field: 'queries' });
  }
  for (const query of queries) {
    if (query.length < 1 || query.length > 200) {
      throw new DomainError('INVALID_REQUEST', 'each query must be 1-200 characters', false, 400, { field: 'queries' });
    }
  }
  const media = (input.media?.length ? input.media : ['youtube', 'podcast']).filter(
    (item): item is 'youtube' | 'podcast' => item === 'youtube' || item === 'podcast'
  );
  if (!media.length) {
    throw new DomainError('INVALID_REQUEST', 'media must include youtube or podcast', false, 400, { field: 'media' });
  }
  return {
    intent,
    media: [...new Set(media)],
    queries,
    person: input.person?.normalize('NFC').trim() || null,
    showOrChannel: input.showOrChannel?.normalize('NFC').trim() || null,
    language: (input.language || defaults.language || 'en').slice(0, 16),
    region: (input.region || defaults.region || 'US').slice(0, 2).toUpperCase(),
    publishedAfter: absoluteTime(input.publishedAfter, now, intent),
    publishedBefore: absoluteTime(input.publishedBefore, now),
    duration: input.duration && input.duration !== 'any' ? input.duration : 'any',
    clean: input.clean !== false
  };
}

function absoluteTime(value: string | null | undefined, now: Date, intent?: SearchIntent): string | null {
  if (!value) {
    if (intent === 'recent') return new Date(now.getTime() - 180 * 24 * 3600 * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
    return null;
  }
  const relative = value.match(/^now-(\d+)([dmy])$/i);
  if (relative) {
    const amount = Number(relative[1]);
    const unit = relative[2].toLowerCase();
    const ms = unit === 'y' ? amount * 365 * 24 * 3600 * 1000 : unit === 'm' ? amount * 30 * 24 * 3600 * 1000 : amount * 24 * 3600 * 1000;
    return new Date(now.getTime() - ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
  }
  const parsed = Date.parse(value);
  if (Number.isNaN(parsed)) {
    throw new DomainError('INVALID_REQUEST', 'publishedAfter must be RFC3339 or now-Nd/Nm/Ny', false, 400, {
      field: 'publishedAfter'
    });
  }
  return new Date(parsed).toISOString().replace(/\.\d{3}Z$/, 'Z');
}
