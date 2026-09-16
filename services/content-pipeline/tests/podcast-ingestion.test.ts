import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { test } from 'node:test';
import type { AddressInfo } from 'node:net';

import { loadConfig, type ServiceConfig } from '../src/config.js';
import { openDatabase } from '../src/jobs/migrations.js';
import { JobStore, type ProgressUpdate } from '../src/jobs/job-store.js';
import { PipelineJobError } from '../src/jobs/worker.js';
import { RedactingLogger } from '../src/observability/logger.js';
import { KeyLayout } from '../src/storage/keys.js';
import { InMemoryObjectStore } from '../src/storage/object-store.js';
import { podcastContentKey } from '../src/domain/content-key.js';
import { ingestPodcastAudio } from '../src/pipeline/podcast-ingestion.js';

// End-to-end ingestion tests (WP4): real downloader + ffmpeg + job store +
// in-memory object store, with only DNS loopback admitted via the SSRF seam.

const execFileAsync = promisify(execFile);
const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url).pathname;

async function ffmpegAvailable(): Promise<boolean> {
  try {
    await execFileAsync('ffmpeg', ['-version']);
    return true;
  } catch {
    return false;
  }
}

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
  const tempRoot = await mkdtemp(join(tmpdir(), 'ingestion-test-'));
  const config = loadConfig({
    CONTENT_IDENTITY_MODE: 'selfhost', CONTENT_SERVICE_TOKEN: 'test-service-token-0123456789',
    MEDIA_API_TOKEN: 'test-media-token-0123456789',
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
      await rm(tempRoot, { recursive: true, force: true });
    }
  };
}

function createPodcastJob(store: JobStore, url: string) {
  store.createJob({
    ownerScope: 'test-owner',
    contentType: 'podcast_episode',
    contentKey: podcastContentKey('https://example.com/feed.xml', 'ep-100'),
    source: { platform: 'rss', sourceId: 'ep-100', url, feedUrl: 'https://example.com/feed.xml' },
    sourceLanguage: 'en',
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    pipelineVersion: '1',
    clientArtifactSchemaVersion: 1
  });
  // Ingestion mirrors the worker: only claimed (running) jobs progress.
  const claimed = store.claimNextJob('test-worker', 60_000);
  assert.ok(claimed, 'expected a claimable job');
  return claimed;
}

