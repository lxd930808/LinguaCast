import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { loadConfig } from '../src/config.js';
import { openDatabase } from '../src/jobs/migrations.js';
import { JobStore } from '../src/jobs/job-store.js';
import { PipelineJobError } from '../src/jobs/worker.js';
import { RedactingLogger } from '../src/observability/logger.js';
import { KeyLayout } from '../src/storage/keys.js';
import { InMemoryObjectStore } from '../src/storage/object-store.js';
import { podcastContentKey } from '../src/domain/content-key.js';
import {
  AsrProviderError,
  AsrSubmissionUncertainError,
  type AsrPollResult,
  type TranscriptionProvider
} from '../src/providers/asr/types.js';
import {
  canonicalFingerprint,
  runAsrStage,
  validateSegments
} from '../src/pipeline/asr-stage.js';

// ASR stage tests (WP5): a scripted fake provider proves submit-once
// semantics, checkpoint resume and stable error mapping without any network.

const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url).pathname;
const AUDIO_SHA = 'a'.repeat(64);

const ASR_PAYLOAD = {
  transcripts: [
    {
      sentences: [
        {
          begin_time: 0,
          end_time: 1200,
          text: 'Hello world.',
          words: [
            { text: 'Hello', begin_time: 0, end_time: 400 },
            { text: 'world', begin_time: 420, end_time: 900, punctuation: '.' }
          ]
        },
        {
          begin_time: 2000,
          end_time: 3200,
          text: 'Second sentence here.',
          words: [
            { text: 'Second', begin_time: 2000, end_time: 2400 },
            { text: 'sentence', begin_time: 2420, end_time: 2800 },
            { text: 'here', begin_time: 2820, end_time: 3100, punctuation: '.' }
          ]
        }
      ]
    }
  ]
};

class FakeProvider implements TranscriptionProvider {
  readonly name = 'fake';
  submitCount = 0;
  pollCount = 0;
  pollScript: AsrPollResult[];
  submitError: Error | null = null;

  constructor(pollScript: AsrPollResult[]) {
    this.pollScript = [...pollScript];
  }

  async submit(): Promise<string> {
    this.submitCount += 1;
    if (this.submitError) throw this.submitError;
    return 'task-fake-001';
  }

  async poll(): Promise<AsrPollResult> {
    this.pollCount += 1;
    const next = this.pollScript.shift();
    if (!next) throw new AsrProviderError('poll script exhausted', true);
    return next;
  }
}

interface Fixture {
  tempRoot: string;
  store: JobStore;
  layout: KeyLayout;
  objectStore: InMemoryObjectStore;
  cleanup: () => Promise<void>;
}

async function setup(): Promise<Fixture> {
  const tempRoot = await mkdtemp(join(tmpdir(), 'asr-stage-test-'));
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
  const job = store.createJob({
    ownerScope: 'test-owner',
    contentType: 'podcast_episode',
    contentKey: podcastContentKey('https://example.com/feed.xml', 'ep-200'),
    source: { platform: 'rss', sourceId: 'ep-200', url: 'https://media.example.com/ep.mp3' },
    sourceLanguage: 'en',
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    pipelineVersion: '1',
    clientArtifactSchemaVersion: 1
  }).job;
  store.registerSourceArtifact({
    jobId: job.jobId,
    kind: 'audio',
    fingerprint: AUDIO_SHA,
    objectKey: 'content-pipeline/test/podcast-audio/' + AUDIO_SHA + '.mp3',
    mimeType: 'audio/mpeg',
    bytes: 1000,
    durationSeconds: 60,
    sha256: AUDIO_SHA
  });
  const objectStore = new InMemoryObjectStore();
  // The audio object exists in storage (WP4 put it there before ASR runs).
  const audioKey = 'content-pipeline/test/podcast-audio/' + AUDIO_SHA + '.mp3';
  await objectStore.put(audioKey, Buffer.from('fake audio bytes'), 'audio/mpeg');
  return {
    tempRoot,
    store,
    layout: new KeyLayout(config.r2),
    objectStore,
    cleanup: async () => {
      store.close();
      await rm(tempRoot, { recursive: true, force: true });
    }
  };
}

function fakeDownload(payload: unknown) {
  return async (_url: string, filePath: string) => {
    const bytes = Buffer.from(JSON.stringify(payload));
    await writeFile(filePath, bytes);
    return {
      filePath,
      bytes: bytes.length,
      sha256: createHash('sha256').update(bytes).digest('hex'),
      contentType: 'application/json',
      finalUrl: _url,
      redirects: 0
    };
  };
}

