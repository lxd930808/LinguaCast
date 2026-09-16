import type { NormalizedSearchHit } from '../contracts.js';
import type { YouTubeDataApiProvider } from './data-api.js';
import type { YtDlpSearchProvider } from './ytdlp-discovery.js';

const ISO_DURATION = /PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/;

export async function hydrateYouTubeHits(
  hits: NormalizedSearchHit[],
  options: {
    api: YouTubeDataApiProvider | null;
    ytdlp: YtDlpSearchProvider;
    hydrationEnabled: boolean;
    hasApiKey: boolean;
    signal?: AbortSignal;
  }
): Promise<NormalizedSearchHit[]> {
  if (!options.hydrationEnabled || hits.length === 0) return hits;
  const ids = hits.slice(0, 10).map((hit) => hit.sourceId);
  if (options.hasApiKey && options.api) {
    const details = await options.api.videosList(ids);
    return hits.map((hit) => applyVideoDetails(hit, details.get(hit.sourceId)));
  }
  const top = hits.slice(0, 5);
  const rest = hits.slice(5);
  const hydrated: NormalizedSearchHit[] = [];
  const workers = 3;
  let cursor = 0;
  await Promise.all(
    Array.from({ length: Math.min(workers, top.length) }, async () => {
      while (cursor < top.length) {
        if (options.signal?.aborted) break;
        const index = cursor;
        cursor += 1;
        const hit = top[index]!;
        const detail = await options.ytdlp.details(hit.sourceId);
        hydrated[index] = detail ? { ...hit, ...pickDetails(detail), warnings: mergeWarning(hit.warnings, detail) } : withPartial(hit);
      }
    })
  );
  return [...hydrated.filter(Boolean), ...rest.map((hit) => withPartial(hit, false))];
}

function applyVideoDetails(hit: NormalizedSearchHit, item: Record<string, unknown> | undefined): NormalizedSearchHit {
  if (!item) return withPartial(hit);
  const snippet = (item.snippet ?? {}) as Record<string, unknown>;
  const stats = (item.statistics ?? {}) as Record<string, unknown>;
  const content = (item.contentDetails ?? {}) as Record<string, unknown>;
  const status = (item.status ?? {}) as Record<string, unknown>;
  if (status.privacyStatus === 'private' || status.uploadStatus === 'rejected') {
    return { ...hit, availability: 'unavailable', deepResearchAvailability: 'unavailable', warnings: mergeWarning(hit.warnings, { warnings: ['unplayable'] }) };
  }
  return {
    ...hit,
    title: snippet.title ? String(snippet.title) : hit.title,
    publisher: snippet.channelTitle ? String(snippet.channelTitle) : hit.publisher,
    publishedAt: snippet.publishedAt ? String(snippet.publishedAt) : hit.publishedAt,
    description: snippet.description ? String(snippet.description).slice(0, 2000) : hit.description,
    durationSeconds: parseIsoDuration(String(content.duration ?? '')) ?? hit.durationSeconds,
    viewCount: stats.viewCount != null ? Number(stats.viewCount) : hit.viewCount,
    likeCount: stats.likeCount != null ? Number(stats.likeCount) : hit.likeCount,
    channelId: snippet.channelId ? String(snippet.channelId) : hit.channelId,
    fieldProvenance: { ...(hit.fieldProvenance ?? {}), durationSeconds: 'youtube_api', publishedAt: 'youtube_api' }
  };
}

function pickDetails(detail: NormalizedSearchHit): Partial<NormalizedSearchHit> {
  return {
    durationSeconds: detail.durationSeconds ?? undefined,
    publishedAt: detail.publishedAt ?? undefined,
    description: detail.description ?? undefined,
    viewCount: detail.viewCount ?? undefined,
    channelId: detail.channelId ?? undefined
  };
}

function withPartial(hit: NormalizedSearchHit, mark = true): NormalizedSearchHit {
  if (!mark) return hit;
  return { ...hit, warnings: [...new Set([...hit.warnings, 'metadata_partial'])] };
}

function mergeWarning(existing: string[], extra: { warnings?: string[] }): string[] {
  return [...new Set([...existing, ...(extra.warnings ?? [])])];
}

function parseIsoDuration(value: string): number | null {
  const match = value.match(ISO_DURATION);
  if (!match) return null;
  const hours = Number(match[1] ?? 0);
  const minutes = Number(match[2] ?? 0);
  const seconds = Number(match[3] ?? 0);
  return hours * 3600 + minutes * 60 + seconds;
}
