// Video audio stage (WP7 Phase A): ask the media service to prepare the
// video's audio, poll to a terminal state, then IMMEDIATELY copy the audio
// into our own temp space + R2 — media jobs expire (~45 min TTL), so the
// audioUrl is never stored as a durable reference. The result is the same
// IngestedAudio contract the podcast path produces, so ASR/segmentation/
// translation/packaging run unchanged.
//
// Zero-impact rules honored here:
//  - media-api is reached over HTTP only (no data volume, no Docker network).
//  - at most one media job in flight (worker serialization + gate).
//  - terminal statuses and 410 expired are respected; the media job is
//    cancelled best-effort once the audio copy is safely uploaded.

import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, readFile, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';

import type { ServiceConfig } from '../../config.js';
import type { JobRow } from '../../domain/job-model.js';
import { PipelineJobError } from '../../jobs/worker.js';
import type { JobStore, ProgressUpdate } from '../../jobs/job-store.js';
import type { RedactingLogger } from '../../observability/logger.js';
import type { KeyLayout } from '../../storage/keys.js';
import type { ObjectStore } from '../../storage/object-store.js';
import type { ContentMediaStore } from '../../domain/content-media-store.js';
import { assertDiskHeadroom } from '../../media/disk-guard.js';
import { downloadToFile } from '../../media/downloader.js';
import { probeMedia } from '../../media/ffprobe.js';
import { trustedMediaHostPolicy } from '../../media/trusted-host.js';
import { ensureStableMp3 } from '../../media/transcode.js';
import {
  MediaServiceError,
  type MediaJobErrorCode,
  type MediaJobView,
  type MediaServiceClient
} from '../../providers/media/types.js';
import type { IngestedAudio } from '../podcast-ingestion.js';
import { promoteVideoMedia, VideoPromotionError, cachedVideo } from './video-media-promotion.js';

export interface VideoAudioHooks {
  updateProgress: (update: ProgressUpdate) => void;
  heartbeat: () => void;
  signal: AbortSignal;
}

export interface VideoAudioDeps {
  store: JobStore;
  layout: KeyLayout;
  objectStore: ObjectStore;
  config: ServiceConfig;
  logger: RedactingLogger;
  mediaClient: MediaServiceClient;
  mediaStore?: ContentMediaStore;
  pollIntervalMs?: number;
  /** Total budget for the media job before giving up (retryable). */
  pollTimeoutMs?: number;
  /** Copy window guard: refuse to start a download this close to expiry. */
  copySafetyMarginMs?: number;
  /** Test seams (same pattern as podcast ingestion). */
  download?: typeof downloadToFile;
  probe?: typeof probeMedia;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
}

/** 'fetching_audio' floor→ceiling from the contract; media progress maps inside. */
const FETCH_FLOOR = 0.03;
const FETCH_CEILING = 0.25;
const DEFAULT_POLL_INTERVAL_MS = 5_000;
const DEFAULT_POLL_TIMEOUT_MS = 60 * 60 * 1000;
const DEFAULT_COPY_MARGIN_MS = 60_000;

interface MediaJobCheckpoint {
  mediaJobId: string;
  videoId: string;
  promotionFailureCode?: string;
  promotion?: 'ready' | 'skipped' | 'failed' | 'pending';
}

