import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { loadConfig, type ServiceConfig } from '../src/config.js';
import { openDatabase } from '../src/jobs/migrations.js';
import { JobStore, type ProgressUpdate } from '../src/jobs/job-store.js';
import { PipelineJobError } from '../src/jobs/worker.js';
import { RedactingLogger } from '../src/observability/logger.js';
import { KeyLayout } from '../src/storage/keys.js';
import { InMemoryObjectStore } from '../src/storage/object-store.js';
import { videoContentKey } from '../src/domain/content-key.js';
import type { MediaProbe } from '../src/media/ffprobe.js';
import type { DownloadOptions, DownloadResult } from '../src/media/downloader.js';
import {
  MediaServiceError,
  type MediaJobErrorCode,
  type MediaJobStatus,
  type MediaJobView,
  type MediaServiceClient
} from '../src/providers/media/types.js';
import { ingestVideoAudio } from '../src/pipeline/video/video-audio.js';

// Video audio stage tests (WP7 Phase A): fake media client + injected
// download/probe seams; the store, key layout and object store are real.

const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url).pathname;
const VIDEO_ID = 'abcdefghijk';
const MEDIA_BASE = 'http://127.0.0.1:3210';
const AUDIO_BYTES = Buffer.from('fake mp3 bytes for the video audio stage');
const AUDIO_SHA = createHash('sha256').update(AUDIO_BYTES).digest('hex');

const MP3_PROBE: MediaProbe = {
  formatName: 'mp3',
  codecName: 'mp3',
  durationSeconds: 3,
  bitrate: 128_000,
  sampleRate: 44_100,
  channels: 2
};

interface Fixture {
  tempRoot: string;
  store: JobStore;
  config: ServiceConfig;
  layout: KeyLayout;
  objectStore: InMemoryObjectStore;
  logger: RedactingLogger;
  cleanup: () => Promise<void>;
}

async function setupFixture(): Promise<Fixture> {
  const tempRoot = await mkdtemp(join(tmpdir(), 'video-audio-test-'));
  const config = loadConfig({
    CONTENT_IDENTITY_MODE: 'selfhost', CONTENT_SERVICE_TOKEN: 'test-service-token-0123456789',
    MEDIA_API_TOKEN: 'test-media-token-0123456789',
    MEDIA_API_BASE_URL: MEDIA_BASE,
    DASHSCOPE_API_KEY: 'test-dashscope-key-0123456789',
    TRANSLATION_API_KEY: 'test-translation-key-0123456789',
    TRANSLATION_MODEL: 'test-model',
    R2_ACCOUNT_ID: 'acct',
    R2_ACCESS_KEY_ID: 'r2-access',
    R2_SECRET_ACCESS_KEY: 'r2-secret-0123456789',
    R2_BUCKET: 'linguacast',
    CONTENT_TEMP_ROOT: tempRoot
  });
  const db = openDatabase(join(tempRoot, 'content.db'), MIGRATIONS_DIR);
  const store = new JobStore(db);
  return {
    tempRoot,
    store,
    config,
    layout: new KeyLayout(config.r2),
    objectStore: new InMemoryObjectStore(),
    logger: new RedactingLogger(() => {}),
    cleanup: async () => {
      store.close();
      await rm(tempDir(tempRoot), { recursive: true, force: true }).catch(() => {});
      await rm(tempRoot, { recursive: true, force: true });
    }
  };
}

function tempDir(root: string): string {
  return root;
}

interface FakeMedia extends MediaServiceClient {
  prepares: number;
  cancels: string[];
  views: MediaJobView[];
  /** Optional failure injected into getJob. */
  pollError?: MediaServiceError;
}

function fakeMediaClient(statuses: MediaJobStatus[], overrides: Partial<FakeMedia> = {}): FakeMedia {
  const views = statuses.map((status, index) =>
    mediaView(status, index / Math.max(statuses.length, 1))
  );
  const fake: FakeMedia = {
    prepares: 0,
    cancels: [],
    views,
    async prepare() {
      fake.prepares += 1;
      return { jobId: 'mj-1', status: 'queued' };
    },
    async getJob() {
      if (fake.pollError) throw fake.pollError;
      return fake.views.length > 1 ? fake.views.shift()! : fake.views[0]!;
    },
    async cancel(jobId: string) {
      fake.cancels.push(jobId);
    },
    ...overrides
  };
  return fake;
}

