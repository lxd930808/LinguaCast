// Display refinement stage (WP6): recursive sub-clause splitting of long
// translated sentences, checkpointed per candidate. Runs after translation so
// long-sentence splitting never blocks a playable artifact; permanent model
// failures keep the whole sentence (client parity with SubtitleDisplayRefiner).

import type { JobRow } from '../../domain/job-model.js';
import { PipelineJobError } from '../../jobs/worker.js';
import type { JobStore, ProgressUpdate } from '../../jobs/job-store.js';
import type { RedactingLogger } from '../../observability/logger.js';
import type { TranslationProvider } from '../../providers/translation/types.js';
import type { LearningSegment } from '../segmentation/types.js';
import { playbackEndMS, playbackStartMS } from '../segmentation/types.js';
import {
  bestBinarySplit,
  PODCAST_PROFILE,
  renderText,
  type SegmentationProfile
} from '../segmentation/sentence-segmenter.js';
import { alignedTranslationSplitSystemPrompt } from '../translation/prompts.js';
import { parseTranslationSplitParts } from '../translation/parse.js';
import { mapTranslationError } from '../translation/translate-stage.js';
import {
  assembleRefined,
  isRefinementCandidate,
  MAX_RECURSION_DEPTH,
  readRefinementCheckpoint,
  requiresDisplaySplit,
  type DisplayRefinementCheckpoint
} from './display-policy.js';

export interface RefinementStageHooks {
  updateProgress: (update: ProgressUpdate) => void;
  heartbeat: () => void;
  signal: AbortSignal;
}

export interface RefinementStageDeps {
  store: JobStore;
  logger: RedactingLogger;
  provider: TranslationProvider;
  profile?: SegmentationProfile;
  concurrency?: number;
}

export interface RefinementStageResult {
  segments: LearningSegment[];
  refinedCandidateCount: number;
  totalCandidates: number;
  reusedCheckpoint: boolean;
}

interface AsrCheckpointShape {
  sourceFingerprint: string;
  segments: LearningSegment[];
}

interface TranslationCheckpointShape {
  sourceFingerprint: string;
  translations: Record<string, string>;
}

export async function runRefinementStage(
  job: JobRow,
  deps: RefinementStageDeps,
  hooks: RefinementStageHooks
): Promise<RefinementStageResult> {
  const { store, provider } = deps;
  const checkpoints = store.reusableCheckpoints(job.jobId);

  // Input reconstruction: ASR segments + the translation stage's durable
  // translations map. Both are checkpointed upstream, so a restart reaches
  // this stage without any provider calls.
  const asr = checkpoints
    .filter((c) => c.stage === 'transcribing')
    .map((c) => c.output as Partial<AsrCheckpointShape> | null)
    .find(
      (o) =>
        o !== null &&
        typeof o === 'object' &&
        Array.isArray(o.segments) &&
        typeof o.sourceFingerprint === 'string'
    ) as AsrCheckpointShape | undefined;
  const translation = checkpoints
    .filter((c) => c.stage === 'translating')
    .map((c) => c.output as Partial<TranslationCheckpointShape> | null)
    .find(
      (o) =>
        o !== null &&
        typeof o === 'object' &&
        typeof o.sourceFingerprint === 'string' &&
        typeof o.translations === 'object' &&
        o.translations !== null
    ) as TranslationCheckpointShape | undefined;
  if (!asr || !translation || translation.sourceFingerprint !== asr.sourceFingerprint) {
    throw new PipelineJobError({
      code: 'INTERNAL_ERROR',
      message: 'refinement stage reached without completed translation checkpoints',
      retryable: false,
      failedStage: 'refining_subtitles'
    });
  }
  const sourceFingerprint = asr.sourceFingerprint;
  const segments = asr.segments.map((segment) => {
    const text = translation.translations[String(segment.sequence)]?.trim();
    return text ? { ...segment, translation: text } : segment;
  });
  if (segments.some((s) => s.translation.trim().length === 0)) {
    throw new PipelineJobError({
      code: 'INTERNAL_ERROR',
      message: 'refinement stage reached with untranslated segments',
      retryable: false,
      failedStage: 'refining_subtitles'
    });
  }

  const candidates = segments.filter(isRefinementCandidate);
  const total = candidates.length;

  // Resume: fingerprint-scoped checkpoint restores completed candidates.
  const prior = readRefinementCheckpoint(checkpoints, sourceFingerprint);
  const refinedBySequence = new Map<number, LearningSegment[]>(
    (prior?.entries ?? []).map((entry) => [entry.originalSequence, entry.segments])
  );
  const pending = candidates.filter((c) => !refinedBySequence.has(c.sequence));

  const checkpointEntries = () =>
    [...refinedBySequence.keys()]
      .sort((a, b) => a - b)
      .map((sequence) => ({
        originalSequence: sequence,
        segments: refinedBySequence.get(sequence)!
      }));

  const writeCheckpoint = (segments0: LearningSegment[] | null) => {
    store.recordCheckpoint(job.jobId, {
      stage: 'refining_subtitles',
      inputFingerprint: sourceFingerprint,
      output: {
        schemaVersion: 1,
        sourceFingerprint,
        entries: checkpointEntries(),
        ...(segments0 ? { segments: segments0 } : {})
      } satisfies DisplayRefinementCheckpoint,
      schemaVersion: 1,
      reusable: true
    });
  };

  if (pending.length === 0) {
    const assembled = enrichSegments(assembleRefined(segments, refinedBySequence));
    writeCheckpoint(assembled);
    hooks.updateProgress({ stage: 'refining_subtitles', stageProgress: 1 });
    return {
      segments: assembled,
      refinedCandidateCount: 0,
      totalCandidates: total,
      reusedCheckpoint: prior !== null
    };
  }

  hooks.updateProgress({ stage: 'refining_subtitles', stageProgress: 0 });

  let completed = refinedBySequence.size;
  try {
    await runPool(pending, deps.concurrency ?? 3, hooks.signal, async (segment) => {
      const pieces = await splitIntoDisplaySubClauses(segment, {
        target: job.targetLanguage,
        provider,
        profile: deps.profile ?? PODCAST_PROFILE,
        depth: 0,
        signal: hooks.signal
      });
      refinedBySequence.set(segment.sequence, pieces);
      writeCheckpoint(null);
      completed += 1;
      hooks.heartbeat();
      hooks.updateProgress({
        stage: 'refining_subtitles',
        stageProgress: completed / total
      });
    });
  } catch (error) {
    if (error instanceof Error && error.message === 'cancelled') throw error;
    throw mapRefinementError(error);
  }

  const assembled = enrichSegments(assembleRefined(segments, refinedBySequence));
  writeCheckpoint(assembled);
  return {
    segments: assembled,
    refinedCandidateCount: pending.length,
    totalCandidates: total,
    reusedCheckpoint: false
  };
}

