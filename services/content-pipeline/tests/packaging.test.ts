import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { openDatabase } from '../src/jobs/migrations.js';
import { JobStore } from '../src/jobs/job-store.js';
import { PipelineJobError } from '../src/jobs/worker.js';
import { RedactingLogger } from '../src/observability/logger.js';
import { podcastContentKey } from '../src/domain/content-key.js';
import { KeyLayout } from '../src/storage/keys.js';
import { InMemoryObjectStore } from '../src/storage/object-store.js';
import { runPackagingStage } from '../src/pipeline/packaging/package-stage.js';
import { buildSourceVtt, buildTargetVtt, formatVttTimestamp } from '../src/pipeline/packaging/vtt.js';
import { canonicalFingerprint } from '../src/pipeline/asr-stage.js';
import type { LearningSegment } from '../src/pipeline/segmentation/types.js';
import type { ServiceConfig } from '../src/config.js';

// Packaging tests (WP6): artifact files, VTT shapes, optional raw transcript
// and the atomic publish contract (manifest last, no half-written ready).

const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url).pathname;
const AUDIO_SHA = 'b'.repeat(64);

const SEGMENTS: LearningSegment[] = [
  {
    sequence: 1,
    startMS: 0,
    endMS: 2640,
    text: 'Welcome back to Slow English News.',
    learningText: 'Welcome back to Slow English News.',
    translation: '欢迎回到慢速英语新闻。',
    speaker: 'S1',
    notes: '',
    words: [],
    playbackSentence: {
      id: 1,
      text: 'Welcome back to Slow English News.',
      translation: '欢迎回到慢速英语新闻。',
      startMS: 0,
      endMS: 2640
    },
    timingSource: 'wordTimeline'
  },
  {
    sequence: 2,
    startMS: 2700,
    endMS: 6900,
    text: 'Today we talk about a small library.',
    learningText: 'Today we talk about a small library.',
    translation: '今天我们谈谈一座小图书馆。',
    notes: '',
    words: [],
    timingSource: 'semantic'
  }
];

const SOURCE_FINGERPRINT = `audiofp0:${canonicalFingerprint(SEGMENTS)}`;

function fakeConfig(tempRoot: string): ServiceConfig {
  return {
    host: '127.0.0.1',
    port: 3220,
    serviceToken: 'test-service-token-0123456789',
    identity: { mode: 'selfhost', accountServiceUrl: null, introspectionToken: null, internalCallers: [], contextSigningKey: null },
    quota: { enabled: false, accountConcurrency: 1, globalConcurrency: 1, probeHeadBytes: 2 * 1024 * 1024 },
    pipelineVersion: 'v10.1',
    mediaApi: { baseUrl: 'http://127.0.0.1:3210', token: 'test-media-token-0123456789' },
    dashscope: { apiKey: 'test-dashscope-key-0123456789', baseUrl: 'https://dashscope.aliyuncs.com' },
    translation: {
      provider: 'dashscope',
      baseUrl: 'https://dashscope.aliyuncs.com',
      apiKey: 'test-translation-key-0123456789',
      model: 'test-model',
      reasoningEffort: null,
      requestTimeoutMs: 300_000,
      networkRetries: 2
    },
    r2: {
      accountId: 'acct',
      accessKeyId: 'r2-access',
      secretAccessKey: 'r2-secret-0123456789',
      bucket: 'linguacast',
      prefix: 'content-pipeline',
      environment: 'test',
      signedUrlTtlSeconds: 3600
    },
    maxBodyBytes: 65536,
    maxMediaBytes: 100 * 1024 * 1024,
    maxMediaDurationSeconds: 3600,
    mediaConcurrency: 1,
    workerConcurrency: 1,
    diskWatermarkBytes: 5 * 1024 * 1024 * 1024,
    tempRoot,
    databasePath: join(tempRoot, 'content.db'),
    videoMediaPromotionEnabled: false,
    videoMediaRetentionDays: 30,
    videoMediaCleanupIntervalSeconds: 21_600,
    videoMediaCleanupBatchSize: 50,
    videoMediaBudgetBytes: 100 * 1024 * 1024 * 1024
  };
}

interface Fixture {
  tempRoot: string;
  store: JobStore;
  layout: KeyLayout;
  objectStore: InMemoryObjectStore;
  config: ServiceConfig;
  jobId: string;
  cleanup: () => Promise<void>;
}