export async function ingestVideoAudio(
  job: JobRow,
  deps: VideoAudioDeps,
  hooks: VideoAudioHooks
): Promise<IngestedAudio> {
  const { store, layout, objectStore, config, logger, mediaClient, mediaStore } = deps;
  const download = deps.download ?? downloadToFile;
  const probe = deps.probe ?? probeMedia;
  const sleep = deps.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
  const now = deps.now ?? Date.now;
  const pollIntervalMs = deps.pollIntervalMs ?? DEFAULT_POLL_INTERVAL_MS;
  const pollTimeoutMs = deps.pollTimeoutMs ?? DEFAULT_POLL_TIMEOUT_MS;
  const copyMarginMs = deps.copySafetyMarginMs ?? DEFAULT_COPY_MARGIN_MS;

  const videoId = job.source.sourceId;
  const tempDir = join(config.tempRoot, job.jobId);

  const existingAudio = store.audioArtifactForJob(job.jobId);
  const existingVideo =
    mediaStore?.currentReadyForContent(job.ownerScope, job.contentType, job.contentKey) ?? null;
  // A database row alone does not prove the stored file still exists.
  if(existingVideo?.objectKey) {
    const head=await objectStore.head(existingVideo.objectKey);
    if(!head || head.bytes!==existingVideo.bytes) mediaStore?.markInvalid(existingVideo.mediaId,'MEDIA_INTEGRITY_FAILED');
  }
  const readyVideo=mediaStore?.currentReadyForContent(job.ownerScope,job.contentType,job.contentKey);
  const wantVideo = Boolean(config.videoMediaPromotionEnabled && mediaStore && !readyVideo);
  const mediaCacheDir=join(config.tempRoot,'media-cache',String(mediaStore?.contentIdForJob(job.jobId) ?? job.jobId));
  if(wantVideo && mediaStore && existingAudio?.objectKey && await cachedVideo(mediaCacheDir,config.maxMediaBytes,now())) {
    try {
      const promoted=await promoteVideoMedia({job,playbackUrl:'',localDir:mediaCacheDir,signal:hooks.signal,onHeartbeat:hooks.heartbeat},
        {mediaStore,layout,objectStore,config,logger,download,now});
      if(promoted.status==='ready' && await objectStore.head(existingAudio.objectKey)) return {...existingAudio,reused:true};
      store.recordCheckpoint(job.jobId,{stage:'fetching_audio',output:{promotionFailureCode:'MEDIA_BUDGET_EXCEEDED'}});
    } catch(error) {
      store.recordCheckpoint(job.jobId,{stage:'fetching_audio',output:{promotionFailureCode:error instanceof VideoPromotionError ? error.failureCode : 'VIDEO_SAVE_FAILED'}});
    }
    if(await objectStore.head(existingAudio.objectKey)) return {...existingAudio,reused:true};
  }

  // Reuse: skip media-api only when audio is durable AND we do not still
  // need to promote a video asset.
  if (existingAudio?.objectKey && !wantVideo) {
    const head = await objectStore.head(existingAudio.objectKey).catch(() => null);
    if (head) {
      logger.info('reusing source audio', { jobId: job.jobId, sha256: existingAudio.sha256 });
      hooks.updateProgress({ stage: 'preparing_audio', audioReady: true });
      return { ...existingAudio, reused: true };
    }
    logger.warn('source artifact row without object; re-preparing', { jobId: job.jobId });
  }

  await mkdir(tempDir, { recursive: true });
  await assertDiskHeadroom(tempDir, config.diskWatermarkBytes);

  // 1. Resume an in-flight media job from checkpoint, else prepare a new one.
  const prepareFreshMediaJob = async (): Promise<string> => {
    const prepared = await callMedia(() =>
      mediaClient.prepare({ videoId, mode: 'mp4' }, hooks.signal)
    );
    store.recordCheckpoint(job.jobId, {
      stage: 'fetching_audio',
      inputFingerprint: videoId,
      output: { mediaJobId: prepared.jobId, videoId } satisfies MediaJobCheckpoint,
      reusable: true
    });
    return prepared.jobId;
  };
  // A resumed checkpoint can point at a media job that already reached a
  // terminal state (failed/evicted/expired) while this content job waited to
  // be retried. Such a checkpoint is re-preparable ONCE per invocation; a
  // fresh job's own failure still fails the stage normally.
  let checkpointReprepareLeft = false;
  const checkpoint = mediaJobCheckpoint(store, job.jobId, videoId);
  let mediaJobId: string;
  if (checkpoint) {
    mediaJobId = checkpoint.mediaJobId;
    checkpointReprepareLeft = true;
    logger.info('resuming media job', { jobId: job.jobId });
  } else {
    mediaJobId = await prepareFreshMediaJob();
  }
  const reprepare = async (reason: string): Promise<void> => {
    logger.info('resumed media job unusable; preparing fresh', {
      jobId: job.jobId,
      mediaJobId,
      reason
    });
    // Best-effort release; also resets the single-flight gate for re-prepare.
    await mediaClient.cancel(mediaJobId).catch(() => undefined);
    mediaJobId = await prepareFreshMediaJob();
    checkpointReprepareLeft = false;
  };

  // 2. Poll to a terminal state, mapping progress into the contract band.
  const pollDeadline = now() + pollTimeoutMs;
  let playbackAudioUrl: string | null = null;
  let playbackVideoUrl: string | null = null;
  let mediaExpiresAt = 0;
  for (;;) {
    hooks.heartbeat();
    if (hooks.signal.aborted) {
      throw new PipelineJobError({
        code: 'INTERNAL_ERROR',
        message: 'cancelled while waiting for media job',
        retryable: false,
        failedStage: 'fetching_audio'
      });
    }
    let view: MediaJobView;
    try {
      view = await mediaClient.getJob(mediaJobId, hooks.signal);
    } catch (error) {
      if (
        checkpointReprepareLeft &&
        error instanceof MediaServiceError &&
        (error.kind === 'not_found' || error.kind === 'expired')
      ) {
        await reprepare(error.kind);
        continue;
      }
      if (error instanceof MediaServiceError) throw mapMediaServiceError(error);
      throw error;
    }
    hooks.updateProgress({
      stage: 'fetching_audio',
      stageProgress:
        FETCH_FLOOR + (FETCH_CEILING - FETCH_FLOOR) * clamp01(view.progress)
    });

    if (view.status === 'ready') {
      const hasAudio = Boolean(view.playback?.audioUrl);
      const hasVideo = Boolean(view.playback?.url);
      if (!hasAudio && !hasVideo) {
        throw new PipelineJobError({
          code: 'INTERNAL_ERROR',
          message: 'media job ready without playback url or audioUrl',
          retryable: false,
          failedStage: 'fetching_audio'
        });
      }
      if (!wantVideo && !hasAudio) {
        throw new PipelineJobError({
          code: 'INTERNAL_ERROR',
          message: 'media job ready without an audioUrl',
          retryable: false,
          failedStage: 'fetching_audio'
        });
      }
      playbackAudioUrl = view.playback?.audioUrl ?? null;
      playbackVideoUrl = view.playback?.url || null;
      mediaExpiresAt = view.expiresAt;
      break;
    }
    if (view.status === 'failed') {
      if (checkpointReprepareLeft) {
        // The checkpointed media job died before we resumed it (e.g. YouTube
        // changed its CDN rules while this content job was waiting to retry).
        // Re-throwing here would pin the content job to a dead media job
        // across every retry; prepare a fresh media job once instead.
        await reprepare('already_failed');
        continue;
      }
      throw mapMediaJobFailure(view.errorCode, view.errorMessage);
    }
    if (now() > pollDeadline) {
      throw new PipelineJobError({
        code: 'SOURCE_UNAVAILABLE',
        message: 'media job did not finish within the poll budget',
        retryable: true,
        retryAfterSeconds: Math.round(pollIntervalMs / 1000),
        failedStage: 'fetching_audio'
      });
    }
    await sleep(pollIntervalMs);
  }

  // 3. Copy the audio NOW. Guard against a URL that expires mid-download.
  if (mediaExpiresAt > 0 && mediaExpiresAt - now() < copyMarginMs) {
    throw new PipelineJobError({
      code: 'AUDIO_DOWNLOAD_FAILED',
      message: 'media audio expires too soon to copy safely',
      retryable: true,
      retryAfterSeconds: 60,
      failedStage: 'fetching_audio'
    });
  }

  try {
    let promotionFailureCode: string | undefined;
    let promotionStatus: 'ready' | 'skipped' | 'failed' | 'pending' = 'pending';
    let localMp4Path: string | null = null;
    if (wantVideo && mediaStore && playbackVideoUrl) {
      try {
        const promoted = await promoteVideoMedia(
          {
            job,
            playbackUrl: playbackVideoUrl,
            localDir: mediaCacheDir,
            signal: hooks.signal,
            onHeartbeat: hooks.heartbeat
          },
          {
            mediaStore,
            layout,
            objectStore,
            config,
            logger,
            download,
            now
          }
        );
        if (promoted.status === 'ready') {
          promotionStatus = 'ready';
          localMp4Path = promoted.localMp4Path;
        } else {
          promotionStatus = 'skipped';
          promotionFailureCode = promoted.reason === 'budget' ? 'MEDIA_BUDGET_EXCEEDED' : 'MEDIA_DISABLED';
        }
      } catch (error) {
        promotionStatus = 'failed';
        promotionFailureCode = error instanceof VideoPromotionError ? error.failureCode : 'VIDEO_SAVE_FAILED';
        logger.warn('media_promotion', {
          result: 'failed',
          jobId: job.jobId,
          code: error instanceof VideoPromotionError ? error.failureCode : 'INTERNAL_ERROR'
        });
      }
    } else if (!wantVideo) {
      promotionStatus = existingVideo ? 'ready' : 'skipped';
    }

    store.recordCheckpoint(job.jobId, {
      stage: 'fetching_audio',
      inputFingerprint: videoId,
      output: { mediaJobId, videoId, promotion: promotionStatus, promotionFailureCode } satisfies MediaJobCheckpoint,
      reusable: true
    });

    if (existingAudio?.objectKey) {
      const audioHead = await objectStore.head(existingAudio.objectKey).catch(() => null);
      if (audioHead) {
        await mediaClient.cancel(mediaJobId).catch(() => undefined);
        hooks.updateProgress({ stage: 'preparing_audio', audioReady: true });
        return { ...existingAudio, reused: true };
      }
    }

    hooks.updateProgress({ stage: 'preparing_audio' });

    if (localMp4Path) {
      try {
        const inputProbe = await probe(localMp4Path);
        if (inputProbe.durationSeconds > config.maxMediaDurationSeconds) {
          throw new PipelineJobError({
            code: 'MEDIA_TOO_LONG',
            message:
              `duration ${Math.round(inputProbe.durationSeconds)}s exceeds limit ` +
              `${config.maxMediaDurationSeconds}s`,
            retryable: false,
            failedStage: 'fetching_audio',
            params: { maxDurationSeconds: config.maxMediaDurationSeconds }
          });
        }
        const normalizedFromMp4 = await ensureStableMp3(
          localMp4Path,
          join(tempDir, 'audio.mp3'),
          inputProbe,
          { maxOutputBytes: config.maxMediaBytes }
        );
        const shaFromMp4 = await hashFile(normalizedFromMp4.filePath);
        const published = await publishVideoAudio({
          job,
          store,
          layout,
          objectStore,
          filePath: normalizedFromMp4.filePath,
          sha256: shaFromMp4,
          bytes: (await stat(normalizedFromMp4.filePath)).size,
          durationSeconds: normalizedFromMp4.probe.durationSeconds,
          transcoded: normalizedFromMp4.transcoded
        });
        hooks.updateProgress({ stage: 'preparing_audio', audioReady: true });
        logger.info('video audio ingested', {
          jobId: job.jobId,
          sha256: published.sha256,
          bytes: published.bytes,
          transcoded: published.transcoded,
          source: 'promoted-mp4'
        });
        await mediaClient.cancel(mediaJobId).catch(() => undefined);
        return published;
      } catch (error) {
        logger.warn('mp4 audio extract failed; falling back to audioUrl', {
          jobId: job.jobId,
          error: error instanceof Error ? error.message : String(error)
        });
      }
    }

    if (!playbackAudioUrl) {
      throw new PipelineJobError({
        code: 'INTERNAL_ERROR',
        message: 'media job ready without an audioUrl and MP4 audio extract failed',
        retryable: false,
        failedStage: 'fetching_audio'
      });
    }

    const ssrf = await trustedMediaHostPolicy(config.mediaApi.baseUrl, playbackAudioUrl);
    const rawPath = join(tempDir, 'source.bin');
    const downloadResult = await download(playbackAudioUrl, rawPath, {
      maxBytes: config.maxMediaBytes,
      signal: hooks.signal,
      ssrf,
      onProgress: (bytes) => {
        if (bytes % (8 * 1024 * 1024) < 64 * 1024) hooks.heartbeat();
      }
    }).catch((error) => {
      throw mapAudioCopyError(error);
    });

    const inputProbe = await probe(downloadResult.filePath);
    if (inputProbe.durationSeconds > config.maxMediaDurationSeconds) {
      throw new PipelineJobError({
        code: 'MEDIA_TOO_LONG',
        message:
          `duration ${Math.round(inputProbe.durationSeconds)}s exceeds limit ` +
          `${config.maxMediaDurationSeconds}s`,
        retryable: false,
        failedStage: 'fetching_audio',
        params: { maxDurationSeconds: config.maxMediaDurationSeconds }
      });
    }
    const normalized = await ensureStableMp3(
      downloadResult.filePath,
      join(tempDir, 'audio.mp3'),
      inputProbe,
      { maxOutputBytes: config.maxMediaBytes }
    );
    const sha256 = normalized.transcoded ? await hashFile(normalized.filePath) : downloadResult.sha256;
    const finalBytes = normalized.transcoded
      ? (await stat(normalized.filePath)).size
      : downloadResult.bytes;
    const published = await publishVideoAudio({
      job,
      store,
      layout,
      objectStore,
      filePath: normalized.filePath,
      sha256,
      bytes: finalBytes,
      durationSeconds: normalized.probe.durationSeconds,
      transcoded: normalized.transcoded
    });
    hooks.updateProgress({ stage: 'preparing_audio', audioReady: true });
    logger.info('video audio ingested', {
      jobId: job.jobId,
      sha256: published.sha256,
      bytes: published.bytes,
      transcoded: published.transcoded,
      source: 'audio-url'
    });

    await mediaClient.cancel(mediaJobId).catch(() => undefined);
    return published;
  } finally {
    await rm(tempDir, { recursive: true, force: true }).catch((error) => {
      logger.warn('temp cleanup failed', {
        jobId: job.jobId,
        error: error instanceof Error ? error.message : String(error)
      });
    });
  }
}

