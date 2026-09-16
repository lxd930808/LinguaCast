// Display sub-clause split policy + planner (WP6): port of
// SubtitleDisplaySplitPolicy and DisplayRefinementPlanner. Pure functions —
// no LLM calls — so the decision and assembly logic is unit-testable.

import type { LearningSegment } from '../segmentation/types.js';
import { weightedLength } from '../segmentation/weighted-length.js';

/** Character budget a single display line should stay under. */
export const CHARACTER_BUDGET = 75.0;
/** Split when the weighted target exceeds budget × this factor. */
export const TARGET_OVERFLOW_FACTOR = 1.2;
/** Maximum recursive split rounds. */
export const MAX_RECURSION_DEPTH = 3;

export function requiresDisplaySplit(source: string, translation: string): boolean {
  if (source.length > CHARACTER_BUDGET) return true;
  return weightedLength(translation) * TARGET_OVERFLOW_FACTOR > CHARACTER_BUDGET;
}

/** Candidates exceed the budget AND still carry a word stream. */
export function isRefinementCandidate(segment: LearningSegment): boolean {
  return requiresDisplaySplit(segment.text, segment.translation) && segment.words.length > 0;
}

export function candidateIndices(segments: LearningSegment[]): number[] {
  const indices: number[] = [];
  for (let i = 0; i < segments.length; i += 1) {
    if (isRefinementCandidate(segments[i])) indices.push(i);
  }
  return indices;
}

/** Per-candidate checkpoint entry, keyed by the pre-split sequence. */
export interface DisplayRefinementCheckpointEntry {
  originalSequence: number;
  segments: LearningSegment[];
}

export interface DisplayRefinementCheckpoint {
  schemaVersion: 1;
  sourceFingerprint: string;
  entries: DisplayRefinementCheckpointEntry[];
  /** Present on the completion write: assembled, enriched, resequenced output. */
  segments?: LearningSegment[];
}

/**
 * Merge checkpointed candidate results back into the original order, then
 * resequence from 1 (client parity with DisplayRefinementPlanner.assemble).
 */
export function assembleRefined(
  original: LearningSegment[],
  refinedBySequence: ReadonlyMap<number, LearningSegment[]>
): LearningSegment[] {
  const output: LearningSegment[] = [];
  for (const segment of original) {
    const refined = refinedBySequence.get(segment.sequence);
    if (refined && refined.length > 0) {
      output.push(...refined);
    } else {
      output.push(segment);
    }
  }
  return output.map((segment, index) => ({ ...segment, sequence: index + 1 }));
}

export function readRefinementCheckpoint(
  checkpoints: Array<{ stage: string; output: unknown }>,
  sourceFingerprint: string
): DisplayRefinementCheckpoint | null {
  for (const checkpoint of checkpoints) {
    if (checkpoint.stage !== 'refining_subtitles') continue;
    const output = checkpoint.output as Partial<DisplayRefinementCheckpoint> | null;
    if (
      output !== null &&
      typeof output === 'object' &&
      output.sourceFingerprint === sourceFingerprint &&
      Array.isArray(output.entries)
    ) {
      return output as DisplayRefinementCheckpoint;
    }
  }
  return null;
}
