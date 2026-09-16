// Translation stage: numbered batches and JSON single-line fallback. Verified
// rows are checkpointed immediately, even if other rows in the batch fail.

import type { JobRow } from '../../domain/job-model.js';
import { PipelineJobError } from '../../jobs/worker.js';
import type { JobStore, ProgressUpdate } from '../../jobs/job-store.js';
import type { RedactingLogger } from '../../observability/logger.js';
import {
  TranslationProviderError,
  type TranslationProvider
} from '../../providers/translation/types.js';
import { TranslationEmptyContentError } from '../../providers/translation/chat-client.js';
import { maxConcurrentRequests } from '../../providers/translation/policy.js';
import type { LearningSegment } from '../segmentation/types.js';
import {
  batchSystemPrompt,
  contextExtractionSystemPrompt,
  singleSystemPrompt,
  EMPTY_CONTEXT,
  type TranslationContext,
  type TranslationQualityMode
} from './prompts.js';
import { blockContext, sampleContextText, termsMatching } from './context.js';
import { missingSequences, numberedUserPrompt, planBatches, type TranslationBatch } from './batches.js';
import {
  parseContextResponse,
  parsePartialBatchTranslations,
  parseNumberedSingleTranslation,
  TranslationContentError
} from './parse.js';

export interface TranslationStageHooks {
  updateProgress: (update: ProgressUpdate) => void;
  heartbeat: () => void;
  signal: AbortSignal;
}

export interface TranslationStageDeps {
  store: JobStore;
  logger: RedactingLogger;
  provider: TranslationProvider;
  /** Batch content retry rounds, limited to still-untranslated rows. */
  batchContentAttempts?: number;
  /** Per-line fallback attempts (client parity: 3). */
  lineContentAttempts?: number;
  concurrency?: number;
}

export interface TranslationStageResult {
  segments: LearningSegment[];
  sourceFingerprint: string;
  context: TranslationContext;
  translatedCount: number;
  reusedCheckpoint: boolean;
}

interface AsrCheckpointShape {
  sourceFingerprint: string;
  segments: LearningSegment[];
}

interface TranslationCheckpoint {
  schemaVersion: 1;
  sourceFingerprint: string;
  context: TranslationContext;
  /** sequence → translation; JSON object keys are strings. */
  translations: Record<string, string>;
}

export async function runTranslationStage(
  job: JobRow,
  deps: TranslationStageDeps,
  hooks: TranslationStageHooks
): Promise<TranslationStageResult> {
  const { store, logger, provider } = deps;
  const qualityMode: TranslationQualityMode = job.translationQuality;

  // The ASR stage's completed-segments checkpoint is this stage's input.
  const asrCheckpoint = store
    .reusableCheckpoints(job.jobId)
    .filter((c) => c.stage === 'transcribing')
    .map((c) => c.output as Partial<AsrCheckpointShape> | null)
    .find(
      (o) =>
        o !== null &&
        typeof o === 'object' &&
        Array.isArray(o.segments) &&
        typeof o.sourceFingerprint === 'string'
    ) as AsrCheckpointShape | undefined;
  if (!asrCheckpoint) {
    throw new PipelineJobError({
      code: 'INTERNAL_ERROR',
      message: 'translation stage reached without transcribed segments',
      retryable: false,
      failedStage: 'translating'
    });
  }
  const sourceSegments = asrCheckpoint.segments;
  const sourceFingerprint = asrCheckpoint.sourceFingerprint;

  // Resume: a fingerprint-matched translation checkpoint restores context and
  // every completed batch; anything else starts clean.
  const prior = readTranslationCheckpoint(store.reusableCheckpoints(job.jobId), sourceFingerprint);
  const translations = new Map<number, string>(
    Object.entries(prior?.translations ?? {}).map(([k, v]) => [Number(k), v])
  );
  let context: TranslationContext = prior?.context ?? EMPTY_CONTEXT;

  const pending = sourceSegments.filter((segment) => {
    const existing = translations.get(segment.sequence) ?? segment.translation;
    return existing.trim().length === 0;
  });

  if (pending.length === 0) {
    logger.info('translation checkpoint complete; skipping provider', { jobId: job.jobId });
    hooks.updateProgress({ stage: 'translating', stageProgress: 1 });
    return {
      segments: applyTranslations(sourceSegments, translations),
      sourceFingerprint,
      context,
      translatedCount: 0,
      reusedCheckpoint: true
    };
  }

  hooks.updateProgress({ stage: 'translating', stageProgress: 0 });

  // Topic summary + glossary, extracted once. Failure degrades to no context —
  // it never blocks translation (client parity).
  if (!prior) {
    context = await extractContext(provider, sourceSegments, job.targetLanguage, hooks.signal);
  }

  const batches = planBatches(pending);
  const concurrency = deps.concurrency ?? maxConcurrentRequests(provider.name);
  const totalBatches = batches.length;
  let completedBatches = 0;

  const persist = () => {
    store.recordCheckpoint(job.jobId, {
      stage: 'translating',
      inputFingerprint: sourceFingerprint,
      output: {
        schemaVersion: 1,
        sourceFingerprint,
        context,
        translations: Object.fromEntries(translations)
      } satisfies TranslationCheckpoint,
      schemaVersion: 1,
      reusable: true
    });
  };
  // Persist the context immediately so a crash before the first batch does not
  // re-extract it on resume.
  persist();

  try {
    await runPool(batches, concurrency, hooks.signal, async (batch) => {
      const batchTranslations = await translateBatch(batch, {
        allSegments: sourceSegments,
        context,
        qualityMode,
        target: job.targetLanguage,
        provider,
        deps,
        signal: hooks.signal,
        jobId: job.jobId,
        accept: (accepted) => {
          for (const [sequence, translation] of accepted) translations.set(sequence, translation);
          persist();
          hooks.heartbeat();
        }
      });
      for (const [sequence, translation] of batchTranslations) {
        translations.set(sequence, translation);
      }
      persist();
      completedBatches += 1;
      hooks.heartbeat();
      hooks.updateProgress({
        stage: 'translating',
        stageProgress: completedBatches / totalBatches
      });
      logger.info('translation batch persisted', {
        jobId: job.jobId,
        batchId: batch.id,
        done: completedBatches,
        total: totalBatches
      });
    });
  } catch (error) {
    if (error instanceof Error && error.message === 'cancelled') throw error;
    throw mapTranslationError(error);
  }

  return {
    segments: applyTranslations(sourceSegments, translations),
    sourceFingerprint,
    context,
    translatedCount: pending.length,
    reusedCheckpoint: false
  };
}