function mediaView(status: MediaJobStatus, progress: number): MediaJobView {
  return {
    jobId: 'mj-1',
    videoId: VIDEO_ID,
    status,
    progress,
    expiresAt: Date.now() + 45 * 60_000,
    errorCode: null,
    errorMessage: null,
    playback:
      status === 'ready'
        ? {
            kind: 'mp4',
            url: `${MEDIA_BASE}/media/mj-1/output.mp4`,
            audioUrl: `${MEDIA_BASE}/media/mj-1/audio.m4a?access_token=x`,
            height: 720,
            durationSeconds: 3,
            videoCodec: 'avc1',
            audioCodec: 'aac',
            itagVideo: 22,
            itagAudio: 140
          }
        : null
  };
}

function fakeDownload(captured?: { options?: DownloadOptions }) {
  return async (url: string, filePath: string, options: DownloadOptions): Promise<DownloadResult> => {
    if (captured) captured.options = options;
    await writeFile(filePath, AUDIO_BYTES);
    return {
      filePath,
      bytes: AUDIO_BYTES.length,
      sha256: AUDIO_SHA,
      contentType: 'audio/mp4',
      finalUrl: url,
      redirects: 0
    };
  };
}

function createVideoJob(store: JobStore) {
  store.createJob({
    ownerScope: 'test-owner',
    contentType: 'video',
    contentKey: videoContentKey('youtube', VIDEO_ID),
    source: {
      platform: 'youtube',
      sourceId: VIDEO_ID,
      url: `https://www.youtube.com/watch?v=${VIDEO_ID}`
    },
    sourceLanguage: 'en',
    targetLanguage: 'zh-Hans',
    translationQuality: 'fast',
    pipelineVersion: '1',
    clientArtifactSchemaVersion: 1
  });
  const claimed = store.claimNextJob('test-worker', 60_000);
  assert.ok(claimed, 'expected a claimable job');
  return claimed;
}

function hooks(store: JobStore, jobId: string, progress: ProgressUpdate[]) {
  return {
    updateProgress: (u: ProgressUpdate) => {
      progress.push(u);
      store.updateProgress(jobId, u);
    },
    heartbeat: () => {},
    signal: new AbortController().signal
  };
}

test('prepare → poll → immediate copy → publish → audioReady → cancel', async () => {
  const fx = await setupFixture();
  try {
    const job = createVideoJob(fx.store);
    const media = fakeMediaClient(['queued', 'fetching', 'packaging', 'ready']);
    const progress: ProgressUpdate[] = [];

    const result = await ingestVideoAudio(job, {
      store: fx.store,
      layout: fx.layout,
      objectStore: fx.objectStore,
      config: fx.config,
      logger: fx.logger,
      mediaClient: media,
      pollIntervalMs: 1,
      download: fakeDownload(),
      probe: async () => MP3_PROBE,
      sleep: async () => {}
    }, hooks(fx.store, job.jobId, progress));

    assert.equal(result.reused, false);
    assert.equal(result.transcoded, false);
    assert.equal(result.sha256, AUDIO_SHA);
    assert.match(result.objectKey, /\/video-audio\/[0-9a-f]{64}\.mp3$/);

    // Bytes landed in our object store — the media TTL no longer matters.
    const head = await fx.objectStore.head(result.objectKey);
    assert.ok(head);
    assert.equal(head.bytes, AUDIO_BYTES.length);

    // audioReady flipped on the job row.
    const row = fx.store.getJob(job.jobId);
    assert.equal(row?.audioReady, true);

    // Media job released after the copy (no lingering 45-min TTL work).
    assert.deepEqual(media.cancels, ['mj-1']);
    assert.equal(media.prepares, 1);

    // Media jobId checkpoint persisted for restart resume.
    const checkpoints = fx.store.reusableCheckpoints(job.jobId);
    const fetchCp = checkpoints.find((c) => c.stage === 'fetching_audio');
    assert.ok(fetchCp);
    assert.deepEqual(fetchCp.output, {
      mediaJobId: 'mj-1',
      videoId: VIDEO_ID,
      promotion: 'skipped'
    });

    // Progress stayed inside the fetching_audio band during polling.
    const fetching = progress.filter((p) => p.stage === 'fetching_audio');
    assert.ok(fetching.length >= 2);
  } finally {
    await fx.cleanup();
  }
});

