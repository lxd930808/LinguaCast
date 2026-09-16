// Packaging stage (WP6): build the client-facing artifacts — segments.json
// envelope, source.vtt, target.vtt, optional raw transcript — and hand them
// to the atomic publisher. The manifest object is written LAST, so a job can
// never become ready pointing at half-written files.

import type { ServiceConfig } from '../../config.js';
import type { JobRow } from '../../domain/job-model.js';
import { PipelineJobError } from '../../jobs/worker.js';
import type { JobStore, ProgressUpdate } from '../../jobs/job-store.js';
import type { RedactingLogger } from '../../observability/logger.js';
import type { KeyLayout } from '../../storage/keys.js';
import type { ObjectStore } from '../../storage/object-store.js';
import { ArtifactPublisher, type ArtifactFileInput } from '../../storage/publisher.js';
import type { LearningSegment } from '../segmentation/types.js';
import { buildSourceVtt, buildTargetVtt } from './vtt.js';

export interface PackagingStageHooks {
  updateProgress: (update: ProgressUpdate) => void;
  heartbeat: () => void;
  signal: AbortSignal;
}

export interface PackagingStageDeps {
  store: JobStore;
  layout: KeyLayout;
  objectStore: ObjectStore;
  config: ServiceConfig;
  logger: RedactingLogger;
  publisher?: ArtifactPublisher;
}

export interface PackagingStageResult {
  manifest: Record<string, unknown>;
  /** Client-facing ref for ContentJobResponse.artifacts / completeJob. */
  manifestRef: Record<string, unknown>;
}

interface RefinementCheckpointShape {
  sourceFingerprint: string;
  segments: LearningSegment[];
}

interface AsrCheckpointShape {
  sourceFingerprint: string;
  rawTranscriptKey?: string | null;
}

export async function runPackagingStage(
  job: JobRow,
  deps: PackagingStageDeps,
  hooks: PackagingStageHooks
): Promise<PackagingStageResult> {
  const { store, objectStore, logger } = deps;
  hooks.updateProgress({ stage: 'packaging', stageProgress: 0 });

  const checkpoints = store.reusableCheckpoints(job.jobId);
  const refinement = checkpoints
    .filter((c) => c.stage === 'refining_subtitles')
    .map((c) => c.output as Partial<RefinementCheckpointShape> | null)
    .find(
      (o) =>
        o !== null &&
        typeof o === 'object' &&
        Array.isArray(o.segments) &&
        typeof o.sourceFingerprint === 'string'
    ) as RefinementCheckpointShape | undefined;
  if (!refinement) {
    throw new PipelineJobError({
      code: 'INTERNAL_ERROR',
      message: 'packaging stage reached without refined segments',
      retryable: false,
      failedStage: 'packaging'
    });
  }
  const segments = refinement.segments;

  const audio = store.audioArtifactForJob(job.jobId);
  if (!audio?.objectKey) {
    throw new PipelineJobError({
      code: 'INTERNAL_ERROR',
      message: 'packaging stage reached without an ingested audio artifact',
      retryable: false,
      failedStage: 'packaging'
    });
  }

  const segmentsJson = Buffer.from(
    JSON.stringify({
      schemaVersion: 1,
      sourceLanguage: job.sourceLanguage,
      targetLanguage: job.targetLanguage,
      segments
    })
  );
  const files: ArtifactFileInput[] = [
    {
      name: 'segments.json',
      role: 'segments',
      required: true,
      data: segmentsJson,
      mimeType: 'application/json'
    },
    {
      name: 'source.vtt',
      role: 'sourceVtt',
      required: true,
      data: Buffer.from(buildSourceVtt(segments)),
      mimeType: 'text/vtt'
    },
    {
      name: 'target.vtt',
      role: 'targetVtt',
      required: true,
      data: Buffer.from(buildTargetVtt(segments)),
      mimeType: 'text/vtt'
    }
  ];

  // Optional raw ASR transcript: archived under source-transcripts/ by the ASR
  // stage. A fetch failure never blocks readiness (required: false).
  const asr = checkpoints
    .filter((c) => c.stage === 'transcribing')
    .map((c) => c.output as Partial<AsrCheckpointShape> | null)
    .find((o) => o !== null && typeof o === 'object');
  const rawTranscriptKey = asr?.rawTranscriptKey ?? null;
  if (rawTranscriptKey) {
    try {
      const raw = await objectStore.getRange(rawTranscriptKey);
      files.push({
        name: 'raw-transcript.json',
        role: 'rawTranscript',
        required: false,
        data: raw,
        mimeType: 'application/json'
      });
    } catch (error) {
      logger.warn('raw transcript fetch failed; publishing without it', {
        jobId: job.jobId,
        err: String(error)
      });
    }
  }

  const publisher =
    deps.publisher ?? new ArtifactPublisher(objectStore, deps.layout, logger);
  let manifest: Record<string, unknown>;
  try {
    manifest = await publisher.publish({
      jobId: job.jobId,
      contentType: job.contentType,
      contentKey: job.contentKey,
      sourceLanguage: job.sourceLanguage,
      targetLanguage: job.targetLanguage,
      translationQuality: job.translationQuality,
      pipelineVersion: job.pipelineVersion,
      audioFingerprint: audio.sha256,
      sourceFingerprint: refinement.sourceFingerprint,
      audio: {
        mimeType: audio.mimeType,
        bytes: audio.bytes,
        durationSeconds: audio.durationSeconds,
        sha256: audio.sha256,
        transcoded: audio.transcoded
      },
      files
    });
  } catch (error) {
    throw new PipelineJobError(
      {
        code: 'ARTIFACT_PUBLISH_FAILED',
        message: error instanceof Error ? error.message : String(error),
        retryable: true,
        failedStage: 'packaging'
      },
      error
    );
  }

  hooks.updateProgress({ stage: 'packaging', stageProgress: 1 });
  return { manifest, manifestRef: publisher.manifestRef(manifest) };
}
