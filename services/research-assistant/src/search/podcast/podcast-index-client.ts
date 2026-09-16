import { createHash } from 'node:crypto';

import { DomainError } from '../../domain/types.js';

export const PODCASTINDEX_DEFAULT_BASE = 'https://api.podcastindex.org/api/1.0';
const ALLOWED_BASES = new Set([PODCASTINDEX_DEFAULT_BASE]);
const MAX_BODY_BYTES = 1_500_000;

export type PodcastIndexHttp = (input: {
  url: URL;
  headers: Record<string, string>;
  timeoutMs: number;
}) => Promise<{ status: number; headers: Record<string, string>; body: string }>;

export class PodcastIndexError extends DomainError {
  constructor(code: string, message: string, retryable: boolean, httpStatus: number, params: Record<string, unknown> = {}) {
    super(code, message, retryable, httpStatus, params);
    this.name = 'PodcastIndexError';
  }
}

export function signPodcastIndex(apiKey: string, apiSecret: string, unixTime: number): string {
  return createHash('sha1').update(`${apiKey}${apiSecret}${unixTime}`).digest('hex');
}

export function podcastIndexHeaders(
  apiKey: string,
  apiSecret: string,
  unixTime: number,
  userAgent = 'LinguaCastResearchAssistant/1.0'
): Record<string, string> {
  return {
    'User-Agent': userAgent,
    'X-Auth-Key': apiKey,
    'X-Auth-Date': String(unixTime),
    Authorization: signPodcastIndex(apiKey, apiSecret, unixTime)
  };
}

const defaultHttp: PodcastIndexHttp = async ({ url, headers, timeoutMs }) => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { headers, signal: controller.signal, redirect: 'error' });
    const body = await response.text();
    const headerMap: Record<string, string> = {};
    response.headers.forEach((value, key) => {
      headerMap[key.toLowerCase()] = value;
    });
    return { status: response.status, headers: headerMap, body };
  } catch (error) {
    if ((error as { name?: string }).name === 'AbortError') {
      throw new PodcastIndexError('PODCASTINDEX_UNAVAILABLE', 'Podcast Index timed out', true, 503);
    }
    throw new PodcastIndexError('PODCASTINDEX_UNAVAILABLE', 'Podcast Index request failed', true, 503);
  } finally {
    clearTimeout(timer);
  }
};

export class PodcastIndexClient {
  constructor(
    private readonly options: {
      apiKey: string;
      apiSecret: string;
      baseUrl?: string;
      timeoutMs?: number;
      http?: PodcastIndexHttp;
      now?: () => number;
      userAgent?: string;
    }
  ) {
    const base = (options.baseUrl || PODCASTINDEX_DEFAULT_BASE).replace(/\/+$/, '');
    if (!ALLOWED_BASES.has(base) && options.baseUrl && !options.baseUrl.includes('example.test')) {
      throw new PodcastIndexError('PODCASTINDEX_NOT_CONFIGURED', 'Podcast Index base URL is not allowlisted', false, 500);
    }
  }

  private get configured(): boolean {
    return Boolean(this.options.apiKey && this.options.apiSecret);
  }