test('an existing source artifact is reused without touching media-api', async () => {
  const fx = await setupFixture();
  try {
    const job = createVideoJob(fx.store);
    const objectKey = fx.layout.videoAudio(AUDIO_SHA);
    await fx.objectStore.put(objectKey, AUDIO_BYTES, 'audio/mpeg');
    fx.store.registerSourceArtifact({
      jobId: job.jobId,
      kind: 'audio',
      fingerprint: AUDIO_SHA,
      objectKey,
      mimeType: 'audio/mpeg',
      bytes: AUDIO_BYTES.length,
      durationSeconds: 3,
      sha256: AUDIO_SHA,
      transcoded: false
    });

    const media = fakeMediaClient(['ready']);
    const result = await ingestVideoAudio(job, {
      store: fx.store,
      layout: fx.layout,
      objectStore: fx.objectStore,
      config: fx.config,
      logger: fx.logger,
      mediaClient: media,
      sleep: async () => {}
    }, hooks(fx.store, job.jobId, []));

    assert.equal(result.reused, true);
    assert.equal(result.objectKey, objectKey);
    assert.equal(media.prepares, 0);
    assert.deepEqual(media.cancels, []);
  } finally {
    await fx.cleanup();
  }
});

test('a persisted mediaJobId checkpoint resumes polling without re-prepare', async () => {
  const fx = await setupFixture();
  try {
    const job = createVideoJob(fx.store);
    fx.store.recordCheckpoint(job.jobId, {
      stage: 'fetching_audio',
      inputFingerprint: VIDEO_ID,
      output: { mediaJobId: 'mj-resumed', videoId: VIDEO_ID },
      reusable: true
    });

    const media = fakeMediaClient(['ready']);
    await ingestVideoAudio(job, {
      store: fx.store,
      layout: fx.layout,
      objectStore: fx.objectStore,
      config: fx.config,
      logger: fx.logger,
      mediaClient: media,
      pollIntervalMs: 1,
      download: fakeDownload(),
      probe: async () => MP3_PROBE,
      sleep: async () => {}
    }, hooks(fx.store, job.jobId, []));

    assert.equal(media.prepares, 0, 'must not prepare a second media job');
    assert.deepEqual(media.cancels, ['mj-resumed']);
  } finally {
    await fx.cleanup();
  }
});

// Production incident 2026-08-29: a content job failed at fetching_audio, and
// every retry resumed the checkpointed (already failed) media job, re-failing
// instantly without ever preparing a fresh one.
test('a resumed checkpoint pointing at a FAILED media job is re-prepared once', async () => {
  const fx = await setupFixture();
  try {
    const job = createVideoJob(fx.store);
    fx.store.recordCheckpoint(job.jobId, {
      stage: 'fetching_audio',
      inputFingerprint: VIDEO_ID,
      output: { mediaJobId: 'mj-dead', videoId: VIDEO_ID },
      reusable: true
    });

    const dead = mediaView('failed', 1);
    dead.jobId = 'mj-dead';
    dead.errorCode = 'MEDIA_DOWNLOAD_FAILED';
    dead.errorMessage = 'HTTP Error 403: Forbidden';
    const freshReady = mediaView('ready', 1);
    freshReady.jobId = 'mj-fresh';
    let prepares = 0;
    const cancels: string[] = [];
    const media: MediaServiceClient = {
      async prepare() {
        prepares += 1;
        return { jobId: 'mj-fresh', status: 'queued' };
      },
      async getJob(jobId: string) {
        return jobId === 'mj-dead' ? dead : freshReady;
      },
      async cancel(jobId: string) {
        cancels.push(jobId);
      }
    };

    const result = await ingestVideoAudio(job, {
      store: fx.store,
      layout: fx.layout,
      objectStore: fx.objectStore,
      config: fx.config,
      logger: fx.logger,
      mediaClient: media,
      pollIntervalMs: 1,
      download: fakeDownload(),
      probe: async () => MP3_PROBE,
      sleep: async () => {}
    }, hooks(fx.store, job.jobId, []));

    assert.equal(result.sha256, AUDIO_SHA);
    assert.equal(prepares, 1, 'exactly one fresh media job');
    assert.deepEqual(cancels, ['mj-dead', 'mj-fresh']);
    // The checkpoint now tracks the fresh media job, not the dead one.
    const cp = fx.store.reusableCheckpoints(job.jobId)
      .find((c) => c.stage === 'fetching_audio');
    assert.deepEqual(cp?.output, {
      mediaJobId: 'mj-fresh',
      videoId: VIDEO_ID,
      promotion: 'skipped'
    });
  } finally {
    await fx.cleanup();
  }
});

