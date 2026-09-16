import { createHash } from 'node:crypto';
import { mkdir, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';

import type { ServiceConfig } from '../config.js';
import type { JobRow } from '../domain/job-model.js';
import { PipelineJobError } from '../jobs/worker.js';
import type { JobStore, ProgressUpdate } from '../jobs/job-store.js';
import type { RedactingLogger } from '../observability/logger.js';
import type { KeyLayout } from '../storage/keys.js';
import type { ObjectStore } from '../storage/object-store.js';
import {
  AsrProviderError,
  AsrSubmissionUncertainError,
  type TranscriptionProvider
} from '../providers/asr/types.js';
import { extractSegments } from '../providers/asr/dashscope-parser.js';
import { downloadToFile, type DownloadOptions } from '../media/downloader.js';
import {
  resegmentLearningSegments,
  PODCAST_PROFILE,
  type SegmentationProfile
} from './segmentation/sentence-segmenter.js';
import type { LearningSegment } from './segmentation/types.js';

// ASR stage (WP5): submit once → persist task ID → bounded polling → fetch the
// raw transcript → deterministic re-segmentation. Restart recovery comes from
// reusable checkpoints: a persisted task ID is resumed, a persisted segment
// set skips the provider entirely.

export interface AsrStageHooks {
  updateProgress: (update: ProgressUpdate) => void;
  heartbeat: () => void;
  signal: AbortSignal;
}

export interface AsrStageDeps {
  store: JobStore;
  layout: KeyLayout;
  objectStore: ObjectStore;
  config: ServiceConfig;
  logger: RedactingLogger;
  provider: TranscriptionProvider;
  profile?: SegmentationProfile;
  pollIntervalMs?: number;
  /** Total poll budget before the task is declared stuck (retry resumes it). */
  pollTimeoutMs?: number;
  signedUrlTtlSeconds?: number;
  download?: typeof downloadToFile;
  ssrf?: DownloadOptions['ssrf'];
}

export interface AsrStageResult {
  segments: LearningSegment[];
  /** sha256 over the canonical segment JSON — the translation reuse boundary. */
  sourceFingerprint: string;
  rawTranscriptKey: string | null;
  reusedCheckpoint: boolean;
}

interface SubmitCheckpoint {
  provider: string;
  taskId: string;
  audioFingerprint: string;
}

interface SegmentsCheckpoint {
  sourceFingerprint: string;
  rawTranscriptKey: string | null;
  segments: LearningSegment[];
}

export async function runAsrStage(
  job: JobRow,
  deps: AsrStageDeps,
  hooks: AsrStageHooks
): Promise<AsrStageResult> {
  const { store, config, logger, provider } = deps;
  const audio = store.audioArtifactForJob(job.jobId);
  if (!audio?.objectKey) {
    throw new PipelineJobError({
      code: 'INTERNAL_ERROR',
      message: 'ASR stage reached without an ingested audio artifact',
      retryable: false,
      failedStage: 'transcribing'
    });
  }

  // 0. Completed-segments checkpoint wins over everything (crash after parse).
  const reusable = store.reusableCheckpoints(job.jobId);
  const doneCheckpoint = reusable
    .filter((c) => c.stage === 'transcribing')
    .map((c) => c.output as Partial<SegmentsCheckpoint> | null)
    .find(
      (o) =>
        o !== null &&
        typeof o === 'object' &&
        Array.isArray(o.segments) &&
        typeof o.sourceFingerprint === 'string' &&
        o.sourceFingerprint.startsWith(sha256Prefix(audio.sha256))
    );
  if (doneCheckpoint) {
    logger.info('reusing transcribed segments checkpoint', { jobId: job.jobId });
    hooks.updateProgress({ stage: 'segmenting' });
    return {
      segments: doneCheckpoint.segments as LearningSegment[],
      sourceFingerprint: (doneCheckpoint as SegmentsCheckpoint).sourceFingerprint,
      rawTranscriptKey: (doneCheckpoint as SegmentsCheckpoint).rawTranscriptKey ?? null,
      reusedCheckpoint: true
    };
  }

  hooks.updateProgress({ stage: 'transcribing', stageProgress: 0 });

  // 1. Resume a persisted task ID, or submit exactly once and persist it.
  const submitCheckpoint = reusable
    .filter((c) => c.stage === 'transcribing')
    .map((c) => c.output as Partial<SubmitCheckpoint> | null)
    .find(
      (o) =>
        o !== null &&
        typeof o === 'object' &&
        typeof o.taskId === 'string' &&
        o.provider === provider.name &&
        o.audioFingerprint === audio.sha256 &&
        !('segments' in o)
    );

  let taskId: string;
  if (submitCheckpoint) {
    taskId = submitCheckpoint.taskId as string;
    logger.info('resuming ASR task from checkpoint', { jobId: job.jobId });
  } else {
    // The provider fetches the audio via a pre-signed URL. The URL is passed
    // over TLS to the provider and is never logged or persisted.
    const signedUrl = await deps.objectStore.presignGet(
      audio.objectKey,
      deps.signedUrlTtlSeconds ?? 3600
    );
    try {
      taskId = await provider.submit({ audioUrl: signedUrl, language: job.sourceLanguage });
    } catch (error) {
      throw mapAsrError(error);
    }
    store.recordCheckpoint(job.jobId, {
      stage: 'transcribing',
      inputFingerprint: audio.sha256,
      output: { provider: provider.name, taskId, audioFingerprint: audio.sha256 },
      schemaVersion: 1,
      reusable: true
    });
  }

  // 2. Bounded polling with restart-safe state (task ID is durable now).
  const pollIntervalMs = deps.pollIntervalMs ?? 5_000;
  const pollTimeoutMs = deps.pollTimeoutMs ?? 30 * 60 * 1000;
  const deadline = Date.now() + pollTimeoutMs;
  let transcriptionUrl: string | null = null;

  while (Date.now() < deadline) {
    if (hooks.signal.aborted) throw new Error('cancelled');
    hooks.heartbeat();
    let poll;
    try {
      poll = await provider.poll(taskId);
    } catch (error) {
      throw mapAsrError(error);
    }
    if (poll.status === 'SUCCEEDED' && poll.transcriptionUrl) {
      transcriptionUrl = poll.transcriptionUrl;
      break;
    }
    hooks.updateProgress({ stage: 'transcribing' });
    await sleep(poll.retryAfterMs ?? pollIntervalMs, hooks.signal);
  }
  if (!transcriptionUrl) {
    // Timed out locally; the task ID is persisted so a retry resumes polling.
    throw new PipelineJobError({
      code: 'ASR_FAILED',
      message: `ASR task did not finish within ${Math.round(pollTimeoutMs / 60000)} minutes`,
      retryable: true,
      failedStage: 'transcribing'
    });
  }

  // 3. Download the raw transcript and archive it under source-transcripts/.
  const tempDir = join(config.tempRoot, job.jobId);
  await mkdir(tempDir, { recursive: true });
  const rawPath = join(tempDir, 'asr-result.json');
  let rawSha: string;
  let rawBytes: Buffer;
  try {
    const download = deps.download ?? downloadToFile;
    const raw = await download(transcriptionUrl, rawPath, {
      maxBytes: 64 * 1024 * 1024,
      signal: hooks.signal,
      ssrf: deps.ssrf,
      allowedMimePrefixes: ['application/json', 'text/', 'application/octet-stream']
    });
    rawSha = raw.sha256;
    rawBytes = await readFile(rawPath);
    const rawKey = deps.layout.sourceTranscript(rawSha);
    deps.layout.assertAllowed(rawKey);
    await deps.objectStore.put(rawKey, rawBytes, 'application/json');
    store.registerSourceArtifact({
      jobId: job.jobId,
      kind: 'raw_transcript',
      fingerprint: rawSha,
      objectKey: rawKey,
      mimeType: 'application/json',
      bytes: rawBytes.length
    });
  } finally {
    await rm(join(config.tempRoot, job.jobId), { recursive: true, force: true }).catch(() => {});
  }

  // 4. Parse + validate + deterministically re-segment.
  hooks.updateProgress({ stage: 'segmenting' });
  let payload: unknown;
  try {
    payload = JSON.parse(rawBytes.toString('utf8'));
  } catch {
    throw new PipelineJobError({
      code: 'ASR_FAILED',
      message: 'ASR result is not valid JSON',
      retryable: false,
      failedStage: 'transcribing'
    });
  }
  const parsed = extractSegments(payload);
  validateSegments(parsed);
  const segments = resegmentLearningSegments(parsed, deps.profile ?? PODCAST_PROFILE);

  const sourceFingerprint = sha256Prefix(audio.sha256) + canonicalFingerprint(segments);

  store.recordCheckpoint(job.jobId, {
    stage: 'transcribing',
    inputFingerprint: audio.sha256,
    output: {
      sourceFingerprint,
      rawTranscriptKey: deps.layout.sourceTranscript(rawSha),
      segments
    } satisfies SegmentsCheckpoint,
    schemaVersion: 1,
    reusable: true
  });

  return { segments, sourceFingerprint, rawTranscriptKey: deps.layout.sourceTranscript(rawSha), reusedCheckpoint: false };
}

/**
 * Stable sanity checks (WP5 task 8): empty recognition and non-monotonic word
 * timelines are definitive ASR failures, not silent pass-throughs.
 */
export function validateSegments(segments: LearningSegment[]): void {
  if (segments.length === 0) {
    throw new PipelineJobError({
      code: 'ASR_FAILED',
      message: 'ASR returned an empty recognition',
      retryable: false,
      failedStage: 'transcribing'
    });
  }
  for (const segment of segments) {
    for (let i = 1; i < segment.words.length; i += 1) {
      if (segment.words[i].startMS < segment.words[i - 1].startMS - 1000) {
        throw new PipelineJobError({
          code: 'ASR_FAILED',
          message: `non-monotonic word timeline in sentence ${segment.sequence}`,
          retryable: false,
          failedStage: 'segmenting'
        });
      }
    }
  }
}

function mapAsrError(error: unknown): PipelineJobError {
  if (error instanceof AsrSubmissionUncertainError) {
    return new PipelineJobError(
      {
        code: 'ASR_SUBMISSION_UNCERTAIN',
        message: error.message,
        retryable: false,
        failedStage: 'transcribing'
      },
      error
    );
  }
  if (error instanceof AsrProviderError) {
    return new PipelineJobError(
      {
        code: 'ASR_FAILED',
        message: error.message,
        retryable: error.retryable,
        retryAfterSeconds: error.retryAfterSeconds,
        failedStage: 'transcribing'
      },
      error
    );
  }
  if (error instanceof PipelineJobError) return error;
  return new PipelineJobError(
    {
      code: 'ASR_FAILED',
      message: error instanceof Error ? error.message : String(error),
      retryable: true,
      failedStage: 'transcribing'
    },
    error
  );
}

/** Stable fingerprint of the segment list (translation reuse boundary). */
export function canonicalFingerprint(segments: LearningSegment[]): string {
  const canonical = segments.map((s) => ({
    sequence: s.sequence,
    startMS: s.startMS,
    endMS: s.endMS,
    text: s.text,
    speaker: s.speaker ?? null,
    words: s.words.map((w) => [w.text, w.startMS, w.endMS, w.punctuation ?? null])
  }));
  return createHash('sha256').update(JSON.stringify(canonical)).digest('hex');
}

function sha256Prefix(value: string): string {
  return `${value.slice(0, 16)}:`;
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => resolve(), ms);
    timer.unref?.();
    signal?.addEventListener('abort', () => {
      clearTimeout(timer);
      reject(new Error('cancelled'));
    }, { once: true });
  });
}