function readTranslationCheckpoint(
  checkpoints: Array<{ stage: string; output: unknown }>,
  sourceFingerprint: string
): TranslationCheckpoint | null {
  for (const checkpoint of checkpoints) {
    if (checkpoint.stage !== 'translating') continue;
    const output = checkpoint.output as Partial<TranslationCheckpoint> | null;
    if (
      output !== null &&
      typeof output === 'object' &&
      output.sourceFingerprint === sourceFingerprint &&
      typeof output.translations === 'object' &&
      output.translations !== null
    ) {
      return output as TranslationCheckpoint;
    }
  }
  return null;
}

async function extractContext(
  provider: TranslationProvider,
  segments: LearningSegment[],
  target: string,
  signal: AbortSignal
): Promise<TranslationContext> {
  const sample = sampleContextText(segments);
  if (sample.length === 0) return EMPTY_CONTEXT;
  try {
    const raw = await provider.chatCompletion({
      systemPrompt: contextExtractionSystemPrompt(target),
      userPrompt: sample,
      signal
    });
    return parseContextResponse(raw) ?? EMPTY_CONTEXT;
  } catch {
    return EMPTY_CONTEXT;
  }
}

interface BatchEnv {
  allSegments: LearningSegment[];
  context: TranslationContext;
  qualityMode: TranslationQualityMode;
  target: string;
  provider: TranslationProvider;
  deps: TranslationStageDeps;
  signal: AbortSignal;
  jobId: string;
  accept: (translations: ReadonlyMap<number, string>) => void;
}

