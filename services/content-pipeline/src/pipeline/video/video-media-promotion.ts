// V12 video media promotion: copy a ready media-api MP4 into the content
// pipeline's own object prefix, verify HEAD/Range, and register a contentKey
// scoped ready asset. Failures never pretend to be ready.

import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, rm, stat, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import type { ServiceConfig } from '../../config.js';
import {
  durationMismatchExceedsThreshold,
  videoRenditionKey,
  type ContentMediaAsset
} from '../../domain/content-media.js';
import { ContentMediaStore } from '../../domain/content-media-store.js';
import type { JobRow } from '../../domain/job-model.js';
import { assertDiskHeadroom } from '../../media/disk-guard.js';
import { downloadToFile, type DownloadOptions, type DownloadResult } from '../../media/downloader.js';
import { probeContainer, type ContainerProbe } from '../../media/ffprobe.js';
import { trustedMediaHostPolicy } from '../../media/trusted-host.js';
import type { RedactingLogger } from '../../observability/logger.js';
import type { KeyLayout } from '../../storage/keys.js';
import { ObjectStoreError, type ObjectStore } from '../../storage/object-store.js';

const RANGE_PROBE_BYTES = 1024;

export class VideoPromotionError extends Error {
  constructor(
    readonly failureCode: string,
    message: string,
    readonly retryable = false
  ) {
    super(message);
    this.name = 'VideoPromotionError';
  }
}

export interface VideoPromotionDeps {
  mediaStore: ContentMediaStore;
  layout: KeyLayout;
  objectStore: ObjectStore;
  config: ServiceConfig;
  logger: RedactingLogger;
  download?: typeof downloadToFile;
  probe?: typeof probeContainer;
  now?: () => number;
}

export interface VideoPromotionInput {
  job: JobRow;
  playbackUrl: string;
  localDir: string;
  signal: AbortSignal;
  onHeartbeat?: () => void;
}

export interface VideoPromotionReady {
  status: 'ready';
  asset: ContentMediaAsset;
  localMp4Path: string | null;
  reused: boolean;
}

export interface VideoPromotionSkipped {
  status: 'skipped';
  reason: 'disabled' | 'budget';
}

export type VideoPromotionResult = VideoPromotionReady | VideoPromotionSkipped;