function mediaJobCheckpoint(
  store: JobStore,
  jobId: string,
  videoId: string
): MediaJobCheckpoint | null {
  const found = store
    .reusableCheckpoints(jobId)
    .filter((c) => c.stage === 'fetching_audio')
    .map((c) => c.output as Partial<MediaJobCheckpoint> | null)
    .find(
      (o) =>
        o !== null &&
        typeof o === 'object' &&
        typeof o.mediaJobId === 'string' &&
        o.videoId === videoId
    );
  return found ? { mediaJobId: found.mediaJobId as string, videoId } : null;
}

/** MediaServiceError kinds → stable content-job errors. */
function callMedia<T>(fn: () => Promise<T>): Promise<T> {
  return fn().catch((error: unknown) => {
    if (!(error instanceof MediaServiceError)) throw error;
    throw mapMediaServiceError(error);
  });
}

/** MediaServiceError kind → stable content-job PipelineJobError. */
function mapMediaServiceError(error: MediaServiceError): PipelineJobError {
  switch (error.kind) {
    case 'unauthorized':
      return new PipelineJobError({
        code: 'INTERNAL_ERROR',
        message: 'media-api rejected the configured token',
        retryable: false,
        failedStage: 'fetching_audio'
      });
    case 'not_found':
      // Evicted between prepare and poll; a retry prepares a fresh job.
      return new PipelineJobError({
        code: 'AUDIO_DOWNLOAD_FAILED',
        message: 'media job vanished before completion',
        retryable: true,
        retryAfterSeconds: 5,
        failedStage: 'fetching_audio'
      });
    case 'expired':
      return new PipelineJobError({
        code: 'AUDIO_DOWNLOAD_FAILED',
        message: 'media job expired before the audio was copied',
        retryable: true,
        retryAfterSeconds: 60,
        failedStage: 'fetching_audio'
      });
    case 'disk_full':
      return new PipelineJobError({
        code: 'STORAGE_FULL',
        message: 'media service disk is full',
        retryable: true,
        retryAfterSeconds: 300,
        failedStage: 'fetching_audio'
      });
    case 'busy':
      return new PipelineJobError({
        code: 'QUEUE_BUSY',
        message: 'media service is busy',
        retryable: true,
        retryAfterSeconds: error.options.retryAfterSeconds ?? 30,
        failedStage: 'fetching_audio'
      });
    case 'invalid_request':
      return new PipelineJobError({
        code: 'SOURCE_UNAVAILABLE',
        message: `media-api rejected the request: ${error.message}`,
        retryable: false,
        failedStage: 'fetching_audio'
      });
    default:
      return new PipelineJobError({
        code: 'SOURCE_UNAVAILABLE',
        message: 'media service unavailable',
        retryable: true,
        retryAfterSeconds: error.options.retryAfterSeconds ?? 30,
        failedStage: 'fetching_audio'
      });
  }
}

