import type { LearningSegment, TranscriptWord } from './types.js';
import { weightedLength } from './weighted-length.js';

// Deterministic sentence segmenter (WP5) — a line-for-line port of
// TimedTextSentenceSegmenter.swift. Behavior must stay bit-compatible; the
// TS tests replay the Swift test vectors and expect identical cuts.
//
// Cut priority (lowest cost first): sentence-end punctuation → strong pause →
// clause punctuation → soft pause. Hard caps (max duration / weighted length)
// force a split; without a natural boundary the most balanced word cut wins.

export interface SegmentationProfile {
  softPauseMS: number;
  strongPauseMS: number;
  targetDurationMS: number;
  maxDurationMS: number;
  targetWeightedLength: number;
  maxWeightedLength: number;
  minimumWordCount: number;
}

/** Podcast defaults: soft 250ms / strong 700ms, target 4s·60, hard max 7s·75, ≥2 words. */
export const PODCAST_PROFILE: SegmentationProfile = {
  softPauseMS: 250,
  strongPauseMS: 700,
  targetDurationMS: 4000,
  maxDurationMS: 7000,
  targetWeightedLength: 60,
  maxWeightedLength: 75,
  minimumWordCount: 2
};

export function segmentsFromWords(
  words: TranscriptWord[],
  profile: SegmentationProfile
): LearningSegment[] {
  if (words.length === 0) return [];
  const output: LearningSegment[] = [];
  for (const hardChunk of splitOnHardBoundaries(words, profile)) {
    const cuts = optimalExclusiveEnds(hardChunk, profile);
    let start = 0;
    for (const end of cuts) {
      output.push(makeSegment(hardChunk.slice(start, end), output.length + 1));
      start = end;
    }
  }
  return output;
}

/** Best single cut index (left = words[0..<index]); null when unsplittable. */
export function bestBinarySplit(
  words: TranscriptWord[],
  profile: SegmentationProfile
): number | null {
  if (words.length < 2) return null;

  let bestCut: number | null = null;
  let bestScore = Number.POSITIVE_INFINITY;
  const mid = words.length / 2;

  for (let cut = 1; cut < words.length; cut += 1) {
    const left = words.slice(0, cut);
    const right = words.slice(cut);
    let score = boundaryCost(cut - 1, words, profile);
    score += balanceCost(left, right);
    if (left.length < profile.minimumWordCount) score += 6;
    if (right.length < profile.minimumWordCount) score += 6;
    if (left.length === 1) score += 4;
    if (right.length === 1) score += 4;

    const midDistance = Math.abs(cut - mid);
    let better: boolean;
    if (Math.abs(score - bestScore) < 1e-9) {
      const bestDistance = Math.abs((bestCut ?? cut) - mid);
      better =
        midDistance < bestDistance - 1e-9 ||
        (Math.abs(midDistance - bestDistance) < 1e-9 && cut < (bestCut ?? cut));
    } else {
      better = score < bestScore;
    }
    if (better) {
      bestScore = score;
      bestCut = cut;
    }
  }
  return bestCut;
}

/**
 * Re-segment ASR sentences locally. Segments without word streams keep their
 * original shape; speaker/notes metadata survive on every piece.
 */
export function resegmentLearningSegments(
  learningSegments: LearningSegment[],
  profile: SegmentationProfile = PODCAST_PROFILE
): LearningSegment[] {
  const output: LearningSegment[] = [];
  let changed = false;

  for (const segment of learningSegments) {
    const wordStream = segment.words;
    if (wordStream.length === 0) {
      output.push(segment);
      continue;
    }
    const pieces = segmentsFromWords(wordStream, profile);
    if (pieces.length === 0) {
      output.push(segment);
      continue;
    }

    if (
      pieces.length !== 1 ||
      pieces[0].startMS !== segment.startMS ||
      pieces[0].endMS !== segment.endMS ||
      pieces[0].text !== segment.text
    ) {
      changed = true;
    }

    for (const piece of pieces) {
      output.push({
        ...segment,
        startMS: piece.startMS,
        endMS: piece.endMS,
        text: piece.text,
        learningText: piece.text,
        translation: '',
        words: piece.words,
        timingSource: piece.timingSource ?? 'wordTimeline'
      });
    }
  }

  if (!changed) return learningSegments;
  output.forEach((segment, index) => {
    segment.sequence = index + 1;
  });
  return output;
}