function makeHooks(store: JobStore, jobId: string) {
  return {
    updateProgress: (u: Parameters<JobStore['updateProgress']>[1]) => store.updateProgress(jobId, u),
    heartbeat: () => {},
    signal: new AbortController().signal
  };
}

async function claimedJob(store: JobStore) {
  const job = store.claimNextJob('test-worker', 60_000);
  assert.ok(job, 'expected a claimable job');
  return job;
}

test('happy path: submit once, poll, archive transcript, resegment', async () => {
  const fx = await setup();
  try {
    const job = await claimedJob(fx.store);
    const provider = new FakeProvider([
      { status: 'PENDING' },
      { status: 'RUNNING' },
      { status: 'SUCCEEDED', transcriptionUrl: 'https://asr.example.com/result.json' }
    ]);
    const config = { ...loadConfig({
      CONTENT_IDENTITY_MODE: 'selfhost', CONTENT_SERVICE_TOKEN: 'test-service-token-0123456789',
      MEDIA_API_TOKEN: 'test-media-token-0123456789',
      DASHSCOPE_API_KEY: 'test-dashscope-key-0123456789',
      TRANSLATION_API_KEY: 'test-translation-key-0123456789',
      TRANSLATION_MODEL: 'test-model',
      R2_ACCOUNT_ID: 'acct', R2_ACCESS_KEY_ID: 'r2-access',
      R2_SECRET_ACCESS_KEY: 'r2-secret-0123456789', R2_BUCKET: 'linguacast',
      CONTENT_TEMP_ROOT: fx.tempRoot
    }) };
    const result = await runAsrStage(job, {
      store: fx.store,
      layout: fx.layout,
      objectStore: fx.objectStore,
      config,
      logger: new RedactingLogger(() => {}),
      provider,
      pollIntervalMs: 1,
      download: fakeDownload(ASR_PAYLOAD) as never
    }, makeHooks(fx.store, job.jobId));

    assert.equal(provider.submitCount, 1);
    assert.equal(provider.pollCount, 3);
    assert.equal(result.reusedCheckpoint, false);
    assert.equal(result.segments.length, 2);
    assert.equal(result.segments[0].text, 'Hello world.');
    assert.equal(result.segments[0].timingSource, 'wordTimeline');
    assert.ok(result.sourceFingerprint.startsWith('aaaaaaaaaaaaaaaa:'));

    // Raw transcript archived under source-transcripts/ and registered.
    assert.ok(result.rawTranscriptKey?.startsWith('content-pipeline/'));
    const head = await fx.objectStore.head(result.rawTranscriptKey!);
    assert.ok(head && head.bytes > 0);

    // The final reusable checkpoint carries the segments (one row per stage;
    // it supersedes the task-ID checkpoint once transcription completed).
    const checkpoints = fx.store.reusableCheckpoints(job.jobId);
    const finalCheckpoint = checkpoints.find(
      (c) =>
        c.stage === 'transcribing' &&
        Array.isArray((c.output as { segments?: unknown[] } | null)?.segments)
    );
    assert.ok(finalCheckpoint, 'segments checkpoint persisted');
    const output = finalCheckpoint.output as { sourceFingerprint: string; segments: unknown[] };
    assert.equal(output.sourceFingerprint, result.sourceFingerprint);
    assert.equal(output.segments.length, 2);
  } finally {
    await fx.cleanup();
  }
});

test('submit uncertainty fails with ASR_SUBMISSION_UNCERTAIN and never retries', async () => {
  const fx = await setup();
  try {
    const job = await claimedJob(fx.store);
    const provider = new FakeProvider([]);
    provider.submitError = new AsrSubmissionUncertainError('socket hangup after POST');
    try {
      await runAsrStage(job, {
        store: fx.store, layout: fx.layout, objectStore: fx.objectStore,
        config: (await import('../src/config.js')).loadConfig({
          CONTENT_IDENTITY_MODE: 'selfhost', CONTENT_SERVICE_TOKEN: 'x'.repeat(24), MEDIA_API_TOKEN: 'x'.repeat(24),
          DASHSCOPE_API_KEY: 'x'.repeat(24), TRANSLATION_API_KEY: 'x'.repeat(24),
          TRANSLATION_MODEL: 'm', R2_ACCOUNT_ID: 'a', R2_ACCESS_KEY_ID: 'r',
          R2_SECRET_ACCESS_KEY: 'x'.repeat(24), R2_BUCKET: 'b', CONTENT_TEMP_ROOT: fx.tempRoot
        }),
        logger: new RedactingLogger(() => {}),
        provider,
        pollIntervalMs: 1,
        download: fakeDownload(ASR_PAYLOAD) as never
      }, makeHooks(fx.store, job.jobId));
      assert.fail('expected failure');
    } catch (error) {
      assert.ok(error instanceof PipelineJobError);
      assert.equal(error.jobError.code, 'ASR_SUBMISSION_UNCERTAIN');
      assert.equal(error.jobError.retryable, false);
    }
    assert.equal(provider.submitCount, 1);
    assert.equal(provider.pollCount, 0);
  } finally {
    await fx.cleanup();
  }
});

