// Strict numbered-JSON parsing (WP6): port of the Swift TranslationClient
// validation. Every rule must hold simultaneously: key set exactly matches
// the expected sequences, `origin` equals the source text character-for-
// character, and the required translation field is non-empty. Interior
// newlines inside translations are normalized to spaces.

import type { LearningSegment } from '../segmentation/types.js';
import type { TranslationContext, TranslationQualityMode, TranslationTerm } from './prompts.js';

export type TranslationContentErrorKind = 'invalidJSON' | 'sequenceMismatch' | 'originMismatch' | 'missingContent';

/** Content/structure failure — the batch layer retries these in place. */
export class TranslationContentError extends Error {
  constructor(readonly kind: TranslationContentErrorKind) {
    super(kind);
    this.name = 'TranslationContentError';
  }
}

export function stripJSONMarkdown(raw: string): string {
  return raw.replace(/```json/g, '').replace(/```/g, '').trim();
}

function parseJsonObject(raw: string): Record<string, unknown> {
  const stripped = stripJSONMarkdown(raw);
  let json: unknown;
  try {
    json = JSON.parse(stripped);
  } catch {
    throw new TranslationContentError('invalidJSON');
  }
  if (typeof json !== 'object' || json === null || Array.isArray(json)) {
    throw new TranslationContentError('invalidJSON');
  }
  return json as Record<string, unknown>;
}

/** quality mode publishes the reflective `final`; fast mode `direct`. */
export function requiredTranslation(
  entry: Record<string, unknown>,
  qualityMode: TranslationQualityMode
): string | null {
  const field = qualityMode === 'quality' ? 'final' : 'direct';
  const value = entry[field];
  if (typeof value !== 'string') return null;
  const cleaned = value.replace(/\s+/g, ' ').trim();
  return cleaned.length === 0 ? null : cleaned;
}

export interface TranslationIssue {
  sequence?: number;
  kind: TranslationContentErrorKind;
}

/** Read top-level keys before JSON.parse can hide duplicate keys. JSON is validated first. */
function topLevelKeys(raw: string): string[] {
  const tokens = /"(?:\\.|[^"\\])*"|[{}\[\]]/g;
  let depth = 0;
  const keys: string[] = [];
  for (const token of raw.matchAll(tokens)) {
    const value = token[0];
    if (value === '{' || value === '[') depth += 1;
    else if (value === '}' || value === ']') depth -= 1;
    else if (depth === 1 && raw.slice(token.index! + value.length).trimStart().startsWith(':')) {
      keys.push(JSON.parse(value) as string);
    }
  }
  return keys;
}

/** Accept only independently verified rows; never guess a missing or incorrect ID. */
export function parsePartialBatchTranslations(
  raw: string,
  expected: LearningSegment[],
  qualityMode: TranslationQualityMode
): { translations: Map<number, string>; issues: TranslationIssue[] } {
  const json = parseJsonObject(raw);
  const keys = topLevelKeys(stripJSONMarkdown(raw));
  const counts = new Map<number, number>();
  const expectedIds = new Set(expected.map((s) => s.sequence));
  const issues: TranslationIssue[] = [];
  for (const key of keys) {
    const id = Number(key);
    if (!/^\d+$/.test(key) || !Number.isSafeInteger(id)) {
      issues.push({ kind: 'sequenceMismatch' });
      continue;
    }
    counts.set(id, (counts.get(id) ?? 0) + 1);
    if (!expectedIds.has(id)) issues.push({ kind: 'sequenceMismatch' });
  }
  const translations = new Map<number, string>();
  for (const source of expected) {
    if (counts.get(source.sequence) !== 1 || !Object.hasOwn(json, String(source.sequence))) {
      issues.push({ sequence: source.sequence, kind: 'sequenceMismatch' });
      continue;
    }
    const value = json[String(source.sequence)];
    if (typeof value !== 'object' || value === null || Array.isArray(value)) {
      issues.push({ sequence: source.sequence, kind: 'invalidJSON' });
      continue;
    }
    const entry = value as Record<string, unknown>;
    if (entry.origin !== source.text) {
      issues.push({ sequence: source.sequence, kind: 'originMismatch' });
      continue;
    }
    const translation = requiredTranslation(entry, qualityMode);
    if (translation === null) {
      issues.push({ sequence: source.sequence, kind: 'missingContent' });
      continue;
    }
    translations.set(source.sequence, translation);
  }
  return { translations, issues };
}