export async function promoteVideoMedia(
  input: VideoPromotionInput,
  deps: VideoPromotionDeps
): Promise<VideoPromotionResult> {
  const { job, playbackUrl, localDir, signal } = input;
  const { mediaStore, layout, objectStore, config, logger } = deps;
  const download = deps.download ?? downloadToFile;
  const probe = deps.probe ?? probeContainer;
  const now = deps.now ?? Date.now;

  if (!config.videoMediaPromotionEnabled) {
    return { status: 'skipped', reason: 'disabled' };
  }

  const existing = mediaStore.currentReadyForContent(job.ownerScope, job.contentType, job.contentKey);
  if (existing?.objectKey) {
    try {
      await verifyObject(objectStore, existing.objectKey, existing.bytes ?? 0);
      logger.info('media_promotion', {
        result: 'reused',
        mediaId: existing.mediaId,
        jobId: job.jobId
      });
      return {
        status: 'ready',
        asset: existing,
        localMp4Path: null,
        reused: true
      };
    } catch {
      mediaStore.markInvalid(existing.mediaId, 'MEDIA_INTEGRITY_FAILED', now());
    }
  }

  await mkdir(localDir, { recursive: true });
  await assertDiskHeadroom(localDir, config.diskWatermarkBytes);

  const localMp4Path = join(localDir, 'source.mp4');
  let downloadResult = await cachedVideo(localDir, config.maxMediaBytes, now());
  let ssrf: DownloadOptions['ssrf'];
  if (!downloadResult) {
  try {
    ssrf = await trustedMediaHostPolicy(config.mediaApi.baseUrl, playbackUrl);
  } catch {
    throw new VideoPromotionError('AUDIO_DOWNLOAD_FAILED', 'media service returned an invalid playback url', true);
  }

  try {
    downloadResult = await download(playbackUrl, localMp4Path, {
      maxBytes: config.maxMediaBytes,
      allowedMimePrefixes: ['video/'],
      signal,
      ssrf,
      onProgress: (bytes) => {
        if (bytes % (8 * 1024 * 1024) < 64 * 1024) input.onHeartbeat?.();
      }
    });
  } catch (error) {
    throw new VideoPromotionError(
      'AUDIO_DOWNLOAD_FAILED',
      error instanceof Error ? error.message : String(error),
      true
    );
  }

  await writeFile(join(localDir,'complete.json'), JSON.stringify({bytes:downloadResult.bytes,sha256:downloadResult.sha256,completedAt:now()}));
  }

  const fileStat = await stat(localMp4Path);
  if (fileStat.size !== downloadResult.bytes) {
    throw new VideoPromotionError('ARTIFACT_PUBLISH_FAILED', 'downloaded size mismatch', true);
  }

  const probeResult = await probe(localMp4Path);
  validateContainer(probeResult, config);

  const height = probeResult.height ?? 0;
  const videoCodec = probeResult.videoCodec ?? 'unknown';
  const audioCodec = probeResult.audioCodec ?? 'unknown';
  const renditionKey = videoRenditionKey(height, videoCodec, audioCodec);
  const fingerprint = downloadResult.sha256;
  const retainUntil = now() + config.videoMediaRetentionDays * 86_400_000;

  if (config.videoMediaBudgetBytes > 0) {
    const used = mediaStore.readyBytesTotal();
    if (used + downloadResult.bytes > config.videoMediaBudgetBytes) {
      logger.warn('media_promotion', {
        result: 'budget_exceeded',
        jobId: job.jobId,
        used,
        incoming: downloadResult.bytes
      });
      return { status: 'skipped', reason: 'budget' };
    }
  }

  const promoting = mediaStore.createPromoting({
    ownerScope: job.ownerScope,
    contentType: job.contentType,
    contentKey: job.contentKey,
    renditionKey,
    fingerprint,
    now: now()
  });

  const finalKey = layout.videoMedia(fingerprint);
  layout.assertAllowed(finalKey);
  const tempKey = layout.videoMediaTemp(promoting.mediaId);
  layout.assertAllowed(tempKey);

  try {
    const existingFinal = await objectStore.head(finalKey);
    if (existingFinal && existingFinal.bytes === downloadResult.bytes) {
      await verifyObject(objectStore, finalKey, downloadResult.bytes);
    } else {
      await uploadAndPublish({
        objectStore,
        tempKey,
        finalKey,
        localMp4Path,
        bytes: downloadResult.bytes,
        sha256: fingerprint
      });
    }

    const asset = mediaStore.markReady({
      mediaId: promoting.mediaId,
      objectKey: finalKey,
      mimeType: 'video/mp4',
      bytes: downloadResult.bytes,
      sha256: fingerprint,
      durationSeconds: probeResult.durationSeconds,
      height,
      videoCodec,
      audioCodec,
      acceptRanges: 'bytes',
      retainUntil,
      now: now()
    });
    await objectStore.delete(tempKey).catch(() => undefined);
    logger.info('media_promotion', {
      result: 'promoted',
      mediaId: asset.mediaId,
      jobId: job.jobId,
      bytes: downloadResult.bytes,
      height
    });
    return { status: 'ready', asset, localMp4Path, reused: false };
  } catch (error) {
    await objectStore.delete(tempKey).catch(() => undefined);
    const code = error instanceof VideoPromotionError ? error.failureCode : 'ARTIFACT_PUBLISH_FAILED';
    mediaStore.markInvalid(promoting.mediaId, code, now());
    if (error instanceof VideoPromotionError) throw error;
    throw new VideoPromotionError(
      'ARTIFACT_PUBLISH_FAILED',
      error instanceof Error ? error.message : String(error),
      true
    );
  }
}