// MARK: - Hard / DP cuts

/** Always cut after sentence-ending punctuation, and before a strong pause gap. */
function splitOnHardBoundaries(
  words: TranscriptWord[],
  profile: SegmentationProfile
): TranscriptWord[][] {
  const chunks: TranscriptWord[][] = [];
  let current: TranscriptWord[] = [];
  for (const word of words) {
    const last = current[current.length - 1];
    if (last) {
      const gap = Math.max(0, word.startMS - last.endMS);
      if (gap >= profile.strongPauseMS) {
        chunks.push(current);
        current = [];
      }
    }
    current.push(word);
    if (isSentenceEnding(word.punctuation)) {
      chunks.push(current);
      current = [];
    }
  }
  if (current.length > 0) chunks.push(current);
  return chunks;
}

/** Exclusive end indices of each chosen segment, always ending with words.length. */
function optimalExclusiveEnds(words: TranscriptWord[], profile: SegmentationProfile): number[] {
  const n = words.length;
  const dp = new Array<number>(n + 1).fill(Number.POSITIVE_INFINITY);
  const prev = new Array<number>(n + 1).fill(-1);
  dp[0] = 0;

  for (let end = 1; end <= n; end += 1) {
    for (let start = 0; start < end; start += 1) {
      if (!Number.isFinite(dp[start])) continue;
      const slice = words.slice(start, end);
      const duration = sliceDurationMS(slice);
      const length = weightedLength(renderText(slice));
      const exceedsMax = duration > profile.maxDurationMS || length > profile.maxWeightedLength;
      if (exceedsMax && slice.length > 1) continue;

      let cost = dp[start];
      if (start > 0) {
        cost += boundaryCost(start - 1, words, profile);
      }
      cost += segmentShapeCost(slice, profile);

      let replace: boolean;
      if (Math.abs(cost - dp[end]) < 1e-9) {
        const currentBalance = shapeBalance(words.slice(prev[end], end), profile);
        const candidateBalance = shapeBalance(slice, profile);
        replace =
          candidateBalance < currentBalance - 1e-9 ||
          (Math.abs(candidateBalance - currentBalance) < 1e-9 && start < prev[end]);
      } else {
        replace = cost < dp[end];
      }
      if (replace) {
        dp[end] = cost;
        prev[end] = start;
      }
    }
    // Safety: force a single-word extension when nothing valid reached `end`.
    if (!Number.isFinite(dp[end])) {
      dp[end] = dp[end - 1] + 100;
      prev[end] = end - 1;
    }
  }

  const ends: number[] = [];
  let cursor = n;
  while (cursor > 0) {
    ends.push(cursor);
    const previous = prev[cursor];
    if (previous < 0 || previous >= cursor) {
      throw new Error('segmenter DP produced an invalid back-pointer');
    }
    cursor = previous;
  }
  return ends.reverse();
}

// MARK: - Costs

/** Boundary cost of cutting *after* `index` (before `index + 1`). */
function boundaryCost(after: number, words: TranscriptWord[], profile: SegmentationProfile): number {
  const left = words[after];
  const right = words[after + 1];
  const gap = Math.max(0, right.startMS - left.endMS);

  let cost: number;
  if (isSentenceEnding(left.punctuation)) {
    cost = 0;
  } else if (gap >= profile.strongPauseMS) {
    cost = 1;
  } else if (isClausePunctuation(left.punctuation)) {
    cost = 2;
  } else if (gap >= profile.softPauseMS) {
    cost = 4;
  } else {
    cost = 25; // no natural boundary
  }

  // Penalize splits that isolate a function word at the end of the left side.
  if (isFunctionWord(left.text)) cost += 12;
  return cost;
}