/** LearningPackBuilder parity: collapse whitespace in learningText. */
export function cleanLearningText(text: string): string {
  return text.split(/\s+/).filter((piece) => piece.length > 0).join(' ');
}

export function enrichSegments(segments: LearningSegment[]): LearningSegment[] {
  return segments.map((segment) => ({
    ...segment,
    learningText: cleanLearningText(
      segment.learningText.length === 0 ? segment.text : segment.learningText
    )
  }));
}

interface SplitEnv {
  target: string;
  provider: TranslationProvider;
  profile: SegmentationProfile;
  depth: number;
  signal: AbortSignal;
}

/**
 * Recursively split one translated segment into display sub-clauses, bounded
 * by MAX_RECURSION_DEPTH. Returns `[segment]` unchanged when no split is
 * required or possible; permanent model failures keep the whole sentence.
 */
async function splitIntoDisplaySubClauses(
  segment: LearningSegment,
  env: SplitEnv
): Promise<LearningSegment[]> {
  if (
    env.depth >= MAX_RECURSION_DEPTH ||
    !requiresDisplaySplit(segment.text, segment.translation) ||
    segment.words.length === 0
  ) {
    return [segment];
  }

  const cut = bestBinarySplit(segment.words, env.profile);
  if (cut === null || cut <= 0 || cut >= segment.words.length) {
    return [segment];
  }

  const wordSlices = [segment.words.slice(0, cut), segment.words.slice(cut)];
  const sourcePieces = wordSlices.map((slice) => renderText(slice));
  if (sourcePieces.some((piece) => piece.length === 0)) {
    return [segment];
  }

  const translationPieces = await splitTranslation(segment.translation, sourcePieces.length, env);
  if (!translationPieces || translationPieces.length !== sourcePieces.length) {
    return [segment];
  }

  const playback = {
    id: segment.sequence,
    text: segment.text,
    translation: segment.translation,
    startMS: playbackStartMS(segment),
    endMS: playbackEndMS(segment)
  };

  const result: LearningSegment[] = [];
  for (let index = 0; index < sourcePieces.length; index += 1) {
    const slice = wordSlices[index];
    const startMS = slice[0]?.startMS ?? segment.startMS;
    const sub: LearningSegment = {
      ...segment,
      startMS,
      endMS: Math.max(slice[slice.length - 1]?.endMS ?? segment.endMS, startMS + 1),
      text: sourcePieces[index],
      learningText: sourcePieces[index],
      translation: translationPieces[index],
      words: slice,
      timingSource: 'wordTimeline',
      playbackSentence: playback
    };
    const further = await splitIntoDisplaySubClauses(sub, { ...env, depth: env.depth + 1 });
    result.push(...further);
  }
  return result;
}

/**
 * Split an existing translation into `partCount` parts matching the source
 * split. Returns null on any failure so the caller keeps the whole sentence.
 */
async function splitTranslation(
  translation: string,
  partCount: number,
  env: SplitEnv
): Promise<string[] | null> {
  if (partCount <= 1) return null;
  if (env.signal.aborted) throw new Error('cancelled');
  try {
    const content = await env.provider.chatCompletion({
      systemPrompt: alignedTranslationSplitSystemPrompt(env.target, partCount),
      userPrompt: translation,
      signal: env.signal
    });
    return parseTranslationSplitParts(content, partCount);
  } catch (error) {
    if (error instanceof Error && error.message === 'cancelled') throw error;
    if (env.signal.aborted) throw new Error('cancelled');
    // Permanent model failure: keep the whole-sentence translation.
    return null;
  }
}

async function runPool<T>(
  items: T[],
  concurrency: number,
  signal: AbortSignal,
  worker: (item: T) => Promise<void>
): Promise<void> {
  let next = 0;
  const lanes = Array.from({ length: Math.max(1, Math.min(concurrency, items.length)) }, async () => {
    while (next < items.length) {
      if (signal.aborted) throw new Error('cancelled');
      const item = items[next];
      next += 1;
      await worker(item);
    }
  });
  await Promise.all(lanes);
}

function mapRefinementError(error: unknown): PipelineJobError {
  const mapped = mapTranslationError(error);
  return new PipelineJobError(
    { ...mapped.jobError, failedStage: 'refining_subtitles' },
    error
  );
}
