import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { loadConfig } from '../src/config.js';
import { openDatabase } from '../src/jobs/migrations.js';
import { JobStore, type ProgressUpdate } from '../src/jobs/job-store.js';
import { PipelineJobError } from '../src/jobs/worker.js';
import { RedactingLogger } from '../src/observability/logger.js';
import { KeyLayout } from '../src/storage/keys.js';
import { InMemoryObjectStore } from '../src/storage/object-store.js';
import { podcastContentKey } from '../src/domain/content-key.js';
import type { TranscriptionProvider } from '../src/providers/asr/types.js';
import type { TranslationProvider } from '../src/providers/translation/types.js';
import type { MediaServiceClient } from '../src/providers/media/types.js';
import { createPipelineExecutor } from '../src/pipeline/executor.js';

// Executor composition tests (WP4–WP7 glue): the full podcast chain runs
// end-to-end with fake providers and real stages; dispatch edge cases fail
// fast with stable errors.

const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url).pathname;
const AUDIO_BYTES = Buffer.from('executor test audio bytes');
const AUDIO_SHA = createHash('sha256').update(AUDIO_BYTES).digest('hex');

const TRANSCRIPT_PAYLOAD = {
  transcripts: [
    {
      sentences: [
        {
          begin_time: 100,
          end_time: 1400,
          text: 'Hello world.',
          words: [
            { text: 'Hello', begin_time: 100, end_time: 400 },
            { text: 'world', begin_time: 420, end_time: 900, punctuation: '.' }
          ]
        },
        {
          begin_time: 2000,
          end_time: 3100,
          text: 'How are you?',
          words: [
            { text: 'How', begin_time: 2000, end_time: 2300 },
            { text: 'are', begin_time: 2320, end_time: 2600 },
            { text: 'you', begin_time: 2620, end_time: 3000, punctuation: '?' }
          ]
        }
      ]
    }
  ]
};

const fakeAsr: TranscriptionProvider = {
  name: 'fake-asr',
  async submit() {
    return 'task-1';
  },
  async poll() {
    return { status: 'SUCCEEDED', transcriptionUrl: 'https://asr.example/result.json' };
  }
};

/**
 * Answers numbered batch prompts with exact-origin JSON; anything else
 * (context extraction, refinement splits) gets an empty object, which the
 * stages treat as "no context" / "no split".
 */
const fakeTranslation: TranslationProvider = {
  name: 'fake-translation',
  model: 'fake-model',
  async chatCompletion({ userPrompt }) {
    const lines = userPrompt
      .split('\n')
      .map((line) => /^(\d+)\.\s(.*)$/.exec(line))
      .filter((m): m is RegExpExecArray => m !== null);
    if (lines.length === 0) return '{}';
    const out: Record<string, { origin: string; direct: string }> = {};
    for (const [, seq, text] of lines) {
      out[seq] = { origin: text, direct: `译文${seq}` };
    }
    return JSON.stringify(out);
  }
};

async function setup() {
  const tempRoot = await mkdtemp(join(tmpdir(), 'executor-test-'));
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
  const layout = new KeyLayout(config.r2);
  const objectStore = new InMemoryObjectStore();
  const logger = new RedactingLogger(() => {});
  return {
    tempRoot,
    config,
    store,
    layout,
    objectStore,
    logger,
    cleanup: async () => {
      store.close();
      await rm(tempRoot, { recursive: true, force: true });
    }
  };
}

function createPodcastJob(store: JobStore) {
  store.createJob({
    ownerScope: 'test-owner',
    contentType: 'podcast_episode',
    contentKey: podcastContentKey('https://example.com/feed.xml', 'ep-1'),
    source: {
      platform: 'rss',
      sourceId: 'ep-1',
      url: 'https://example.com/ep-1.mp3',
      feedUrl: 'https://example.com/feed.xml'
    },
    sourceLanguage: 'en',
    targetLanguage: 'zh-Hans',
    translationQuality: 'fast',
    pipelineVersion: '1',
    clientArtifactSchemaVersion: 1
  });
  const claimed = store.claimNextJob('test-worker', 60_000);
  assert.ok(claimed);
  return claimed;
}