function segmentShapeCost(slice: TranscriptWord[], profile: SegmentationProfile): number {
  const duration = sliceDurationMS(slice);
  const length = weightedLength(renderText(slice));
  const targetDuration = Math.max(profile.targetDurationMS, 1);
  const targetLength = Math.max(profile.targetWeightedLength, 1);

  let cost = 0;
  cost += 2.0 * (duration / targetDuration - 1.0) ** 2;
  cost += 2.0 * (length / targetLength - 1.0) ** 2;

  if (slice.length < profile.minimumWordCount) {
    cost += 5.0 * (profile.minimumWordCount - slice.length);
  }
  if (slice.length === 1) cost += 8;
  if (duration < targetDuration * 0.4) cost += 1.5;
  if (length < targetLength * 0.4) cost += 1.5;
  return cost;
}

function balanceCost(left: TranscriptWord[], right: TranscriptWord[]): number {
  const leftLen = weightedLength(renderText(left));
  const rightLen = weightedLength(renderText(right));
  const totalLen = Math.max(leftLen + rightLen, 1);
  const leftDur = sliceDurationMS(left);
  const rightDur = sliceDurationMS(right);
  const totalDur = Math.max(leftDur + rightDur, 1);
  return Math.abs(leftLen - rightLen) / totalLen + Math.abs(leftDur - rightDur) / totalDur;
}

function shapeBalance(slice: TranscriptWord[], profile: SegmentationProfile): number {
  const duration = sliceDurationMS(slice);
  const length = weightedLength(renderText(slice));
  return (
    Math.abs(duration - profile.targetDurationMS) / Math.max(profile.targetDurationMS, 1) +
    Math.abs(length - profile.targetWeightedLength) / Math.max(profile.targetWeightedLength, 1)
  );
}

// MARK: - Rendering / metrics

function makeSegment(words: TranscriptWord[], sequence: number): LearningSegment {
  const text = renderText(words);
  const startMS = words[0]?.startMS ?? 0;
  const endMS = Math.max(words[words.length - 1]?.endMS ?? startMS + 1, startMS + 1);
  return {
    sequence,
    startMS,
    endMS,
    text,
    learningText: text,
    translation: '',
    notes: '',
    words,
    timingSource: 'wordTimeline'
  };
}

export function renderText(words: TranscriptWord[]): string {
  return words
    .map((word) =>
      word.punctuation && word.punctuation.length > 0 ? word.text + word.punctuation : word.text
    )
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function sliceDurationMS(words: TranscriptWord[]): number {
  if (words.length === 0) return 0;
  return Math.max(0, words[words.length - 1].endMS - words[0].startMS);
}

function isSentenceEnding(punctuation?: string): boolean {
  if (!punctuation) return false;
  return [...punctuation].some((c) => '.?!…'.includes(c));
}

function isClausePunctuation(punctuation?: string): boolean {
  if (!punctuation) return false;
  return [...punctuation].some((c) => ',;:——–'.includes(c));
}

const FUNCTION_WORDS = new Set([
  'a', 'an', 'the',
  'of', 'in', 'on', 'at', 'to', 'for', 'from', 'by', 'with', 'as', 'into', 'onto',
  'over', 'under', 'about', 'after', 'before', 'between', 'through', 'during', 'without',
  'and', 'or', 'but', 'nor', 'so', 'yet', 'if', 'than', 'that',
  'is', 'are', 'was', 'were', 'be', 'been', 'am', 'do', 'does', 'did',
  'have', 'has', 'had', 'will', 'would', 'could', 'should', 'may', 'might',
  'must', 'shall', 'can', 'not', 'no', 'up', 'out'
]);

function isFunctionWord(text: string): boolean {
  // NFKC fold + lowercase + strip non-alphanumerics, mirroring the Swift side.
  const folded = text.normalize('NFKC').toLowerCase().trim();
  const stripped = folded.replace(/[^\p{L}\p{N}]+/gu, '');
  return FUNCTION_WORDS.has(stripped);
}