test('a resumed checkpoint pointing at a VANISHED media job (404) is re-prepared once', async () => {
  const fx = await setupFixture();
  try {
    const job = createVideoJob(fx.store);
    fx.store.recordCheckpoint(job.jobId, {
      stage: 'fetching_audio',
      inputFingerprint: VIDEO_ID,
      output: { mediaJobId: 'mj-gone', videoId: VIDEO_ID },
      reusable: true
    });

    const freshReady = mediaView('ready', 1);
    freshReady.jobId = 'mj-fresh';
    let prepares = 0;
    const media: MediaServiceClient = {
      async prepare() {
        prepares += 1;
        return { jobId: 'mj-fresh', status: 'queued' };
      },
      async getJob(jobId: string) {
        if (jobId === 'mj-gone') throw new MediaServiceError('not_found', 'evicted');
        return freshReady;
      },
      async cancel() {}
    };

    const result = await ingestVideoAudio(job, {
      store: fx.store,
      layout: fx.layout,
      objectStore: fx.objectStore,
      config: fx.config,
      logger: fx.logger,
      mediaClient: media,
      pollIntervalMs: 1,
      download: fakeDownload(),
      probe: async () => MP3_PROBE,
      sleep: async () => {}
    }, hooks(fx.store, job.jobId, []));

    assert.equal(result.sha256, AUDIO_SHA);
    assert.equal(prepares, 1);
  } finally {
    await fx.cleanup();
  }
});

test('a fresh media job failing terminally still fails the stage (no re-prepare loop)', async () => {
  const fx = await setupFixture();
  try {
    const job = createVideoJob(fx.store);
    const failed = mediaView('failed', 1);
    failed.errorCode = 'MEDIA_DOWNLOAD_FAILED';
    failed.errorMessage = 'HTTP Error 403: Forbidden';
    let prepares = 0;
    const media: MediaServiceClient = {
      async prepare() {
        prepares += 1;
        return { jobId: 'mj-1', status: 'queued' };
      },
      async getJob() {
        return failed;
      },
      async cancel() {}
    };

    await assert.rejects(
      () =>
        ingestVideoAudio(job, {
          store: fx.store,
          layout: fx.layout,
          objectStore: fx.objectStore,
          config: fx.config,
          logger: fx.logger,
          mediaClient: media,
          pollIntervalMs: 1,
          sleep: async () => {}
        }, hooks(fx.store, job.jobId, [])),
      (error: unknown) =>
        error instanceof PipelineJobError &&
        error.jobError.code === 'AUDIO_DOWNLOAD_FAILED' &&
        error.jobError.retryable === true
    );
    assert.equal(prepares, 1, 'no silent re-prepare for a fresh job failure');
  } finally {
    await fx.cleanup();
  }
});

test('terminal media failures map to stable content-job errors', async (t) => {
  const cases: Array<{
    name: string;
    code: MediaJobErrorCode;
    expectCode: string;
    retryable: boolean;
  }> = [
    { name: 'VIDEO_UNAVAILABLE', code: 'VIDEO_UNAVAILABLE', expectCode: 'SOURCE_UNAVAILABLE', retryable: false },
    { name: 'SABR_ATTESTATION_REQUIRED (PO token)', code: 'SABR_ATTESTATION_REQUIRED', expectCode: 'SOURCE_RESTRICTED', retryable: false },
    { name: 'SABR_REQUEST_FAILED (rate limit)', code: 'SABR_REQUEST_FAILED', expectCode: 'SOURCE_RATE_LIMITED', retryable: true },
    { name: 'UNSUPPORTED_CODEC', code: 'UNSUPPORTED_CODEC', expectCode: 'UNSUPPORTED_AUDIO', retryable: false },
    { name: 'DISK_FULL', code: 'DISK_FULL', expectCode: 'STORAGE_FULL', retryable: true },
    { name: 'MEDIA_DOWNLOAD_FAILED', code: 'MEDIA_DOWNLOAD_FAILED', expectCode: 'AUDIO_DOWNLOAD_FAILED', retryable: true }
  ];

  for (const c of cases) {
    await t.test(c.name, async () => {
      const fx = await setupFixture();
      try {
        const job = createVideoJob(fx.store);
        const failed = mediaView('failed', 1);
        failed.errorCode = c.code;
        failed.errorMessage = `upstream said ${c.code}`;
        const media = fakeMediaClient(['fetching'], { views: [mediaView('fetching', 0.5), failed] });

        await assert.rejects(
          () =>
            ingestVideoAudio(job, {
              store: fx.store,
              layout: fx.layout,
              objectStore: fx.objectStore,
              config: fx.config,
              logger: fx.logger,
              mediaClient: media,
              pollIntervalMs: 1,
              sleep: async () => {}
            }, hooks(fx.store, job.jobId, [])),
          (error: unknown) => {
            assert.ok(error instanceof PipelineJobError, 'expected PipelineJobError');
            assert.equal(error.jobError.code, c.expectCode);
            assert.equal(error.jobError.retryable, c.retryable);
            assert.equal(error.jobError.failedStage, 'fetching_audio');
            return true;
          }
        );
      } finally {
        await fx.cleanup();
      }
    });
  }
});