/** Strict entry point retained for callers that require a complete batch. */
export function parseNumberedBatchTranslations(
  raw: string,
  expected: LearningSegment[],
  qualityMode: TranslationQualityMode
): Map<number, string> {
  const result = parsePartialBatchTranslations(raw, expected, qualityMode);
  if (result.issues.length) throw new TranslationContentError(result.issues[0].kind);
  return result.translations;
}

export function parseNumberedSingleTranslation(
  raw: string,
  expected: LearningSegment,
  qualityMode: TranslationQualityMode
): string {
  const json = parseJsonObject(raw);
  // Accept either a bare object or a single-keyed numbered wrapper.
  let entry: Record<string, unknown>;
  if (typeof json.origin === 'string') {
    if (json.origin !== expected.text) throw new TranslationContentError('originMismatch');
    entry = json;
  } else {
    const values = Object.values(json);
    const nested = values.length === 1 ? values[0] : null;
    if (
      typeof nested !== 'object' ||
      nested === null ||
      Array.isArray(nested)
    ) {
      throw new TranslationContentError('invalidJSON');
    }
    if ((nested as Record<string, unknown>).origin !== expected.text) {
      throw new TranslationContentError('originMismatch');
    }
    entry = nested as Record<string, unknown>;
  }
  const translation = requiredTranslation(entry, qualityMode);
  if (translation === null) throw new TranslationContentError('missingContent');
  return translation;
}

/** Parse the topic-summary + glossary extraction response. */
export function parseContextResponse(raw: string): TranslationContext | null {
  let json: Record<string, unknown>;
  try {
    json = parseJsonObject(raw);
  } catch {
    return null;
  }
  const summary = typeof json.summary === 'string' ? json.summary.trim() : '';
  const rawTerms = Array.isArray(json.terms) ? json.terms : [];
  const terms: TranslationTerm[] = [];
  for (const value of rawTerms.slice(0, 15)) {
    if (typeof value !== 'object' || value === null) continue;
    const entry = value as Record<string, unknown>;
    const source = typeof entry.source === 'string' ? entry.source.trim() : '';
    const target = typeof entry.target === 'string' ? entry.target.trim() : '';
    if (source.length === 0 || target.length === 0) continue;
    const note = typeof entry.note === 'string' ? entry.note.trim() : '';
    terms.push({ source, target, note });
  }
  return { topicSummary: summary, terms };
}

/**
 * Parse the `{"parts":[...]}` split response, requiring exactly
 * `expectedCount` non-empty parts. Tolerates code fences and surrounding
 * prose around the JSON object.
 */
export function parseTranslationSplitParts(content: string, expectedCount: number): string[] | null {
  const unfenced = content.replace(/```json/g, '').replace(/```/g, '');
  const start = unfenced.indexOf('{');
  const end = unfenced.lastIndexOf('}');
  if (start === -1 || end === -1 || end < start) return null;
  let object: unknown;
  try {
    object = JSON.parse(unfenced.slice(start, end + 1));
  } catch {
    return null;
  }
  if (typeof object !== 'object' || object === null) return null;
  const parts = (object as { parts?: unknown }).parts;
  if (!Array.isArray(parts) || parts.length !== expectedCount) return null;
  const strings = parts.map((p) => (typeof p === 'string' ? p.trim() : ''));
  if (strings.some((s) => s.length === 0)) return null;
  return strings;
}