  async request(path: string, params: Record<string, string | number | undefined>): Promise<unknown> {
    if (!this.configured) {
      throw new PodcastIndexError('PODCASTINDEX_NOT_CONFIGURED', 'Podcast Index is not configured', false, 503);
    }
    const base = (this.options.baseUrl || PODCASTINDEX_DEFAULT_BASE).replace(/\/+$/, '');
    const url = new URL(`${base}${path.startsWith('/') ? path : `/${path}`}`);
    for (const [key, value] of Object.entries(params)) {
      if (value != null && value !== '') url.searchParams.set(key, String(value));
    }
    const unixTime = this.options.now?.() ?? Math.floor(Date.now() / 1000);
    const headers = podcastIndexHeaders(
      this.options.apiKey,
      this.options.apiSecret,
      unixTime,
      this.options.userAgent
    );
    const http = this.options.http ?? defaultHttp;
    let response: { status: number; headers: Record<string, string>; body: string };
    try {
      response = await http({ url, headers, timeoutMs: this.options.timeoutMs ?? 10_000 });
    } catch (error) {
      if (error instanceof PodcastIndexError) throw error;
      throw new PodcastIndexError('PODCASTINDEX_UNAVAILABLE', 'Podcast Index request failed', true, 503);
    }
    this.assertSafeBody(response.body, response.status, response.headers);
    if (response.status === 401 || response.status === 403) {
      throw new PodcastIndexError('PODCASTINDEX_AUTH_FAILED', 'Podcast Index authentication failed', true, 401);
    }
    if (response.status === 429) {
      throw new PodcastIndexError('PODCASTINDEX_RATE_LIMITED', 'Podcast Index rate limited', true, 429, {
        retryAfterSeconds: parseRetryAfter(response.headers['retry-after'])
      });
    }
    if (response.status >= 500) {
      throw new PodcastIndexError('PODCASTINDEX_UNAVAILABLE', 'Podcast Index upstream error', true, 503);
    }
    if (response.status >= 400) {
      throw new PodcastIndexError('PODCASTINDEX_INVALID_RESPONSE', 'Podcast Index returned an error', true, 502);
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(response.body);
    } catch {
      throw new PodcastIndexError('PODCASTINDEX_INVALID_RESPONSE', 'Podcast Index response was not JSON', true, 502);
    }
    if (!parsed || typeof parsed !== 'object') {
      throw new PodcastIndexError('PODCASTINDEX_INVALID_RESPONSE', 'Podcast Index response schema was invalid', true, 502);
    }
    return parsed;
  }

  searchByPerson(q: string, max = 10) {
    return this.request('/search/byperson', { q, max });
  }
  searchByTerm(q: string, max = 10) {
    return this.request('/search/byterm', { q, max });
  }
  searchByTitle(q: string, max = 10) {
    return this.request('/search/bytitle', { q, max });
  }
  podcastByFeedId(id: number) {
    return this.request('/podcasts/byfeedid', { id });
  }
  podcastByItunesId(id: number) {
    return this.request('/podcasts/byitunesid', { id });
  }
  episodesByFeedId(id: number, max = 10, since?: number) {
    return this.request('/episodes/byfeedid', { id, max, since });
  }
  episodeById(id: number) {
    return this.request('/episodes/byid', { id });
  }
  recentEpisodes(max = 10, lang?: string) {
    return this.request('/recent/episodes', { max, lang });
  }

  private assertSafeBody(body: string, status: number, headers: Record<string, string>): void {
    if (Buffer.byteLength(body) > MAX_BODY_BYTES) {
      throw new PodcastIndexError('PODCASTINDEX_INVALID_RESPONSE', 'Podcast Index response exceeded size limit', true, 502);
    }
    const type = headers['content-type'] ?? '';
    if (status === 200 && type.includes('html')) {
      throw new PodcastIndexError('PODCASTINDEX_INVALID_RESPONSE', 'Podcast Index returned HTML', true, 502);
    }
    if (body.trimStart().startsWith('<')) {
      throw new PodcastIndexError('PODCASTINDEX_INVALID_RESPONSE', 'Podcast Index returned HTML', true, 502);
    }
  }
}

function parseRetryAfter(value: string | undefined): number {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.round(n) : 30;
}

export function redactPodcastIndexSecrets(text: string, apiKey: string, apiSecret: string, signature?: string): string {
  let out = text;
  for (const secret of [apiKey, apiSecret, signature]) {
    if (secret && secret.length >= 8) out = out.split(secret).join('[REDACTED]');
  }
  out = out.replace(/X-Auth-Key:\s*\S+/gi, 'X-Auth-Key: [REDACTED]');
  out = out.replace(/Authorization:\s*\S+/gi, 'Authorization: [REDACTED]');
  return out;
}