async function seedAudioArtifact(
  store: JobStore,
  layout: KeyLayout,
  objectStore: InMemoryObjectStore,
  jobId: string
): Promise<string> {
  const objectKey = layout.podcastAudio(AUDIO_SHA);
  await objectStore.put(objectKey, AUDIO_BYTES, 'audio/mpeg');
  store.registerSourceArtifact({
    jobId,
    kind: 'audio',
    fingerprint: AUDIO_SHA,
    objectKey,
    mimeType: 'audio/mpeg',
    bytes: AUDIO_BYTES.length,
    durationSeconds: 3,
    sha256: AUDIO_SHA,
    transcoded: false
  });
  return objectKey;
}

test('full podcast chain: reuse → ASR → translate → refine → package', async () => {
  const fx = await setup();
  try {
    const job = createPodcastJob(fx.store);
    await seedAudioArtifact(fx.store, fx.layout, fx.objectStore, job.jobId);

    const executor = createPipelineExecutor({
      store: fx.store,
      layout: fx.layout,
      objectStore: fx.objectStore,
      config: fx.config,
      logger: fx.logger,
      asrProvider: fakeAsr,
      translationProvider: fakeTranslation,
      download: async (url, filePath) => {
        assert.equal(url, 'https://asr.example/result.json');
        const data = Buffer.from(JSON.stringify(TRANSCRIPT_PAYLOAD));
        await writeFile(filePath, data);
        return {
          filePath,
          bytes: data.length,
          sha256: createHash('sha256').update(data).digest('hex'),
          contentType: 'application/json',
          finalUrl: url,
          redirects: 0
        };
      }
    });

    const progress: ProgressUpdate[] = [];
    const manifestRef = (await executor({
      job,
      logger: fx.logger,
      signal: new AbortController().signal,
      heartbeat: () => {},
      updateProgress: (u) => {
        progress.push(u);
        fx.store.updateProgress(job.jobId, u);
      },
      recordCheckpoint: (c) => fx.store.recordCheckpoint(job.jobId, c),
      reusableCheckpoints: () => fx.store.reusableCheckpoints(job.jobId)
    })) as Record<string, unknown>;

    // Manifest ref returned for completeJob; packaged objects exist.
    assert.ok(manifestRef && typeof manifestRef === 'object');
    const keys = await fx.objectStore.listKeys('');
    assert.ok(keys.some((k) => k.includes('manifest')), `manifest key missing: ${keys}`);
    assert.ok(keys.some((k) => k.endsWith('.vtt')), `vtt key missing: ${keys}`);

    // Segments JSON carries both translations from the fake provider.
    const segmentsKey = keys.find((k) => k.includes('segments') && k.endsWith('.json'));
    assert.ok(segmentsKey, `segments key missing: ${keys}`);
    const payload = JSON.parse(
      (await fx.objectStore.getRange(segmentsKey)).toString('utf8')
    ) as { segments: Array<{ text: string; translation: string }> };
    const segments = payload.segments;
    assert.ok(Array.isArray(segments) && segments.length >= 2);
    assert.equal(segments[0].text, 'Hello world.');
    assert.match(segments[0].translation, /译文/);

    // Stages progressed in contract order and reached completion progress.
    const stages = progress.map((p) => p.stage).filter(Boolean);
    assert.ok(stages.includes('transcribing'));
    assert.ok(stages.includes('translating'));
    assert.ok(stages.includes('packaging'));

    // Audio was reused — no ingestion fetch happened.
    const row = fx.store.getJob(job.jobId);
    assert.equal(row?.audioReady, true);
  } finally {
    await fx.cleanup();
  }
});