/** Terminal media job errorCode → stable content-job error (plan WP7 tests). */
function mapMediaJobFailure(
  errorCode: MediaJobErrorCode | null,
  errorMessage: string | null
): PipelineJobError {
  const message = errorMessage ?? 'media job failed';
  switch (errorCode) {
    case 'VIDEO_UNAVAILABLE':
      return new PipelineJobError({
        code: 'SOURCE_UNAVAILABLE',
        message,
        retryable: false,
        failedStage: 'fetching_audio'
      });
    case 'SABR_ATTESTATION_REQUIRED':
      return new PipelineJobError({
        code: 'SOURCE_RESTRICTED',
        message,
        retryable: false,
        failedStage: 'fetching_audio'
      });
    case 'SABR_REQUEST_FAILED':
    case 'SABR_PARSE_FAILED':
      return new PipelineJobError({
        code: 'SOURCE_RATE_LIMITED',
        message,
        retryable: true,
        retryAfterSeconds: 300,
        failedStage: 'fetching_audio'
      });
    case 'UNSUPPORTED_CODEC':
    case 'FFMPEG_FAILED':
      return new PipelineJobError({
        code: 'UNSUPPORTED_AUDIO',
        message,
        retryable: false,
        failedStage: 'fetching_audio'
      });
    case 'DISK_FULL':
      return new PipelineJobError({
        code: 'STORAGE_FULL',
        message,
        retryable: true,
        retryAfterSeconds: 300,
        failedStage: 'fetching_audio'
      });
    case 'BUSY':
      return new PipelineJobError({
        code: 'QUEUE_BUSY',
        message,
        retryable: true,
        retryAfterSeconds: 30,
        failedStage: 'fetching_audio'
      });
    case 'MEDIA_EXPIRED':
    case 'MEDIA_DOWNLOAD_FAILED':
      return new PipelineJobError({
        code: 'AUDIO_DOWNLOAD_FAILED',
        message,
        retryable: true,
        retryAfterSeconds: 60,
        failedStage: 'fetching_audio'
      });
    default:
      return new PipelineJobError({
        code: 'INTERNAL_ERROR',
        message,
        retryable: true,
        failedStage: 'fetching_audio'
      });
  }
}

