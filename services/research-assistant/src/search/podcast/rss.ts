import { XMLParser } from 'fast-xml-parser';

import { DomainError } from '../../domain/types.js';
import type { HttpGet } from '../http.js';
import { defaultHttpGet } from '../http.js';
import type { NormalizedSearchHit } from '../contracts.js';
import { assignStableIdentity } from '../identity.js';
import { normalizeHit } from '../normalize.js';

const BLOCKED_HOSTS = new Set(['localhost', 'metadata.google.internal']);
const PRIVATE_IP = /^(127\.|10\.|192\.168\.|169\.254\.|0\.|::1|fc|fd|fe80)/i;
const MAX_XML_BYTES = 1_500_000;

export function assertPublicHttpsUrl(raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new DomainError('SOURCE_URL_BLOCKED', 'invalid source URL', false, 400);
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new DomainError('SOURCE_URL_BLOCKED', 'source URL scheme is not allowed', false, 400);
  }
  const host = url.hostname.toLowerCase();
  if (BLOCKED_HOSTS.has(host) || PRIVATE_IP.test(host) || host.endsWith('.local')) {
    throw new DomainError('SOURCE_URL_BLOCKED', 'source URL host is not allowed', false, 400);
  }
  return url;
}

export async function fetchRssEpisodes(
  feedURL: string,
  limit: number,
  httpGet: HttpGet = defaultHttpGet
): Promise<NormalizedSearchHit[]> {
  const url = assertPublicHttpsUrl(feedURL);
  const response = await httpGet(url, 15_000);
  if (response.status >= 300 && response.status < 400) {
    throw new DomainError('SOURCE_URL_BLOCKED', 'RSS redirect is not followed automatically', true, 400);
  }
  if (response.status >= 400) {
    throw new DomainError('RSS_UNAVAILABLE', 'RSS fetch failed', true, 503);
  }
  const xml = response.text || (typeof response.json === 'string' ? response.json : '');
  if (Buffer.byteLength(xml) > MAX_XML_BYTES) {
    throw new DomainError('RSS_UNAVAILABLE', 'RSS document exceeded size limit', true, 400);
  }
  if (/<!DOCTYPE/i.test(xml) || /<!ENTITY/i.test(xml)) {
    throw new DomainError('SOURCE_URL_BLOCKED', 'RSS document with external entities is not allowed', false, 400);
  }
  const type = '';
  void type;
  const parser = new XMLParser({
    ignoreAttributes: false,
    processEntities: false,
    htmlEntities: false,
    allowBooleanAttributes: false
  });
  let parsed: unknown;
  try {
    parsed = parser.parse(xml);
  } catch {
    throw new DomainError('RSS_UNAVAILABLE', 'RSS XML was not parseable', true, 400);
  }
  const items = collectItems(parsed).slice(0, Math.min(50, Math.max(1, limit)));
  return items.map((item, index) => {
    const guid = textOf(item.guid) || textOf(item.link) || `episode-${index}`;
    const enclosure = enclosureOf(item);
    const title = textOf(item.title) || guid;
    return normalizeHit(
      assignStableIdentity({
        platform: 'podcast',
        sourceType: 'podcast_episode',
        sourceId: guid,
        canonicalURL: textOf(item.link) || enclosure?.url || feedURL,
        feedURL,
        title,
        publisher: null,
        publishedAt: parseRssDate(textOf(item.pubDate)),
        durationSeconds: itunesDuration(item),
        description: textOf(item.description)?.slice(0, 2000) ?? null,
        thumbnailURL: null,
        availability: 'public',
        provider: 'rss',
        fallback: true,
        provenance: { title: 'rss', sourceId: 'rss' },
        fieldProvenance: { title: 'rss', guid: 'rss' },
        deepResearchAvailability: enclosure?.url ? 'available' : 'unavailable',
        warnings: enclosure?.url ? [] : ['missing_enclosure'],
        guid,
        enclosureUrl: enclosure?.url ?? null,
        enclosureType: enclosure?.type ?? null,
        providerRank: index + 1
      })
    );
  });
}

function collectItems(parsed: unknown): Array<Record<string, unknown>> {
  const rss = parsed as { rss?: { channel?: { item?: unknown } }; feed?: { entry?: unknown } };
  const items = rss?.rss?.channel?.item ?? rss?.feed?.entry ?? [];
  const list = Array.isArray(items) ? items : [items];
  return list.filter((item): item is Record<string, unknown> => Boolean(item) && typeof item === 'object');
}

function textOf(value: unknown): string | null {
  if (typeof value === 'string') return value.replace(/<!\[CDATA\[|\]\]>/g, '').trim() || null;
  if (value && typeof value === 'object' && '#text' in (value as Record<string, unknown>)) {
    return textOf((value as Record<string, unknown>)['#text']);
  }
  return null;
}

function enclosureOf(item: Record<string, unknown>): { url: string; type?: string } | null {
  const enclosure = item.enclosure as Record<string, unknown> | undefined;
  if (!enclosure) return null;
  const url = String(enclosure['@_url'] ?? enclosure.url ?? '');
  if (!url) return null;
  return { url, type: enclosure['@_type'] ? String(enclosure['@_type']) : undefined };
}

function itunesDuration(item: Record<string, unknown>): number | null {
  const raw = item['itunes:duration'];
  const text = textOf(raw);
  if (!text) return null;
  if (/^\d+$/.test(text)) return Number(text);
  const parts = text.split(':').map(Number);
  if (parts.some((part) => Number.isNaN(part))) return null;
  return parts.reduce((sum, part) => sum * 60 + part, 0);
}

function parseRssDate(value: string | null): string | null {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}