test('a persisted task ID is resumed after a crash — submit is not repeated', async () => {
  const fx = await setup();
  try {
    const job = await claimedJob(fx.store);
    fx.store.recordCheckpoint(job.jobId, {
      stage: 'transcribing',
      inputFingerprint: AUDIO_SHA,
      output: { provider: 'fake', taskId: 'task-resumed', audioFingerprint: AUDIO_SHA },
      schemaVersion: 1,
      reusable: true
    });
    const provider = new FakeProvider([
      { status: 'SUCCEEDED', transcriptionUrl: 'https://asr.example.com/result.json' }
    ]);
    const config = loadConfig({
      CONTENT_IDENTITY_MODE: 'selfhost', CONTENT_SERVICE_TOKEN: 'x'.repeat(24), MEDIA_API_TOKEN: 'x'.repeat(24),
      DASHSCOPE_API_KEY: 'x'.repeat(24), TRANSLATION_API_KEY: 'x'.repeat(24),
      TRANSLATION_MODEL: 'm', R2_ACCOUNT_ID: 'a', R2_ACCESS_KEY_ID: 'r',
      R2_SECRET_ACCESS_KEY: 'x'.repeat(24), R2_BUCKET: 'b', CONTENT_TEMP_ROOT: fx.tempRoot
    });
    const result = await runAsrStage(job, {
      store: fx.store, layout: fx.layout, objectStore: fx.objectStore, config,
      logger: new RedactingLogger(() => {}),
      provider, pollIntervalMs: 1, download: fakeDownload(ASR_PAYLOAD) as never
    }, makeHooks(fx.store, job.jobId));
    assert.equal(provider.submitCount, 0, 'submit must not be repeated');
    assert.equal(provider.pollCount, 1);
    assert.equal(result.segments.length, 2);
  } finally {
    await fx.cleanup();
  }
});

test('a completed segments checkpoint short-circuits the provider entirely', async () => {
  const fx = await setup();
  try {
    const job = await claimedJob(fx.store);
    const segments = [
      {
        sequence: 1, startMS: 0, endMS: 500, text: 'Done already.',
        learningText: 'Done already.', translation: '', notes: '',
        words: [{ text: 'Done', startMS: 0, endMS: 200 }, { text: 'already', startMS: 220, endMS: 480, punctuation: '.' }],
        timingSource: 'wordTimeline' as const
      }
    ];
    const fingerprint = `${AUDIO_SHA.slice(0, 16)}:${canonicalFingerprint(segments)}`;
    fx.store.recordCheckpoint(job.jobId, {
      stage: 'transcribing',
      inputFingerprint: AUDIO_SHA,
      output: { sourceFingerprint: fingerprint, rawTranscriptKey: null, segments },
      schemaVersion: 1,
      reusable: true
    });
    const provider = new FakeProvider([]);
    const config = loadConfig({
      CONTENT_IDENTITY_MODE: 'selfhost', CONTENT_SERVICE_TOKEN: 'x'.repeat(24), MEDIA_API_TOKEN: 'x'.repeat(24),
      DASHSCOPE_API_KEY: 'x'.repeat(24), TRANSLATION_API_KEY: 'x'.repeat(24),
      TRANSLATION_MODEL: 'm', R2_ACCOUNT_ID: 'a', R2_ACCESS_KEY_ID: 'r',
      R2_SECRET_ACCESS_KEY: 'x'.repeat(24), R2_BUCKET: 'b', CONTENT_TEMP_ROOT: fx.tempRoot
    });
    const result = await runAsrStage(job, {
      store: fx.store, layout: fx.layout, objectStore: fx.objectStore, config,
      logger: new RedactingLogger(() => {}),
      provider, pollIntervalMs: 1, download: fakeDownload(ASR_PAYLOAD) as never
    }, makeHooks(fx.store, job.jobId));
    assert.equal(provider.submitCount, 0);
    assert.equal(provider.pollCount, 0);
    assert.equal(result.reusedCheckpoint, true);
    assert.equal(result.sourceFingerprint, fingerprint);
    assert.equal(result.segments.length, 1);
  } finally {
    await fx.cleanup();
  }
});