test('podcast ingestion flow', { skip: !(await ffmpegAvailable()) }, async (t) => {
  // Synthesize a real MP3 once per suite.
  const mediaDir = await mkdtemp(join(tmpdir(), 'ingestion-media-'));
  const mp3Path = join(mediaDir, 'episode.mp3');
  await execFileAsync('ffmpeg', [
    '-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=3',
    '-codec:a', 'libmp3lame', '-b:a', '128k', mp3Path
  ]);
  const mp3Bytes = await readFile(mp3Path);

  const hits = { count: 0 };
  const server = createServer((req, res) => {
    hits.count += 1;
    if (req.url === '/episode.mp3') {
      res.writeHead(200, {
        'content-type': 'audio/mpeg',
        'content-length': mp3Bytes.length
      });
      res.end(mp3Bytes);
    } else {
      res.writeHead(404).end();
    }
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const loopback = { allowAddress: (ip: string) => ip === '127.0.0.1' || ip === '::1' };

  t.after(async () => {
    await new Promise((resolve) => server.close(resolve));
    await rm(mediaDir, { recursive: true, force: true });
  });

  await t.test('downloads, probes, publishes and marks audio ready', async () => {
    const fx = await setupFixture();
    try {
      const job = createPodcastJob(fx.store, `${baseUrl}/episode.mp3`);
      const progress: ProgressUpdate[] = [];
      const result = await ingestPodcastAudio(job, {
        store: fx.store,
        layout: fx.layout,
        objectStore: fx.objectStore,
        config: fx.config,
        logger: fx.logger,
        ssrf: loopback
      }, {
        updateProgress: (u) => {
          progress.push(u);
          fx.store.updateProgress(job.jobId, u);
        },
        heartbeat: () => {},
        signal: new AbortController().signal
      });

      assert.equal(result.reused, false);
      assert.equal(result.transcoded, false); // source was already MP3
      assert.equal(result.mimeType, 'audio/mpeg');
      assert.ok(Math.abs(result.durationSeconds - 3) < 0.5);
      assert.match(result.objectKey, /^content-pipeline\/[^/]+\/podcast-audio\/[0-9a-f]{64}\.mp3$/);

      // Object landed with the same bytes.
      const head = await fx.objectStore.head(result.objectKey);
      assert.ok(head);
      assert.equal(head.bytes, mp3Bytes.length);
      assert.deepEqual(await fx.objectStore.getRange(result.objectKey), mp3Bytes);

      // Source artifact registered with fingerprint = sha256 of the bytes.
      const artifact = fx.store.audioArtifactForJob(job.jobId);
      assert.ok(artifact);
      assert.equal(artifact.objectKey, result.objectKey);
      assert.equal(artifact.sha256, result.sha256);

      // audioReady flipped through progress updates.
      const updated = fx.store.getJob(job.jobId);
      assert.equal(updated?.audioReady, true);
      assert.equal(updated?.subtitlesReady, false);
      assert.ok(progress.some((u) => u.audioReady === true));

      // Temp directory cleaned up.
      await assert.rejects(stat(join(fx.tempRoot, job.jobId)));
    } finally {
      await fx.cleanup();
    }
  });

  await t.test('second job for the same content reuses the uploaded audio', async () => {
    const fx = await setupFixture();
    try {
      const job = createPodcastJob(fx.store, `${baseUrl}/episode.mp3`);
      const hooks = {
        updateProgress: (u: ProgressUpdate) => fx.store.updateProgress(job.jobId, u),
        heartbeat: () => {},
        signal: new AbortController().signal
      };
      const first = await ingestPodcastAudio(job, {
        store: fx.store, layout: fx.layout, objectStore: fx.objectStore,
        config: fx.config, logger: fx.logger, ssrf: loopback
      }, hooks);
      const hitsAfterFirst = hits.count;

      const again = await ingestPodcastAudio(job, {
        store: fx.store, layout: fx.layout, objectStore: fx.objectStore,
        config: fx.config, logger: fx.logger, ssrf: loopback
      }, hooks);
      assert.equal(again.reused, true);
      assert.equal(again.objectKey, first.objectKey);
      assert.equal(hits.count, hitsAfterFirst, 'no second download');
    } finally {
      await fx.cleanup();
    }
  });

  await t.test('a dead source fails with SOURCE_UNAVAILABLE and cleans temp', async () => {
    const fx = await setupFixture();
    try {
      const job = createPodcastJob(fx.store, `${baseUrl}/gone.mp3`);
      try {
        await ingestPodcastAudio(job, {
          store: fx.store, layout: fx.layout, objectStore: fx.objectStore,
          config: fx.config, logger: fx.logger, ssrf: loopback
        }, {
          updateProgress: () => {},
          heartbeat: () => {},
          signal: new AbortController().signal
        });
        assert.fail('expected failure');
      } catch (error) {
        assert.ok(error instanceof PipelineJobError);
        assert.equal(error.jobError.code, 'SOURCE_UNAVAILABLE');
        assert.equal(error.jobError.retryable, false);
      }
      await assert.rejects(stat(join(fx.tempRoot, job.jobId)));
    } finally {
      await fx.cleanup();
    }
  });

  await t.test('duration above the cap fails with MEDIA_TOO_LONG', async () => {
    const fx = await setupFixture();
    try {
      fx.config.maxMediaDurationSeconds = 1; // 3s fixture exceeds it
      const job = createPodcastJob(fx.store, `${baseUrl}/episode.mp3`);
      try {
        await ingestPodcastAudio(job, {
          store: fx.store, layout: fx.layout, objectStore: fx.objectStore,
          config: fx.config, logger: fx.logger, ssrf: loopback
        }, {
          updateProgress: () => {},
          heartbeat: () => {},
          signal: new AbortController().signal
        });
        assert.fail('expected failure');
      } catch (error) {
        assert.ok(error instanceof PipelineJobError);
        assert.equal(error.jobError.code, 'MEDIA_TOO_LONG');
      }
    } finally {
      await fx.cleanup();
    }
  });
});
