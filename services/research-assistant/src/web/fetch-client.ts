import { DomainError } from '../domain/types.js';
import {
  MAX_REDIRECTS,
  assertPublicResolvedUrl,
  canonicalUrl,
  resolveRedirect,
  type DnsLookup
} from './policy.js';

export const ALLOWED_MIME = new Set([
  'text/html',
  'text/plain',
  'application/json',
  'application/xhtml+xml',
  'application/pdf'
]);

export interface FetchedPage {
  requestedUrl: string;
  finalUrl: string;
  mime: string;
  body: Buffer;
  status: number;
}

export type PageFetch = (
  url: URL,
  init: { redirect: 'manual'; signal: AbortSignal; headers: Record<string, string> }
) => Promise<{
  status: number;
  headers: { get(name: string): string | null };
  arrayBuffer(): Promise<ArrayBuffer>;
}>;

function looksCompressed(body: Buffer): boolean {
  if (body.length < 2) return false;
  if (body[0] === 0x1f && body[1] === 0x8b) return true;
  return body[0] === 0x78 && (body[1] === 0x01 || body[1] === 0x9c || body[1] === 0xda);
}

export async function fetchAllowedPage(
  raw: string,
  options: {
    lookup: DnsLookup;
    fetchImpl: PageFetch;
    maxBytes: number;
    timeoutMs?: number;
  }
): Promise<FetchedPage> {
  const timeoutMs = options.timeoutMs ?? 10_000;
  let current = await assertPublicResolvedUrl(raw, options.lookup);
  for (let hop = 0; hop <= MAX_REDIRECTS; hop += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let response: Awaited<ReturnType<PageFetch>>;
    try {
      response = await options.fetchImpl(current, {
        redirect: 'manual',
        signal: controller.signal,
        headers: { accept: 'text/html, text/plain, application/json, application/xhtml+xml', 'user-agent': 'linguacast-research-assistant' }
      });
    } catch {
      throw new DomainError('WEB_FETCH_FAILED', 'page fetch failed after policy checks', true, 503);
    } finally {
      clearTimeout(timer);
    }
    if (response.status >= 300 && response.status < 400) {
      const next = resolveRedirect(current, response.headers.get('location'));
      current = await assertPublicResolvedUrl(next.toString(), options.lookup);
      continue;
    }
    if (response.status >= 400) {
      throw new DomainError('WEB_FETCH_FAILED', 'page fetch failed after policy checks', true, 503);
    }
    const mime = (response.headers.get('content-type') ?? 'text/html').split(';')[0]!.trim().toLowerCase();
    if (!ALLOWED_MIME.has(mime)) {
      throw new DomainError('WEB_CONTENT_UNSUPPORTED', 'MIME type is not allowed', false, 422);
    }
    if (mime === 'application/pdf') {
      throw new DomainError('WEB_CONTENT_UNSUPPORTED', 'PDF extraction is not enabled', false, 422);
    }
    const length = Number(response.headers.get('content-length') ?? '0');
    if (length > options.maxBytes) {
      throw new DomainError('WEB_CONTENT_TOO_LARGE', 'response exceeded the size cap', false, 413);
    }
    const body = Buffer.from(await response.arrayBuffer());
    if (body.length > options.maxBytes) {
      throw new DomainError('WEB_CONTENT_TOO_LARGE', 'extracted body exceeded the size cap', false, 413);
    }
    if (looksCompressed(body)) {
      throw new DomainError('WEB_CONTENT_UNSUPPORTED', 'compressed payloads are not accepted as page bodies', false, 422);
    }
    return {
      requestedUrl: canonicalUrl(raw),
      finalUrl: canonicalUrl(current.toString()),
      mime,
      body,
      status: response.status
    };
  }
  throw new DomainError('WEB_URL_BLOCKED', 'too many redirects', false, 400);
}