test('provider terminal failure maps to retryable ASR_FAILED', async () => {
  const fx = await setup();
  try {
    const job = await claimedJob(fx.store);
    const provider = new FakeProvider([]);
    provider.poll = async () => {
      throw new AsrProviderError('task FAILED: audio too noisy', true, 30);
    };
    const config = loadConfig({
      CONTENT_IDENTITY_MODE: 'selfhost', CONTENT_SERVICE_TOKEN: 'x'.repeat(24), MEDIA_API_TOKEN: 'x'.repeat(24),
      DASHSCOPE_API_KEY: 'x'.repeat(24), TRANSLATION_API_KEY: 'x'.repeat(24),
      TRANSLATION_MODEL: 'm', R2_ACCOUNT_ID: 'a', R2_ACCESS_KEY_ID: 'r',
      R2_SECRET_ACCESS_KEY: 'x'.repeat(24), R2_BUCKET: 'b', CONTENT_TEMP_ROOT: fx.tempRoot
    });
    try {
      await runAsrStage(job, {
        store: fx.store, layout: fx.layout, objectStore: fx.objectStore, config,
        logger: new RedactingLogger(() => {}),
        provider, pollIntervalMs: 1, download: fakeDownload(ASR_PAYLOAD) as never
      }, makeHooks(fx.store, job.jobId));
      assert.fail('expected failure');
    } catch (error) {
      assert.ok(error instanceof PipelineJobError);
      assert.equal(error.jobError.code, 'ASR_FAILED');
      assert.equal(error.jobError.retryable, true);
      assert.equal(error.jobError.retryAfterSeconds, 30);
    }
    assert.equal(provider.submitCount, 1); // task persisted for the retry
  } finally {
    await fx.cleanup();
  }
});

test('empty recognition is a stable non-retryable failure', async () => {
  const fx = await setup();
  try {
    const job = await claimedJob(fx.store);
    const provider = new FakeProvider([
      { status: 'SUCCEEDED', transcriptionUrl: 'https://asr.example.com/empty.json' }
    ]);
    const config = loadConfig({
      CONTENT_IDENTITY_MODE: 'selfhost', CONTENT_SERVICE_TOKEN: 'x'.repeat(24), MEDIA_API_TOKEN: 'x'.repeat(24),
      DASHSCOPE_API_KEY: 'x'.repeat(24), TRANSLATION_API_KEY: 'x'.repeat(24),
      TRANSLATION_MODEL: 'm', R2_ACCOUNT_ID: 'a', R2_ACCESS_KEY_ID: 'r',
      R2_SECRET_ACCESS_KEY: 'x'.repeat(24), R2_BUCKET: 'b', CONTENT_TEMP_ROOT: fx.tempRoot
    });
    try {
      await runAsrStage(job, {
        store: fx.store, layout: fx.layout, objectStore: fx.objectStore, config,
        logger: new RedactingLogger(() => {}),
        provider, pollIntervalMs: 1, download: fakeDownload({ transcripts: [] }) as never
      }, makeHooks(fx.store, job.jobId));
      assert.fail('expected failure');
    } catch (error) {
      assert.ok(error instanceof PipelineJobError);
      assert.equal(error.jobError.code, 'ASR_FAILED');
      assert.equal(error.jobError.retryable, false);
    }
  } finally {
    await fx.cleanup();
  }
});

test('validateSegments rejects non-monotonic word timelines', () => {
  assert.throws(
    () =>
      validateSegments([
        {
          sequence: 1, startMS: 0, endMS: 5000, text: 'x', learningText: 'x',
          translation: '', notes: '',
          words: [
            { text: 'a', startMS: 3000, endMS: 3500 },
            { text: 'b', startMS: 1000, endMS: 1500 } // 2s regression
          ],
          timingSource: 'wordTimeline'
        }
      ]),
    (error: unknown) =>
      error instanceof PipelineJobError && error.jobError.code === 'ASR_FAILED'
  );
  assert.throws(
    () => validateSegments([]),
    (error: unknown) =>
      error instanceof PipelineJobError &&
      error.jobError.code === 'ASR_FAILED' &&
      error.jobError.retryable === false
  );
});