test('ready without audioUrl is a definitive failure', async () => {
  const fx = await setupFixture();
  try {
    const job = createVideoJob(fx.store);
    const ready = mediaView('ready', 1);
    ready.playback = {
      kind: 'hls',
      url: `${MEDIA_BASE}/media/mj-1/master.m3u8`,
      height: null,
      durationSeconds: null,
      videoCodec: null,
      audioCodec: null,
      itagVideo: null,
      itagAudio: null
    };
    const media = fakeMediaClient(['ready'], { views: [ready] });

    await assert.rejects(
      () =>
        ingestVideoAudio(job, {
          store: fx.store,
          layout: fx.layout,
          objectStore: fx.objectStore,
          config: fx.config,
          logger: fx.logger,
          mediaClient: media,
          pollIntervalMs: 1,
          sleep: async () => {}
        }, hooks(fx.store, job.jobId, [])),
      (error: unknown) =>
        error instanceof PipelineJobError &&
        error.jobError.code === 'INTERNAL_ERROR' &&
        error.jobError.retryable === false
    );
  } finally {
    await fx.cleanup();
  }
});

test('audioUrl too close to expiry refuses the copy (retryable)', async () => {
  const fx = await setupFixture();
  try {
    const job = createVideoJob(fx.store);
    const expiring = mediaView('ready', 1);
    expiring.expiresAt = Date.now() + 10_000; // inside the 60s safety margin
    let downloads = 0;
    const media = fakeMediaClient(['ready'], { views: [expiring] });

    await assert.rejects(
      () =>
        ingestVideoAudio(job, {
          store: fx.store,
          layout: fx.layout,
          objectStore: fx.objectStore,
          config: fx.config,
          logger: fx.logger,
          mediaClient: media,
          pollIntervalMs: 1,
          download: async (...args) => {
            downloads += 1;
            return fakeDownload()(args[0], args[1], args[2]);
          },
          probe: async () => MP3_PROBE,
          sleep: async () => {}
        }, hooks(fx.store, job.jobId, [])),
      (error: unknown) =>
        error instanceof PipelineJobError &&
        error.jobError.code === 'AUDIO_DOWNLOAD_FAILED' &&
        error.jobError.retryable === true
    );
    assert.equal(downloads, 0, 'must not start a copy that cannot finish');
  } finally {
    await fx.cleanup();
  }
});

