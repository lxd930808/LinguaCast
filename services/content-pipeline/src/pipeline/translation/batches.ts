// Batch planning (WP6): port of TranslationBatchPlanner. Numbered-JSON
// batches hold at most `maxItems` lines or `maxCharacters` source characters
// so the model can echo every origin verbatim.

import type { LearningSegment } from '../segmentation/types.js';
import { BATCH_MAX_CHARACTERS, BATCH_MAX_ITEMS } from '../../providers/translation/policy.js';

export interface TranslationBatch {
  id: number;
  segments: LearningSegment[];
}

export function planBatches(
  segments: LearningSegment[],
  maxItems: number = BATCH_MAX_ITEMS,
  maxCharacters: number = BATCH_MAX_CHARACTERS
): TranslationBatch[] {
  const batches: TranslationBatch[] = [];
  let current: LearningSegment[] = [];
  let currentCharacters = 0;

  for (const segment of segments) {
    const segmentCharacters = segment.text.length;
    const wouldExceedItems = current.length > 0 && current.length >= maxItems;
    const wouldExceedCharacters =
      current.length > 0 && currentCharacters + segmentCharacters > maxCharacters;
    if (wouldExceedItems || wouldExceedCharacters) {
      batches.push({ id: batches.length, segments: current });
      current = [];
      currentCharacters = 0;
    }
    current.push(segment);
    currentCharacters += segmentCharacters;
  }

  if (current.length > 0) {
    batches.push({ id: batches.length, segments: current });
  }
  return batches;
}

export function missingSequences(
  batch: TranslationBatch,
  translatedSequences: ReadonlySet<number>
): number[] {
  return batch.segments.map((s) => s.sequence).filter((seq) => !translatedSequences.has(seq));
}

/** Numbered user prompt: "12. source line" per row. */
export function numberedUserPrompt(batch: TranslationBatch): string {
  return batch.segments.map((s) => `${s.sequence}. ${s.text}`).join('\n');
}