async function setup(options?: { rawTranscript?: boolean }): Promise<Fixture> {
  const tempRoot = await mkdtemp(join(tmpdir(), 'packaging-test-'));
  const config = fakeConfig(tempRoot);
  const db = openDatabase(config.databasePath, MIGRATIONS_DIR);
  const store = new JobStore(db);
  const { job } = store.createJob({
    ownerScope: 'test-owner',
    contentType: 'podcast_episode',
    contentKey: podcastContentKey('https://example.com/feed.xml', 'ep-500'),
    source: { platform: 'rss', sourceId: 'ep-500', url: 'https://media.example.com/ep.mp3' },
    sourceLanguage: 'en',
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    pipelineVersion: 'v10.1',
    clientArtifactSchemaVersion: 1
  });
  const layout = new KeyLayout(config.r2);
  const objectStore = new InMemoryObjectStore();
  const audioKey = layout.podcastAudio(AUDIO_SHA);
  await objectStore.put(audioKey, Buffer.from('fake audio'), 'audio/mpeg');
  store.registerSourceArtifact({
    jobId: job.jobId,
    kind: 'audio',
    fingerprint: AUDIO_SHA,
    objectKey: audioKey,
    mimeType: 'audio/mpeg',
    bytes: 1000,
    durationSeconds: 60.5,
    sha256: AUDIO_SHA,
    transcoded: false
  });

  const rawTranscriptKey = options?.rawTranscript === false ? null : layout.sourceTranscript('c'.repeat(64));
  if (rawTranscriptKey) {
    await objectStore.put(rawTranscriptKey, Buffer.from('{"raw":true}'), 'application/json');
  }
  store.recordCheckpoint(job.jobId, {
    stage: 'transcribing',
    inputFingerprint: AUDIO_SHA,
    output: { sourceFingerprint: SOURCE_FINGERPRINT, rawTranscriptKey, segments: SEGMENTS },
    schemaVersion: 1,
    reusable: true
  });
  store.recordCheckpoint(job.jobId, {
    stage: 'refining_subtitles',
    inputFingerprint: SOURCE_FINGERPRINT,
    output: { schemaVersion: 1, sourceFingerprint: SOURCE_FINGERPRINT, entries: [], segments: SEGMENTS },
    schemaVersion: 1,
    reusable: true
  });

  return {
    tempRoot,
    store,
    layout,
    objectStore,
    config,
    jobId: job.jobId,
    cleanup: async () => {
      store.close();
      await rm(tempRoot, { recursive: true, force: true });
    }
  };
}

function makeHooks(store: JobStore, jobId: string) {
  return {
    updateProgress: (u: Parameters<JobStore['updateProgress']>[1]) => store.updateProgress(jobId, u),
    heartbeat: () => {},
    signal: new AbortController().signal
  };
}

test('formatVttTimestamp renders HH:MM:SS.mmm', () => {
  assert.equal(formatVttTimestamp(0), '00:00:00.000');
  assert.equal(formatVttTimestamp(2640), '00:00:02.640');
  assert.equal(formatVttTimestamp(3_726_005), '01:02:06.005');
  assert.equal(formatVttTimestamp(-5), '00:00:00.000');
});

test('buildVtt emits cue ids, timings and skips empty text', () => {
  const source = buildSourceVtt(SEGMENTS);
  assert.equal(
    source,
    [
      'WEBVTT',
      '',
      '1',
      '00:00:00.000 --> 00:00:02.640',
      'Welcome back to Slow English News.',
      '',
      '2',
      '00:00:02.700 --> 00:00:06.900',
      'Today we talk about a small library.',
      ''
    ].join('\n')
  );
  const target = buildTargetVtt(SEGMENTS);
  assert.ok(target.includes('欢迎回到慢速英语新闻。'));
  const withEmpty = buildTargetVtt([{ ...SEGMENTS[0], translation: ' ' }, SEGMENTS[1]]);
  assert.ok(!withEmpty.includes('00:00:00.000 --> 00:00:02.640'));
  assert.ok(withEmpty.includes('今天我们谈谈一座小图书馆。'));
});

