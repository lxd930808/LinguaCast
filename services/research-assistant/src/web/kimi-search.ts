import { JsonFileCredentialStore } from '../agent/pi-credentials.js';
import { DomainError } from '../domain/types.js';
import type { WebHit, WebSearchProvider } from './search-client.js';

export const KIMI_SEARCH_URL = 'https://api.kimi.com/coding/v1/search';
export const KIMI_OAUTH_TOKEN_URL = 'https://auth.kimi.com/api/oauth/token';
export const KIMI_OAUTH_CLIENT_ID = '17e5f671-d194-4dfb-9706-5516cb48c098';
export const KIMI_CODING_PROVIDER_ID = 'kimi-coding';
export const KIMI_REFRESH_SKEW_MS = 60_000;

type FetchLike = typeof fetch;

interface KimiSearchResult {
  site_name?: string;
  title?: string;
  url?: string;
  snippet?: string;
  content?: string;
  date?: string;
}

interface KimiSearchResponse {
  search_results?: KimiSearchResult[];
}

export interface KimiCodingWebSearchOptions {
  authPath: string;
  fetchImpl?: FetchLike;
  now?: () => number;
}

export class KimiCodingWebSearchProvider implements WebSearchProvider {
  readonly name = 'kimi';

  constructor(private readonly options: KimiCodingWebSearchOptions) {}

  async search(query: string, options: { locale?: string; limit: number }): Promise<WebHit[]> {
    const limit = clampLimit(options.limit);
    const token = await this.ensureAccessToken(false);
    const first = await this.callSearch(query, limit, token);
    if (first.status !== 401) {
      return this.parseHits(first, limit);
    }
    const retryToken = await this.ensureAccessToken(true);
    const second = await this.callSearch(query, limit, retryToken);
    return this.parseHits(second, limit);
  }

  private async ensureAccessToken(force: boolean): Promise<string> {
    const store = new JsonFileCredentialStore(this.options.authPath);
    let access = '';
    await store.modify(KIMI_CODING_PROVIDER_ID, async (current) => {
      if (!current || current.type !== 'oauth' || !current.access || !current.refresh) {
        throw new DomainError('WEB_SEARCH_FAILED', 'kimi-coding oauth is not configured', true, 503);
      }
      const expires = typeof current.expires === 'number' ? current.expires : 0;
      const now = this.options.now?.() ?? Date.now();
      if (!force && expires > now + KIMI_REFRESH_SKEW_MS) {
        access = current.access;
        return current;
      }
      const next = await this.refresh(current.refresh);
      access = next.access;
      return { type: 'oauth', access: next.access, refresh: next.refresh, expires: next.expires };
    });
    return access;
  }

  private async refresh(refreshToken: string): Promise<{ access: string; refresh: string; expires: number }> {
    const fetchImpl = this.options.fetchImpl ?? fetch;
    const response = await fetchImpl(KIMI_OAUTH_TOKEN_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: 'application/json'
      },
      body: new URLSearchParams({
        client_id: KIMI_OAUTH_CLIENT_ID,
        grant_type: 'refresh_token',
        refresh_token: refreshToken
      }).toString()
    });
    const text = await response.text();
    if (!response.ok) {
      throw new DomainError(
        'WEB_SEARCH_FAILED',
        `kimi-coding oauth refresh failed (${response.status})`,
        response.status >= 500,
        response.status === 401 || response.status === 403 ? 503 : 502
      );
    }
    let json: { access_token?: unknown; refresh_token?: unknown; expires_in?: unknown };
    try {
      json = JSON.parse(text) as { access_token?: unknown; refresh_token?: unknown; expires_in?: unknown };
    } catch {
      throw new DomainError('WEB_SEARCH_FAILED', 'kimi-coding oauth refresh returned invalid json', true, 502);
    }
    if (
      typeof json.access_token !== 'string' ||
      !json.access_token ||
      typeof json.refresh_token !== 'string' ||
      !json.refresh_token ||
      typeof json.expires_in !== 'number' ||
      !Number.isFinite(json.expires_in) ||
      json.expires_in <= 0
    ) {
      throw new DomainError('WEB_SEARCH_FAILED', 'kimi-coding oauth refresh missing fields', true, 502);
    }
    const now = this.options.now?.() ?? Date.now();
    return {
      access: json.access_token,
      refresh: json.refresh_token,
      expires: now + json.expires_in * 1000
    };
  }

  private async callSearch(query: string, limit: number, token: string): Promise<{ status: number; body: string }> {
    const fetchImpl = this.options.fetchImpl ?? fetch;
    const response = await fetchImpl(KIMI_SEARCH_URL, {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`
      },
      body: JSON.stringify({
        text_query: query,
        limit,
        enable_page_crawling: false,
        timeout_seconds: 30
      })
    });
    return { status: response.status, body: await response.text() };
  }

  private parseHits(result: { status: number; body: string }, limit: number): WebHit[] {
    if (!result.status || result.status >= 400) {
      throw new DomainError(
        'WEB_SEARCH_FAILED',
        `kimi search failed (${result.status || 0})`,
        result.status >= 500,
        result.status === 429 ? 429 : 502
      );
    }
    let json: KimiSearchResponse;
    try {
      json = JSON.parse(result.body) as KimiSearchResponse;
    } catch {
      throw new DomainError('WEB_SEARCH_FAILED', 'kimi search returned invalid json', true, 502);
    }
    const rows = Array.isArray(json.search_results) ? json.search_results : [];
    const hits: WebHit[] = [];
    for (const row of rows) {
      const url = typeof row.url === 'string' ? row.url.trim() : '';
      if (!url) continue;
      let host = '';
      try {
        host = new URL(url).hostname;
      } catch {
        continue;
      }
      const title = (typeof row.title === 'string' && row.title.trim()) || url;
      const snippet =
        (typeof row.snippet === 'string' && row.snippet.trim()) ||
        (typeof row.content === 'string' && row.content.trim()) ||
        '';
      const publishedAt = typeof row.date === 'string' && row.date.trim() ? row.date.trim() : null;
      const site = (typeof row.site_name === 'string' && row.site_name.trim()) || host;
      hits.push({ title, url, snippet, publishedAt, site });
      if (hits.length >= limit) break;
    }
    return hits;
  }
}

function clampLimit(limit: number): number {
  if (!Number.isFinite(limit) || limit < 1) return 5;
  return Math.min(20, Math.floor(limit));
}
