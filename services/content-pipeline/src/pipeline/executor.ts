// Pipeline executor (WP4–WP7 composition): the single ContentWorker entry
// point. Dispatches on content type, then runs the shared stage chain —
// audio ingestion → ASR/segmentation → translation → refinement → packaging.
// Every stage is checkpoint-resumable; the executor itself is thin glue.
//
//   podcast_episode: ingestPodcastAudio (WP4)
//   video:           ingestVideoAudio  (WP7 Phase A, via media-api)
//   both:            runAsrStage → runTranslationStage → runRefinementStage
//                    → runPackagingStage (WP5/WP6)

import type { ServiceConfig } from '../config.js';
import type { JobStore } from '../jobs/job-store.js';
import { PipelineJobError, type PipelineExecutor } from '../jobs/worker.js';
import type { RedactingLogger } from '../observability/logger.js';
import type { KeyLayout } from '../storage/keys.js';
import type { ObjectStore } from '../storage/object-store.js';
import type { TranscriptionProvider } from '../providers/asr/types.js';
import type { TranslationProvider } from '../providers/translation/types.js';
import type { MediaServiceClient } from '../providers/media/types.js';
import type { ContentMediaStore } from '../domain/content-media-store.js';
import type { downloadToFile, DownloadOptions } from '../media/downloader.js';
import type { probeMedia } from '../media/ffprobe.js';
import type { SegmentationProfile } from './segmentation/sentence-segmenter.js';
import { PODCAST_PROFILE } from './segmentation/sentence-segmenter.js';
import { ingestPodcastAudio } from './podcast-ingestion.js';
import type { MediaTaskRunner } from './video/media-task-runner.js';
import { ingestVideoAudio } from './video/video-audio.js';
import { runAsrStage } from './asr-stage.js';
import { runTranslationStage } from './translation/translate-stage.js';
import { runRefinementStage } from './refinement/refine-stage.js';
import { runPackagingStage } from './packaging/package-stage.js';

export interface PipelineExecutorDeps {
  store: JobStore;
  layout: KeyLayout;
  objectStore: ObjectStore;
  config: ServiceConfig;
  logger: RedactingLogger;
  asrProvider: TranscriptionProvider;
  translationProvider: TranslationProvider;
  /** Required once video jobs are enabled; absence fails video jobs fast. */
  mediaClient?: MediaServiceClient;
  mediaStore?: ContentMediaStore;
  mediaRunner?: MediaTaskRunner;
  profile?: SegmentationProfile;
  /** Test seams forwarded to the ingestion/ASR stages. */
  download?: typeof downloadToFile;
  probe?: typeof probeMedia;
  ssrf?: DownloadOptions['ssrf'];
}

/**
 * Per-job dependency view: object keys and media-service calls are scoped to
 * the job's owning account so stage code never mixes accounts (V18 WP03).
 */
export function scopeDepsToOwner<T extends { layout: KeyLayout; mediaClient?: MediaServiceClient }>(
  deps: T,
  ownerScope: string
): T {
  const layout = typeof deps.layout.forAccount === 'function' ? deps.layout.forAccount(ownerScope) : deps.layout;
  const mediaClient = deps.mediaClient?.forAccount ? deps.mediaClient.forAccount(ownerScope) : deps.mediaClient;
  return { ...deps, layout, mediaClient };
}

export function createPipelineExecutor(rootDeps: PipelineExecutorDeps): PipelineExecutor {
  const profile = rootDeps.profile ?? PODCAST_PROFILE;
  return async ({ job, signal, heartbeat, updateProgress }) => {
    const hooks = { updateProgress, heartbeat, signal };
    const deps = scopeDepsToOwner(rootDeps, job.ownerScope);

    // 1. Ingest: produce the durable MP3 source artifact + audioReady.
    if (job.contentType === 'podcast_episode') {
      await ingestPodcastAudio(job, deps, hooks);
    } else if (job.contentType === 'video') {
      if (!deps.mediaClient) {
        throw new PipelineJobError({
          code: 'INTERNAL_ERROR',
          message: 'video pipeline requires a configured media service client',
          retryable: false,
          failedStage: 'fetching_audio'
        });
      }
      if(deps.mediaRunner) await deps.mediaRunner.ingest(job,hooks);
      else await ingestVideoAudio(job, { ...deps, mediaClient: deps.mediaClient }, hooks);
    } else {
      throw new PipelineJobError({
        code: 'INTERNAL_ERROR',
        message: `unsupported content type: ${job.contentType as string}`,
        retryable: false,
        failedStage: 'validating_source'
      });
    }

    // 2. Shared chain: transcribe/segment → translate → refine → package.
    await runAsrStage(
      job,
      { ...deps, provider: deps.asrProvider, profile },
      hooks
    );
    await runTranslationStage(
      job,
      { store: deps.store, logger: deps.logger, provider: deps.translationProvider },
      hooks
    );
    await runRefinementStage(
      job,
      { store: deps.store, logger: deps.logger, provider: deps.translationProvider, profile },
      hooks
    );
    const packaged = await runPackagingStage(job, deps, hooks);

    // Returned to ContentWorker.completeJob → artifact_manifest + ready.
    return packaged.manifestRef;
  };
}