async function translateBatch(
  batch: TranslationBatch,
  env: BatchEnv
): Promise<Map<number, string>> {
  const { before, after } = blockContext(
    env.allSegments,
    new Set(batch.segments.map((s) => s.sequence))
  );
  const blockText = batch.segments.map((s) => s.text).join('\n');
  const matchedTerms = termsMatching(env.context.terms, blockText);
  const systemPrompt = batchSystemPrompt({
    target: env.target,
    topicSummary: env.context.topicSummary,
    terms: matchedTerms,
    contextBefore: before,
    contextAfter: after,
    qualityMode: env.qualityMode
  });
  const translations = new Map<number, string>();
  const batchAttempts = env.deps.batchContentAttempts ?? 3;
  for (let attempt = 0; attempt < batchAttempts; attempt += 1) {
    const pending = batch.segments.filter((s) => !translations.has(s.sequence));
    if (pending.length === 0) break;
    try {
      const userPrompt = numberedUserPrompt({ id: batch.id, segments: pending });
      const raw = await env.provider.chatCompletion({ systemPrompt, userPrompt, signal: env.signal });
      const parsed = parsePartialBatchTranslations(raw, pending, env.qualityMode);
      for (const [sequence, translation] of parsed.translations) translations.set(sequence, translation);
      if (parsed.translations.size) env.accept(parsed.translations);
      for (const issue of parsed.issues) {
        env.deps.logger.warn('translation content rejected', {
          jobId: env.jobId, batchId: batch.id, attempt: attempt + 1,
          phase: 'batch', ...issue
        });
      }
    } catch (error) {
      if (error instanceof TranslationContentError || error instanceof TranslationEmptyContentError) {
        env.deps.logger.warn('translation content rejected', {
          jobId: env.jobId, batchId: batch.id, attempt: attempt + 1, phase: 'batch',
          kind: error instanceof TranslationContentError ? error.kind : 'missingContent'
        });
        continue;
      }
      throw error;
    }
  }

  const missing = missingSequences(batch, new Set(translations.keys()));
  if (missing.length > 0) {
    // Per-line fallback with the single-line skeleton (client parity).
    const fallback = await translateSegmentsIndividually(
      batch.segments.filter((s) => missing.includes(s.sequence)),
      env
    );
    for (const [sequence, translation] of fallback) {
      if (!translations.has(sequence)) translations.set(sequence, translation);
    }
  }

  const stillMissing = missingSequences(batch, new Set(translations.keys()));
  if (stillMissing.length > 0) {
    throw new PipelineJobError({
      code: 'TRANSLATION_FAILED',
      message: `translation batch ${batch.id} missing ${stillMissing.length} line(s) after fallbacks`,
      retryable: true,
      failedStage: 'translating'
    });
  }
  return translations;
}

async function translateSegmentsIndividually(
  segments: LearningSegment[],
  env: BatchEnv
): Promise<Map<number, string>> {
  const translations = new Map<number, string>();
  const lineAttempts = env.deps.lineContentAttempts ?? 3;
  await runPool(segments, 3, env.signal, async (segment) => {
    const matchedTerms = termsMatching(env.context.terms, segment.text);
    const systemPrompt = singleSystemPrompt({
      target: env.target,
      topicSummary: env.context.topicSummary,
      terms: matchedTerms,
      qualityMode: env.qualityMode
    });
    for (let attempt = 0; attempt < lineAttempts; attempt += 1) {
      try {
        const raw = await env.provider.chatCompletion({
          systemPrompt,
          userPrompt: JSON.stringify({ id: segment.sequence, text: segment.text }),
          signal: env.signal
        });
        translations.set(
          segment.sequence,
          parseNumberedSingleTranslation(raw, segment, env.qualityMode)
        );
        env.accept(new Map([[segment.sequence, translations.get(segment.sequence)!]]));
        return;
      } catch (error) {
        if (error instanceof TranslationContentError || error instanceof TranslationEmptyContentError) {
          env.deps.logger.warn('translation content rejected', {
            jobId: env.jobId, sequence: segment.sequence, attempt: attempt + 1, phase: 'single',
            kind: error instanceof TranslationContentError ? error.kind : 'missingContent'
          });
          continue;
        }
        throw error;
      }
    }
    // Line ultimately unproducible: leave it missing so the batch fails hard.
  });
  return translations;
}

function applyTranslations(
  segments: LearningSegment[],
  translations: ReadonlyMap<number, string>
): LearningSegment[] {
  return segments.map((segment) => {
    const translation = translations.get(segment.sequence)?.trim();
    if (!translation) return segment;
    return { ...segment, translation };
  });
}

/** Stop scheduling on failure and drain in-flight work before returning to the job worker. */
async function runPool<T>(
  items: T[],
  concurrency: number,
  signal: AbortSignal,
  worker: (item: T) => Promise<void>
): Promise<void> {
  let next = 0;
  let failure: { error: unknown } | undefined;
  const lanes = Array.from({ length: Math.max(1, Math.min(concurrency, items.length)) }, async () => {
    try {
      while (!failure && next < items.length) {
        if (signal.aborted) throw new Error('cancelled');
        const item = items[next];
        next += 1;
        await worker(item);
      }
    } catch (error) {
      failure ??= { error };
    }
  });
  await Promise.all(lanes);
  if (failure) throw failure.error;
}

/** Map provider/content failures to stable job error codes. */
export function mapTranslationError(error: unknown): PipelineJobError {
  if (error instanceof PipelineJobError) return error;
  if (error instanceof TranslationProviderError) {
    return new PipelineJobError(
      {
        code: 'TRANSLATION_FAILED',
        message: error.message,
        retryable: error.retryable,
        retryAfterSeconds: error.retryAfterSeconds,
        failedStage: 'translating'
      },
      error
    );
  }
  return new PipelineJobError(
    {
      code: 'TRANSLATION_FAILED',
      message: error instanceof Error ? error.message : String(error),
      retryable: true,
      failedStage: 'translating'
    },
    error
  );
}