test('happy path: publishes segments, both VTTs and raw transcript', async () => {
  const fx = await setup();
  try {
    const job = fx.store.claimNextJob('test-worker', 60_000);
    assert.ok(job);
    const result = await runPackagingStage(
      job,
      {
        store: fx.store,
        layout: fx.layout,
        objectStore: fx.objectStore,
        config: fx.config,
        logger: new RedactingLogger()
      },
      makeHooks(fx.store, fx.jobId)
    );

    const manifest = result.manifest as {
      files: Array<{ name: string; role: string; required: boolean; status: string }>;
      sourceFingerprint: string;
      audioFingerprint: string;
      pipelineVersion: string;
    };
    assert.deepEqual(
      manifest.files.map((f) => [f.name, f.role, f.required, f.status]),
      [
        ['segments.json', 'segments', true, 'ready'],
        ['source.vtt', 'sourceVtt', true, 'ready'],
        ['target.vtt', 'targetVtt', true, 'ready'],
        ['raw-transcript.json', 'rawTranscript', false, 'ready']
      ]
    );
    assert.equal(manifest.sourceFingerprint, SOURCE_FINGERPRINT);
    assert.equal(manifest.audioFingerprint, AUDIO_SHA);
    assert.equal(manifest.pipelineVersion, 'v10.1');

    // Every published object exists at its final key; temp objects are gone.
    for (const name of ['segments.json', 'source.vtt', 'target.vtt', 'raw-transcript.json', 'manifest.json']) {
      const head = await fx.objectStore.head(fx.layout.jobArtifact(fx.jobId, name));
      assert.ok(head, `missing published object ${name}`);
    }
    const tempKeys = await fx.objectStore.listKeys(fx.layout.jobArtifact(fx.jobId, '.tmp-'));
    assert.deepEqual(tempKeys, []);

    // segments.json uses the contract envelope.
    const segmentsData = await fx.objectStore.getRange(fx.layout.jobArtifact(fx.jobId, 'segments.json'));
    const envelope = JSON.parse(segmentsData.toString('utf8')) as {
      schemaVersion: number;
      sourceLanguage: string;
      targetLanguage: string;
      segments: LearningSegment[];
    };
    assert.equal(envelope.schemaVersion, 1);
    assert.equal(envelope.sourceLanguage, 'en');
    assert.equal(envelope.targetLanguage, 'zh-Hans');
    assert.equal(envelope.segments.length, 2);
    assert.equal(envelope.segments[0].playbackSentence?.id, 1);

    // manifestRef carries the client-facing subset.
    assert.ok(result.manifestRef.files);
    assert.equal(result.manifestRef.sourceFingerprint, SOURCE_FINGERPRINT);
  } finally {
    await fx.cleanup();
  }
});

test('missing raw transcript object still publishes ready artifacts', async () => {
  const fx = await setup({ rawTranscript: false });
  try {
    const job = fx.store.claimNextJob('test-worker', 60_000);
    assert.ok(job);
    const result = await runPackagingStage(
      job,
      {
        store: fx.store,
        layout: fx.layout,
        objectStore: fx.objectStore,
        config: fx.config,
        logger: new RedactingLogger()
      },
      makeHooks(fx.store, fx.jobId)
    );
    const manifest = result.manifest as { files: Array<{ name: string }> };
    assert.deepEqual(
      manifest.files.map((f) => f.name),
      ['segments.json', 'source.vtt', 'target.vtt']
    );
  } finally {
    await fx.cleanup();
  }
});

test('no refinement checkpoint is an internal error (never ready half-built)', async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), 'packaging-test-'));
  const config = fakeConfig(tempRoot);
  const db = openDatabase(config.databasePath, MIGRATIONS_DIR);
  const store = new JobStore(db);
  try {
    store.createJob({
      ownerScope: 'test-owner',
      contentType: 'podcast_episode',
      contentKey: podcastContentKey('https://example.com/feed.xml', 'ep-501'),
      source: { platform: 'rss', sourceId: 'ep-501', url: 'https://media.example.com/ep.mp3' },
      sourceLanguage: 'en',
      targetLanguage: 'zh-Hans',
      translationQuality: 'fast',
      pipelineVersion: 'v10.1',
      clientArtifactSchemaVersion: 1
    });
    const job = store.claimNextJob('test-worker', 60_000);
    assert.ok(job);
    await assert.rejects(
      runPackagingStage(
        job,
        {
          store,
          layout: new KeyLayout(config.r2),
          objectStore: new InMemoryObjectStore(),
          config,
          logger: new RedactingLogger()
        },
        makeHooks(store, job.jobId)
      ),
      (error: unknown) => {
        assert.ok(error instanceof PipelineJobError);
        assert.equal(error.jobError.code, 'INTERNAL_ERROR');
        assert.equal(error.jobError.failedStage, 'packaging');
        return true;
      }
    );
  } finally {
    store.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});
