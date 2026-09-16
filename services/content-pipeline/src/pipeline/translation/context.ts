// Context selection (WP6): port of TranslationContextSamplingPolicy,
// TranslationBlockContextPolicy and TranslationContext.terms(matching:).
// String lengths use UTF-16 code units on both platforms (Swift String.count
// counts extended grapheme clusters — for the ASCII-heavy budget checks here
// the results agree; CJK source text is not expected pre-translation).

import type { LearningSegment } from '../segmentation/types.js';
import type { TranslationTerm } from './prompts.js';

export const MAX_CONTEXT_CHARACTERS = 8_000;
export const CONTEXT_BUCKET_COUNT = 8;
export const PER_BUCKET_CHARACTER_TARGET = 1_000;

/**
 * Transcript excerpt for topic/term extraction: the full transcript up to
 * 8000 chars, otherwise whole sentences sampled evenly across 8 buckets
 * (~1000 chars each), order preserved.
 */
export function sampleContextTexts(segments: LearningSegment[]): string[] {
  const texts = segments.map((s) => s.text);
  const total = texts.reduce((sum, t) => sum + t.length, 0);
  if (total <= MAX_CONTEXT_CHARACTERS) return texts;
  if (segments.length === 0) return [];

  const bucketCount = Math.min(CONTEXT_BUCKET_COUNT, segments.length);
  const bucketSize = Math.max(1, Math.floor(segments.length / bucketCount));
  const sampled: string[] = [];
  for (let bucketIndex = 0; bucketIndex < bucketCount; bucketIndex += 1) {
    const lower = bucketIndex * bucketSize;
    const upper =
      bucketIndex === bucketCount - 1
        ? segments.length
        : Math.min(segments.length, (bucketIndex + 1) * bucketSize);
    if (lower >= upper) break;
    let bucketCharacters = 0;
    for (let i = lower; i < upper; i += 1) {
      if (bucketCharacters >= PER_BUCKET_CHARACTER_TARGET) break;
      sampled.push(segments[i].text);
      bucketCharacters += segments[i].text.length;
    }
  }

  const result: string[] = [];
  let running = 0;
  for (const text of sampled) {
    if (running >= MAX_CONTEXT_CHARACTERS) break;
    result.push(text);
    running += text.length;
  }
  return result;
}

export function sampleContextText(segments: LearningSegment[]): string {
  return sampleContextTexts(segments).join('\n');
}

export const PRECEDING_LINE_COUNT = 3;
export const FOLLOWING_LINE_COUNT = 2;

/** Per-block context injection: previous 3 lines, following 2 lines. */
export function blockContext(
  allSegments: LearningSegment[],
  blockSequences: ReadonlySet<number>
): { before: string[]; after: string[] } {
  if (allSegments.length === 0) return { before: [], after: [] };
  const indices: number[] = [];
  for (let i = 0; i < allSegments.length; i += 1) {
    if (blockSequences.has(allSegments[i].sequence)) indices.push(i);
  }
  if (indices.length === 0) return { before: [], after: [] };
  const first = indices[0];
  const last = indices[indices.length - 1];
  const beforeStart = Math.max(0, first - PRECEDING_LINE_COUNT);
  const before = allSegments.slice(beforeStart, first).map((s) => s.text);
  const afterEnd = Math.min(allSegments.length, last + 1 + FOLLOWING_LINE_COUNT);
  const after = allSegments.slice(last + 1, afterEnd).map((s) => s.text);
  return { before, after };
}

/** Glossary entries whose source literally appears in the block text. */
export function termsMatching(terms: TranslationTerm[], blockText: string): TranslationTerm[] {
  const haystack = blockText.toLowerCase();
  return terms.filter(
    (term) => term.source.length > 0 && haystack.includes(term.source.toLowerCase())
  );
}
