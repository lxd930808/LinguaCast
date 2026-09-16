import type { NormalizedSearchHit } from './contracts.js';

const HTML_TAG = /<[^>]+>/g;
const SCRIPT = /<script[\s\S]*?<\/script>/gi;

export function sanitizeDescription(raw: string | null | undefined, max = 2000): string | null {
  if (!raw) return null;
  const text = raw
    .replace(SCRIPT, ' ')
    .replace(HTML_TAG, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/\s+/g, ' ')
    .normalize('NFC')
    .trim();
  if (!text) return null;
  return text.slice(0, max);
}

export function sanitizeTitle(raw: string, fallback: string): string {
  const text = raw.normalize('NFC').replace(/\s+/g, ' ').trim();
  return (text || fallback).slice(0, 300);
}

export function clipDescriptionForModel(raw: string | null | undefined, max = 600): string | null {
  if (!raw) return null;
  return raw.slice(0, max);
}

export function normalizeHit(hit: NormalizedSearchHit): NormalizedSearchHit {
  const missing: string[] = [...(hit.missingFields ?? [])];
  const description = sanitizeDescription(hit.description);
  const title = sanitizeTitle(hit.title, hit.sourceId);
  if (!hit.durationSeconds) missing.push('durationSeconds');
  if (!hit.publishedAt) missing.push('publishedAt');
  if (!hit.viewCount && hit.platform === 'youtube') missing.push('viewCount');
  if (hit.sourceType !== 'video' && !hit.enclosureUrl && hit.sourceType === 'podcast_episode') {
    missing.push('enclosureUrl');
  }
  const warnings = [...hit.warnings];
  if (hit.sourceType === 'podcast_episode' && !hit.enclosureUrl) {
    warnings.push('missing_enclosure');
  }
  return {
    ...hit,
    title,
    description,
    publisher: hit.publisher?.normalize('NFC').trim() || null,
    missingFields: [...new Set(missing)],
    warnings: [...new Set(warnings)],
    deepResearchAvailability:
      hit.sourceType === 'podcast_show'
        ? 'unavailable'
        : hit.sourceType === 'podcast_episode' && !hit.enclosureUrl
          ? 'unavailable'
          : hit.deepResearchAvailability
  };
}

export function boundToolPayload(value: unknown, maxChars = 8000): unknown {
  const json = JSON.stringify(value);
  if (json.length <= maxChars) return value;
  if (value && typeof value === 'object' && Array.isArray((value as { results?: unknown[] }).results)) {
    const copy = { ...(value as Record<string, unknown>) };
    const results = [...((copy.results as unknown[]) ?? [])];
    while (JSON.stringify({ ...copy, results }).length > maxChars && results.length > 0) {
      results.pop();
    }
    copy.results = results;
    copy.warnings = [...new Set([...(Array.isArray(copy.warnings) ? (copy.warnings as string[]) : []), 'truncated'])];
    return copy;
  }
  return JSON.parse(json.slice(0, maxChars - 1) + '…') as unknown;
}
