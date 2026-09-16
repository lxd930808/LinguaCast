import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, readFile, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';

import type { ServiceConfig } from '../config.js';
import type { JobRow } from '../domain/job-model.js';
import { PipelineJobError } from '../jobs/worker.js';
import type { JobStore, ProgressUpdate } from '../jobs/job-store.js';
import type { RedactingLogger } from '../observability/logger.js';
import type { KeyLayout } from '../storage/keys.js';
import type { ObjectStore } from '../storage/object-store.js';
import { assertDiskHeadroom } from '../media/disk-guard.js';
import { downloadToFile, type DownloadOptions } from '../media/downloader.js';
import { probeMedia } from '../media/ffprobe.js';
import { ensureStableMp3 } from '../media/transcode.js';

// Podcast audio ingestion (WP4): fetch → probe → normalize to MP3 →
// fingerprint → publish to R2 under the content-pipeline prefix. The audio
// becomes playable (audioReady) as soon as the upload lands, well before
// ASR/translation finish. Source artifacts are shared across variants by
// SHA-256 fingerprint, so a second variant of the same episode skips the
// download entirely.

export interface IngestionHooks {
  updateProgress: (update: ProgressUpdate) => void;
  heartbeat: () => void;
  signal: AbortSignal;
}

export interface IngestionDeps {
  store: JobStore;
  layout: KeyLayout;
  objectStore: ObjectStore;
  config: ServiceConfig;
  logger: RedactingLogger;
  /** Test seam for the HTTP layer (SSRF policy still applies). */
  download?: typeof downloadToFile;
  probe?: typeof probeMedia;
  /** Test seam: allow loopback fixture servers. */
  ssrf?: DownloadOptions['ssrf'];
}

export interface IngestedAudio {
  objectKey: string;
  mimeType: string;
  bytes: number;
  durationSeconds: number;
  sha256: string;
  transcoded: boolean;
  reused: boolean;
}

export async function ingestPodcastAudio(
  job: JobRow,
  deps: IngestionDeps,
  hooks: IngestionHooks
): Promise<IngestedAudio> {
  const { store, layout, objectStore, config, logger } = deps;
  const download = deps.download ?? downloadToFile;
  const probe = deps.probe ?? probeMedia;
  const tempDir = join(config.tempRoot, job.jobId);

  // 0. Disk guard: refuse to start below the watermark.
  await mkdir(tempDir, { recursive: true });
  await assertDiskHeadroom(tempDir, config.diskWatermarkBytes);

  try {
    // 1. Reuse: an identical source artifact already uploaded wins.
    const existing = store.audioArtifactForJob(job.jobId);
    if (existing?.objectKey) {
      const head = await objectStore.head(existing.objectKey).catch(() => null);
      if (head) {
        logger.info('reusing source audio', { jobId: job.jobId, sha256: existing.sha256 });
        hooks.updateProgress({
          stage: 'preparing_audio',
          audioReady: true
        });
        return { ...existing, reused: true };
      }
      logger.warn('source artifact row without object; re-downloading', { jobId: job.jobId });
    }

    // 2. Download to a temp file (streaming, SSRF-guarded).
    hooks.updateProgress({ stage: 'fetching_audio', stageProgress: 0 });
    const rawPath = join(tempDir, 'source.bin');
    const downloadResult = await download(job.source.url, rawPath, {
      maxBytes: config.maxMediaBytes,
      signal: hooks.signal,
      ssrf: deps.ssrf,
      onProgress: (bytes) => {
        // Cheap liveness signal while large files stream.
        if (bytes % (8 * 1024 * 1024) < 64 * 1024) hooks.heartbeat();
      }
    });

    // 3. Probe and duration cap.
    hooks.updateProgress({ stage: 'preparing_audio' });
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

    // 4. Normalize to MP3 (passthrough when already stable).
    const normalized = await ensureStableMp3(
      downloadResult.filePath,
      join(tempDir, 'audio.mp3'),
      inputProbe,
      { maxOutputBytes: config.maxMediaBytes }
    );

    // 5. Fingerprint the final bytes (transcode changes the hash).
    const sha256 = normalized.transcoded
      ? await hashFile(normalized.filePath)
      : downloadResult.sha256;

    // 6. Publish to R2 (streaming when supported), then verify.
    const objectKey = layout.podcastAudio(sha256);
    layout.assertAllowed(objectKey);
    const finalBytes = normalized.transcoded
      ? (await stat(normalized.filePath)).size
      : downloadResult.bytes;
    if (objectStore.putStream) {
      await objectStore.putStream(
        objectKey,
        createReadStream(normalized.filePath),
        finalBytes,
        'audio/mpeg'
      );
    } else {
      await objectStore.put(objectKey, await readFile(normalized.filePath), 'audio/mpeg');
    }
    const head = await objectStore.head(objectKey);
    if (!head || head.bytes !== finalBytes) {
      throw new PipelineJobError({
        code: 'ARTIFACT_PUBLISH_FAILED',
        message: 'audio upload verification failed',
        retryable: true,
        failedStage: 'preparing_audio'
      });
    }

    // 7. Register the shared source artifact and flip audioReady.
    store.registerSourceArtifact({
      jobId: job.jobId,
      kind: 'audio',
      fingerprint: sha256,
      objectKey,
      mimeType: 'audio/mpeg',
      bytes: finalBytes,
      durationSeconds: normalized.probe.durationSeconds,
      sha256,
      transcoded: normalized.transcoded
    });
    hooks.updateProgress({ stage: 'preparing_audio', audioReady: true });
    logger.info('audio ingested', {
      jobId: job.jobId,
      sha256,
      bytes: finalBytes,
      transcoded: normalized.transcoded
    });

    return {
      objectKey,
      mimeType: 'audio/mpeg',
      bytes: finalBytes,
      durationSeconds: normalized.probe.durationSeconds,
      sha256,
      transcoded: normalized.transcoded,
      reused: false
    };
  } finally {
    // 8. Temp cleanup always runs; leftover temp is a retry/alert signal.
    await rm(tempDir, { recursive: true, force: true }).catch((error) => {
      logger.warn('temp cleanup failed', {
        jobId: job.jobId,
        error: error instanceof Error ? error.message : String(error)
      });
    });
  }
}

async function hashFile(path: string): Promise<string> {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) {
    hash.update(chunk as Buffer);
  }
  return hash.digest('hex');
}
