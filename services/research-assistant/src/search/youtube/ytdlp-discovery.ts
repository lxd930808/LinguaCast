import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';

import type { ServiceConfig } from '../../config/index.js';
import { DomainError } from '../../domain/types.js';
import type { NormalizedSearchHit, SearchPlan } from '../contracts.js';
import { YOUTUBE_VIDEO_ID, assignStableIdentity } from '../identity.js';
import { normalizeHit } from '../normalize.js';
import { defaultProcessRunner, type ProcessRunner } from '../http.js';

export { defaultProcessRunner, type ProcessRunner };

export class YtDlpSearchProvider {
  readonly name = 'ytdlp';

  constructor(
    private readonly config: ServiceConfig,
    private readonly runner: ProcessRunner = defaultProcessRunner
  ) {}

  async search(query: string, limit: number, _locale?: string): Promise<NormalizedSearchHit[]> {
    return this.discover({ query, limit });
  }

  async discover(input: { query: string; limit: number; plan?: SearchPlan }): Promise<NormalizedSearchHit[]> {
    const normalized = input.query.normalize('NFC').trim();
    if (normalized.length < 1 || normalized.length > 200) {
      throw new DomainError('INVALID_REQUEST', 'query must be 1-200 characters', false, 400, { field: 'query' });
    }
    const capped = Math.min(10, Math.max(1, input.limit));
    mkdirSync(this.config.tempRoot, { recursive: true });
    const cwd = mkdtempSync(join(this.config.tempRoot, 'ytdlp-'));
    try {
      const args = [
        '--ignore-config',
        '--skip-download',
        '--flat-playlist',
        '--dump-single-json',
        '--no-warnings',
        '--no-call-home',
        `ytsearch${capped}:${normalized}`
      ];
      const result = await this.runner.run(this.config.ytdlpPath, args, {
        cwd,
        timeoutMs: this.config.ytdlpTimeoutMs,
        stdoutMax: this.config.ytdlpStdoutMaxBytes,
        stderrMax: this.config.ytdlpStderrMaxBytes
      });
      if (result.code !== 0) {
        throw new DomainError('YTDLP_INVALID_OUTPUT', 'yt-dlp exited unsuccessfully', true, 503);
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(result.stdout);
      } catch {
        throw new DomainError('YTDLP_INVALID_OUTPUT', 'yt-dlp JSON was not parseable', true, 503);
      }
      return normalizeFlatYtDlp(parsed);
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  }

  async details(videoId: string): Promise<NormalizedSearchHit | null> {
    if (!YOUTUBE_VIDEO_ID.test(videoId)) return null;
    mkdirSync(this.config.tempRoot, { recursive: true });
    const cwd = mkdtempSync(join(this.config.tempRoot, 'ytdlp-d-'));
    try {
      const args = [
        '--ignore-config',
        '--skip-download',
        '--dump-single-json',
        '--no-warnings',
        '--no-call-home',
        `https://www.youtube.com/watch?v=${videoId}`
      ];
      const result = await this.runner.run(this.config.ytdlpPath, args, {
        cwd,
        timeoutMs: Math.min(10_000, this.config.ytdlpTimeoutMs),
        stdoutMax: this.config.ytdlpStdoutMaxBytes,
        stderrMax: this.config.ytdlpStderrMaxBytes
      });
      if (result.code !== 0) return null;
      const parsed = JSON.parse(result.stdout) as unknown;
      return normalizeFlatYtDlp(parsed)[0] ?? null;
    } catch {
      return null;
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  }
}

export function normalizeFlatYtDlp(parsed: unknown): NormalizedSearchHit[] {
  const entries = Array.isArray((parsed as { entries?: unknown[] })?.entries)
    ? ((parsed as { entries: unknown[] }).entries)
    : [parsed];
  const hits: NormalizedSearchHit[] = [];
  const seen = new Set<string>();
  for (const [index, entry] of entries.entries()) {
    if (!entry || typeof entry !== 'object') continue;
    const item = entry as Record<string, unknown>;
    const id = String(item.id ?? item.url ?? '').replace(/^https?:\/\/youtu\.be\//, '').replace(/.*v=/, '');
    const extractor = String(item.extractor ?? item.ie_key ?? 'Youtube');
    if (!YOUTUBE_VIDEO_ID.test(id)) continue;
    if (seen.has(id)) continue;
    if (/playlist|channel/i.test(extractor) && item._type && item._type !== 'video') continue;
    if (item.live_status === 'is_upcoming' || item.availability === 'upcoming') continue;
    seen.add(id);
    const missing: string[] = [];
    if (item.duration == null) missing.push('durationSeconds');
    if (!item.upload_date && !item.timestamp) missing.push('publishedAt');
    hits.push(
      normalizeHit(
        assignStableIdentity({
          platform: 'youtube',
          sourceType: 'video',
          sourceId: id,
          canonicalURL: `https://www.youtube.com/watch?v=${id}`,
          title: String(item.title ?? id),
          publisher: item.channel ? String(item.channel) : item.uploader ? String(item.uploader) : null,
          publishedAt: item.upload_date ? toRfc3339(String(item.upload_date)) : item.timestamp ? unixToIso(item.timestamp) : null,
          durationSeconds: typeof item.duration === 'number' ? Math.round(item.duration) : null,
          description: item.description ? String(item.description).slice(0, 2000) : null,
          thumbnailURL: item.thumbnail ? String(item.thumbnail) : null,
          availability: item.availability ? String(item.availability) : 'public',
          provider: 'ytdlp',
          fallback: false,
          provenance: { title: 'ytdlp', sourceId: 'ytdlp' },
          fieldProvenance: { title: 'ytdlp', sourceId: 'ytdlp' },
          deepResearchAvailability: 'available',
          warnings: [],
          channelId: item.channel_id ? String(item.channel_id) : null,
          viewCount: typeof item.view_count === 'number' ? item.view_count : null,
          missingFields: missing,
          providerRank: index + 1
        })
      )
    );
  }
  return hits;
}

function toRfc3339(yyyymmdd: string): string | null {
  if (!/^\d{8}$/.test(yyyymmdd)) return null;
  return `${yyyymmdd.slice(0, 4)}-${yyyymmdd.slice(4, 6)}-${yyyymmdd.slice(6, 8)}T00:00:00Z`;
}

function unixToIso(value: unknown): string | null {
  const n = Number(value);
  if (!Number.isFinite(n)) return null;
  const ms = n > 10_000_000_000 ? n : n * 1000;
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

export function ytdlpArgvForSearch(query: string, limit: number): string[] {
  return [
    '--ignore-config',
    '--skip-download',
    '--flat-playlist',
    '--dump-single-json',
    '--no-warnings',
    '--no-call-home',
    `ytsearch${limit}:${query}`
  ];
}