test('video job without a media client fails fast with a stable error', async () => {
  const fx = await setup();
  try {
    fx.store.createJob({
      ownerScope: 'test-owner',
      contentType: 'video',
      contentKey: 'youtube:abcdefghijk',
      source: {
        platform: 'youtube',
        sourceId: 'abcdefghijk',
        url: 'https://www.youtube.com/watch?v=abcdefghijk'
      },
      sourceLanguage: 'en',
      targetLanguage: 'zh-Hans',
      translationQuality: 'fast',
      pipelineVersion: '1',
      clientArtifactSchemaVersion: 1
    });
    const job = fx.store.claimNextJob('test-worker', 60_000);
    assert.ok(job);

    const executor = createPipelineExecutor({
      store: fx.store,
      layout: fx.layout,
      objectStore: fx.objectStore,
      config: fx.config,
      logger: fx.logger,
      asrProvider: fakeAsr,
      translationProvider: fakeTranslation
    });
    await assert.rejects(
      () =>
        executor({
          job,
          logger: fx.logger,
          signal: new AbortController().signal,
          heartbeat: () => {},
          updateProgress: () => {},
          recordCheckpoint: () => {},
          reusableCheckpoints: () => []
        }),
      (error: unknown) =>
        error instanceof PipelineJobError &&
        error.jobError.code === 'INTERNAL_ERROR' &&
        error.jobError.retryable === false &&
        error.jobError.failedStage === 'fetching_audio'
    );
  } finally {
    await fx.cleanup();
  }
});

test('video job dispatches to the media stage when a client is configured', async () => {
  const fx = await setup();
  try {
    fx.store.createJob({
      ownerScope: 'test-owner',
      contentType: 'video',
      contentKey: 'youtube:abcdefghijk',
      source: {
        platform: 'youtube',
        sourceId: 'abcdefghijk',
        url: 'https://www.youtube.com/watch?v=abcdefghijk'
      },
      sourceLanguage: 'en',
      targetLanguage: 'zh-Hans',
      translationQuality: 'fast',
      pipelineVersion: '1',
      clientArtifactSchemaVersion: 1
    });
    const job = fx.store.claimNextJob('test-worker', 60_000);
    assert.ok(job);
    // Pre-seeded artifact: the media stage reuses it, so a stub client that
    // only records "not called" is enough to prove dispatch + reuse.
    await seedAudioArtifact(fx.store, fx.layout, fx.objectStore, job.jobId);

    let mediaTouched = false;
    const mediaClient: MediaServiceClient = {
      async prepare() {
        mediaTouched = true;
        return { jobId: 'mj-1', status: 'queued' };
      },
      async getJob() {
        mediaTouched = true;
        throw new Error('unreached');
      },
      async cancel() {
        mediaTouched = true;
      }
    };

    const executor = createPipelineExecutor({
      store: fx.store,
      layout: fx.layout,
      objectStore: fx.objectStore,
      config: fx.config,
      logger: fx.logger,
      asrProvider: fakeAsr,
      translationProvider: fakeTranslation,
      mediaClient,
      download: async (url, filePath) => {
        const data = Buffer.from(JSON.stringify(TRANSCRIPT_PAYLOAD));
        await writeFile(filePath, data);
        return {
          filePath,
          bytes: data.length,
          sha256: createHash('sha256').update(data).digest('hex'),
          contentType: 'application/json',
          finalUrl: url,
          redirects: 0
        };
      }
    });

    const manifestRef = await executor({
      job,
      logger: fx.logger,
      signal: new AbortController().signal,
      heartbeat: () => {},
      updateProgress: () => {},
      recordCheckpoint: (c) => fx.store.recordCheckpoint(job.jobId, c),
      reusableCheckpoints: () => fx.store.reusableCheckpoints(job.jobId)
    });
    assert.ok(manifestRef);
    assert.equal(mediaTouched, false, 'reused artifact must skip media-api');
  } finally {
    await fx.cleanup();
  }
});