test('media-api transport errors map to stable codes', async (t) => {
  const cases: Array<{ name: string; error: MediaServiceError; expectCode: string; retryable: boolean; retryAfter?: number }> = [
    {
      name: '401 unauthorized → non-retryable INTERNAL_ERROR',
      error: new MediaServiceError('unauthorized', 'bad token'),
      expectCode: 'INTERNAL_ERROR',
      retryable: false
    },
    {
      name: '404 mid-poll → retryable AUDIO_DOWNLOAD_FAILED',
      error: new MediaServiceError('not_found', 'evicted'),
      expectCode: 'AUDIO_DOWNLOAD_FAILED',
      retryable: true
    },
    {
      name: '410 expired → retryable AUDIO_DOWNLOAD_FAILED',
      error: new MediaServiceError('expired', 'gone'),
      expectCode: 'AUDIO_DOWNLOAD_FAILED',
      retryable: true
    },
    {
      name: '507 → retryable STORAGE_FULL',
      error: new MediaServiceError('disk_full', 'no space'),
      expectCode: 'STORAGE_FULL',
      retryable: true
    },
    {
      name: '429 with retryAfter → QUEUE_BUSY with retryAfterSeconds',
      error: new MediaServiceError('busy', 'slow down', { retryAfterSeconds: 45 }),
      expectCode: 'QUEUE_BUSY',
      retryable: true,
      retryAfter: 45
    },
    {
      name: '5xx → retryable SOURCE_UNAVAILABLE',
      error: new MediaServiceError('unavailable', 'boom'),
      expectCode: 'SOURCE_UNAVAILABLE',
      retryable: true
    }
  ];

  for (const c of cases) {
    await t.test(c.name, async () => {
      const fx = await setupFixture();
      try {
        const job = createVideoJob(fx.store);
        const media = fakeMediaClient(['queued'], { pollError: c.error });
        await assert.rejects(
          () =>
            ingestVideoAudio(job, {
              store: fx.store,
              layout: fx.layout,
              objectStore: fx.objectStore,
              config: fx.config,
              logger: fx.logger,
              mediaClient: media,
              pollIntervalMs: 1,
              sleep: async () => {}
            }, hooks(fx.store, job.jobId, [])),
          (error: unknown) => {
            assert.ok(error instanceof PipelineJobError);
            assert.equal(error.jobError.code, c.expectCode);
            assert.equal(error.jobError.retryable, c.retryable);
            if (c.retryAfter !== undefined) {
              assert.equal(error.jobError.retryAfterSeconds, c.retryAfter);
            }
            return true;
          }
        );
      } finally {
        await fx.cleanup();
      }
    });
  }
});

test('SSRF policy: only the configured media host is allowlisted', async () => {
  const fx = await setupFixture();
  try {
    // audioUrl on the media service host → an allowlist is provided.
    const job = createVideoJob(fx.store);
    const captured: { options?: DownloadOptions } = {};
    const media = fakeMediaClient(['ready']);
    await ingestVideoAudio(job, {
      store: fx.store,
      layout: fx.layout,
      objectStore: fx.objectStore,
      config: fx.config,
      logger: fx.logger,
      mediaClient: media,
      pollIntervalMs: 1,
      download: fakeDownload(captured),
      probe: async () => MP3_PROBE,
      sleep: async () => {}
    }, hooks(fx.store, job.jobId, []));
    assert.ok(captured.options?.ssrf, 'media-host download must carry an allowlist');

    // audioUrl on a public host (e.g. R2 presigned) → default public policy.
    const fx2 = await setupFixture();
    try {
      const job2 = createVideoJob(fx2.store);
      const captured2: { options?: DownloadOptions } = {};
      const remote = mediaView('ready', 1);
      remote.playback = {
        kind: 'mp4',
        url: 'https://r2.example.com/signed/output.mp4',
        audioUrl: 'https://r2.example.com/signed/audio.m4a',
        height: 720,
        durationSeconds: 3,
        videoCodec: 'avc1',
        audioCodec: 'aac',
        itagVideo: null,
        itagAudio: null
      };
      const media2 = fakeMediaClient(['ready'], { views: [remote] });
      await ingestVideoAudio(job2, {
        store: fx2.store,
        layout: fx2.layout,
        objectStore: fx2.objectStore,
        config: fx2.config,
        logger: fx2.logger,
        mediaClient: media2,
        pollIntervalMs: 1,
        download: fakeDownload(captured2),
        probe: async () => MP3_PROBE,
        sleep: async () => {}
      }, hooks(fx2.store, job2.jobId, []));
      assert.equal(captured2.options?.ssrf, undefined, 'public URLs keep the default policy');
    } finally {
      await fx2.cleanup();
    }
  } finally {
    await fx.cleanup();
  }
});

test('interrupted download maps to retryable AUDIO_DOWNLOAD_FAILED', async () => {
  const fx = await setupFixture();
  try {
    const job = createVideoJob(fx.store);
    const media = fakeMediaClient(['ready']);
    await assert.rejects(
      () =>
        ingestVideoAudio(job, {
          store: fx.store,
          layout: fx.layout,
          objectStore: fx.objectStore,
          config: fx.config,
          logger: fx.logger,
          mediaClient: media,
          pollIntervalMs: 1,
          download: async () => {
            throw new Error('socket hang up');
          },
          probe: async () => MP3_PROBE,
          sleep: async () => {}
        }, hooks(fx.store, job.jobId, [])),
      (error: unknown) =>
        error instanceof PipelineJobError &&
        error.jobError.code === 'AUDIO_DOWNLOAD_FAILED' &&
        error.jobError.retryable === true
    );
  } finally {
    await fx.cleanup();
  }
});
