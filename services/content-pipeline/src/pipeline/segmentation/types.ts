// Segmentation domain types (WP5). These mirror the Swift LearningSegment
// wire shape frozen in WP0 (fixtures/contract/learning-segments-bilingual.json)
// and ios/.../LearningCore.swift.

export interface TranscriptWord {
  text: string;
  startMS: number;
  endMS: number;
  punctuation?: string;
}

export type SegmentTimingSource = 'wordTimeline' | 'semantic' | 'legacy';

/**
 * Whole-sentence playback identity shared by display sub-clauses (WP6
 * refinement). Mirrors Swift PlaybackSentence; present in the WP0 contract
 * fixture learning-segments-bilingual.json.
 */
export interface PlaybackSentence {
  id: number;
  text: string;
  translation: string;
  startMS: number;
  endMS: number;
}

export interface LearningSegment {
  sequence: number;
  startMS: number;
  endMS: number;
  text: string;
  learningText: string;
  translation: string;
  speaker?: string;
  notes: string;
  words: TranscriptWord[];
  playbackSentence?: PlaybackSentence;
  timingSource: SegmentTimingSource;
}

/** Whole-sentence start used for repeat/navigation (Swift playbackStartMS). */
export function playbackStartMS(segment: LearningSegment): number {
  return segment.playbackSentence?.startMS ?? segment.startMS;
}

/** Whole-sentence end used for repeat/navigation (Swift playbackEndMS). */
export function playbackEndMS(segment: LearningSegment): number {
  return segment.playbackSentence?.endMS ?? segment.endMS;
}
