export type SearchIntent = 'topic' | 'person' | 'show' | 'channel' | 'recent';
export type SearchMedia = 'youtube' | 'podcast';
export type CanonicalPlatform = 'youtube' | 'podcast';
export type WirePlatform = 'youtube' | 'podcast' | 'apple_podcasts';
export type SourceType = 'video' | 'podcast_show' | 'podcast_episode';
export type DurationFilter = 'short' | 'medium' | 'long' | 'any';
export type ProviderStatusCode =
  | 'success'
  | 'empty'
  | 'partial'
  | 'unavailable'
  | 'rate_limited'
  | 'misconfigured';

export const MATCH_REASONS = [
  'title_exact',
  'entity_exact',
  'title_term_coverage',
  'person_tag',
  'person_tag_and_episode_title',
  'description_term',
  'recent_window',
  'channel_or_show_match',
  'duration_match',
  'language_match',
  'provider_rank',
  'metadata_complete',
  'filter_best_effort',
  'unqualified'
] as const;

export type MatchReason = (typeof MATCH_REASONS)[number];

export interface SearchPlan {
  intent: SearchIntent;
  media: SearchMedia[];
  queries: string[];
  person: string | null;
  showOrChannel: string | null;
  language: string;
  region: string;
  publishedAfter: string | null;
  publishedBefore: string | null;
  duration: DurationFilter;
  clean: boolean;
}

export interface ProviderStatus {
  provider: string;
  status: ProviderStatusCode;
  latencyMs?: number;
  cacheHit?: boolean;
  errorCode?: string;
  retryAfterSeconds?: number;
  rawCount?: number;
  acceptedCount?: number;
}

export interface FieldProvenance {
  [field: string]: string;
}

export interface NormalizedSearchHit {
  platform: CanonicalPlatform | 'apple_podcasts';
  sourceType: SourceType;
  sourceId: string;
  stableId?: string;
  aliases?: string[];
  canonicalURL: string;
  feedURL?: string | null;
  title: string;
  publisher?: string | null;
  publishedAt?: string | null;
  durationSeconds?: number | null;
  description?: string | null;
  thumbnailURL?: string | null;
  availability?: string | null;
  provider: string;
  fallback?: boolean;
  provenance: Record<string, unknown>;
  fieldProvenance?: FieldProvenance;
  deepResearchAvailability: 'available' | 'unavailable';
  warnings: string[];
  channelId?: string | null;
  viewCount?: number | null;
  likeCount?: number | null;
  podcastIndexFeedId?: number | null;
  podcastIndexEpisodeId?: number | null;
  itunesId?: string | null;
  guid?: string | null;
  language?: string | null;
  explicit?: boolean | null;
  enclosureUrl?: string | null;
  enclosureType?: string | null;
  personTags?: string[];
  providerRank?: number;
  missingFields?: string[];
}

export interface RankedSearchHit extends NormalizedSearchHit {
  rank: number;
  relevanceScore: number;
  matchReason: MatchReason;
  qualified: boolean;
}

export interface SearchProvider {
  readonly name: string;
  search(query: string, limit: number, locale?: string): Promise<NormalizedSearchHit[]>;
}

export const SEARCH_SCHEMA_VERSION = 'v14.1';

export function isV14ClientVersion(version: string | undefined): boolean {
  if (!version) return false;
  return /v14|assistant-14|^14\./i.test(version);
}

export function projectPlatform(platform: string, clientVersion: string | undefined, searchV2: boolean): WirePlatform {
  if (platform === 'youtube') return 'youtube';
  if (searchV2 && isV14ClientVersion(clientVersion)) return 'podcast';
  return 'apple_podcasts';
}

export function canonicalPlatform(platform: string): CanonicalPlatform {
  return platform === 'youtube' ? 'youtube' : 'podcast';
}