function mapAudioCopyError(error: unknown): PipelineJobError {
  if (error instanceof PipelineJobError) return error;
  return new PipelineJobError({
    code: 'AUDIO_DOWNLOAD_FAILED',
    message: error instanceof Error ? error.message : String(error),
    retryable: true,
    retryAfterSeconds: 60,
    failedStage: 'fetching_audio'
  });
}

async function publishVideoAudio(input: {
  job: JobRow;
  store: JobStore;
  layout: KeyLayout;
  objectStore: ObjectStore;
  filePath: string;
  sha256: string;
  bytes: number;
  durationSeconds: number;
  transcoded: boolean;
}): Promise<IngestedAudio> {
  const objectKey = input.layout.videoAudio(input.sha256);
  input.layout.assertAllowed(objectKey);
  if (input.objectStore.putStream) {
    await input.objectStore.putStream(
      objectKey,
      createReadStream(input.filePath),
      input.bytes,
      'audio/mpeg'
    );
  } else {
    await input.objectStore.put(objectKey, await readFile(input.filePath), 'audio/mpeg');
  }
  const head = await input.objectStore.head(objectKey);
  if (!head || head.bytes !== input.bytes) {
    throw new PipelineJobError({
      code: 'ARTIFACT_PUBLISH_FAILED',
      message: 'audio upload verification failed',
      retryable: true,
      failedStage: 'preparing_audio'
    });
  }
  input.store.registerSourceArtifact({
    jobId: input.job.jobId,
    kind: 'audio',
    fingerprint: input.sha256,
    objectKey,
    mimeType: 'audio/mpeg',
    bytes: input.bytes,
    durationSeconds: input.durationSeconds,
    sha256: input.sha256,
    transcoded: input.transcoded
  });
  return {
    objectKey,
    mimeType: 'audio/mpeg',
    bytes: input.bytes,
    durationSeconds: input.durationSeconds,
    sha256: input.sha256,
    transcoded: input.transcoded,
    reused: false
  };
}

function clamp01(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.min(1, Math.max(0, value));
}

async function hashFile(path: string): Promise<string> {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) {
    hash.update(chunk as Buffer);
  }
  return hash.digest('hex');
}