function validateContainer(probe: ContainerProbe, config: ServiceConfig): void {
  if (!probe.hasVideo) {
    throw new VideoPromotionError('UNSUPPORTED_AUDIO', 'mp4 has no video track');
  }
  if (!probe.hasAudio) {
    throw new VideoPromotionError('UNSUPPORTED_AUDIO', 'mp4 has no audio track');
  }
  if (probe.durationSeconds > config.maxMediaDurationSeconds) {
    throw new VideoPromotionError(
      'MEDIA_TOO_LONG',
      `duration ${Math.round(probe.durationSeconds)}s exceeds limit ${config.maxMediaDurationSeconds}s`
    );
  }
  const videoDuration = probe.videoDurationSeconds ?? probe.durationSeconds;
  const audioDuration = probe.audioDurationSeconds ?? probe.durationSeconds;
  if (durationMismatchExceedsThreshold(videoDuration, audioDuration)) {
    throw new VideoPromotionError(
      'UNSUPPORTED_AUDIO',
      'video and audio durations differ beyond the subtitle sync threshold'
    );
  }
}

async function uploadAndPublish(input: {
  objectStore: ObjectStore;
  tempKey: string;
  finalKey: string;
  localMp4Path: string;
  bytes: number;
  sha256: string;
}): Promise<void> {
  if (input.objectStore.putStream) {
    await input.objectStore.putStream(
      input.tempKey,
      createReadStream(input.localMp4Path),
      input.bytes,
      'video/mp4'
    );
  } else {
    const { readFile } = await import('node:fs/promises');
    await input.objectStore.put(input.tempKey, await readFile(input.localMp4Path), 'video/mp4');
  }
  await verifyObject(input.objectStore, input.tempKey, input.bytes);
  await input.objectStore.copy(input.tempKey, input.finalKey);
  await verifyObject(input.objectStore, input.finalKey, input.bytes);
  void input.sha256;
}

async function verifyObject(store: ObjectStore, key: string, expectedBytes: number): Promise<void> {
  const head = await store.head(key);
  if (!head || head.bytes !== expectedBytes) {
    throw new VideoPromotionError(
      'MEDIA_INTEGRITY_FAILED',
      `HEAD mismatch for ${expectedBytes} byte object`
    );
  }
  try {
    const firstEnd = Math.min(RANGE_PROBE_BYTES - 1, expectedBytes - 1);
    const first = await store.getRange(key, 0, firstEnd);
    if (expectedBytes > 0 && first.length === 0) {
      throw new VideoPromotionError('MEDIA_INTEGRITY_FAILED', 'first Range returned empty');
    }
    const tailStart = Math.max(0, expectedBytes - RANGE_PROBE_BYTES);
    const last = await store.getRange(key, tailStart, expectedBytes - 1);
    if (expectedBytes > 0 && last.length === 0) {
      throw new VideoPromotionError('MEDIA_INTEGRITY_FAILED', 'tail Range returned empty');
    }
  } catch (error) {
    if (error instanceof VideoPromotionError) throw error;
    if (error instanceof ObjectStoreError) {
      throw new VideoPromotionError('MEDIA_INTEGRITY_FAILED', error.message);
    }
    throw error;
  }
}

export async function hashLocalFile(path: string): Promise<string> {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) {
    hash.update(chunk as Buffer);
  }
  return hash.digest('hex');
}

export async function cleanupLocalDir(dir: string, logger: RedactingLogger, jobId: string): Promise<void> {
  await rm(dir, { recursive: true, force: true }).catch((error) => {
    logger.warn('temp cleanup failed', {
      jobId,
      error: error instanceof Error ? error.message : String(error)
    });
  });
}


/** A complete marker prevents a partial download from being reused after a crash. */
export async function cachedVideo(dir: string, maxBytes: number, now = Date.now()): Promise<DownloadResult | null> {
  try {
    const marker=JSON.parse(await readFile(join(dir,'complete.json'),'utf8')) as {bytes:number;sha256:string;completedAt:number};
    if(!Number.isFinite(marker.completedAt)||now-marker.completedAt>86_400_000||marker.bytes<=0||marker.bytes>maxBytes) return null;
    const filePath=join(dir,'source.mp4');
    if((await stat(filePath)).size!==marker.bytes) return null;
    const hash=createHash('sha256');
    for await (const chunk of createReadStream(filePath)) hash.update(chunk);
    if(hash.digest('hex')!==marker.sha256) return null;
    return {filePath,bytes:marker.bytes,sha256:marker.sha256,contentType:'video/mp4',finalUrl:'',redirects:0};
  } catch { return null; }
}
