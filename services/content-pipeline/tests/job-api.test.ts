import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import type { AddressInfo } from 'node:net';

import { createApp, listen, type AppHandle } from '../src/app.js';
import { loadConfig, type ServiceConfig } from '../src/config.js';
import { openDatabase } from '../src/jobs/migrations.js';
import { JobStore } from '../src/jobs/job-store.js';
import { ContentWorker, type PipelineExecutor } from '../src/jobs/worker.js';
import { RedactingLogger } from '../src/observability/logger.js';
import { podcastContentKey, videoContentKey } from '../src/domain/content-key.js';
import { ContentMediaStore, ContentMediaStoreError } from '../src/domain/content-media-store.js';
import { validate, type SchemaNode } from './support/json-schema-lite.js';
import { readFileSync } from 'node:fs';

const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url).pathname;
const wireSchema = JSON.parse(
  readFileSync(new URL('../../../docs/contracts/content-job-v1.wire.schema.json', import.meta.url), 'utf8')
) as SchemaNode;

function assertWireCompliance(body: unknown, label: string): void {
  const errors = validate(
    { $ref: '#/definitions/ContentJobResponse', definitions: wireSchema.definitions },
    body
  );
  assert.deepEqual(errors, [], `${label} response must match the wire schema:\n${errors.join('\n')}`);
}

const TOKEN = 'test-service-token-0123456789';
const AUTH = { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' };

const PODCAST_BODY = {
  contentType: 'podcast_episode',
  contentKey: podcastContentKey('https://example.com/feed.xml', 'ep-001'),
  source: {
    platform: 'rss',
    sourceId: 'ep-001',
    url: 'https://media.example.com/ep-001.mp3',
    feedUrl: 'https://example.com/feed.xml'
  },
  sourceLanguage: 'en',
  targetLanguage: 'zh-Hans',
  translationQuality: 'quality',
  clientArtifactSchemaVersion: 1
};

interface TestContext {
  baseUrl: string;
  store: JobStore;
  app: AppHandle;
  cleanup: () => Promise<void>;
}

async function setup(): Promise<TestContext> {
  const tempRoot = await mkdtemp(join(tmpdir(), 'content-jobs-test-'));
  const logger = new RedactingLogger(() => {});
  const config: ServiceConfig = {
    ...loadConfig({
      CONTENT_IDENTITY_MODE: 'selfhost', CONTENT_SERVICE_TOKEN: TOKEN,
      MEDIA_API_TOKEN: 'test-media-token-0123456789',
      DASHSCOPE_API_KEY: 'test-dashscope-key-0123456789',
      TRANSLATION_API_KEY: 'test-translation-key-0123456789',
      TRANSLATION_MODEL: 'test-model',
      R2_ACCOUNT_ID: 'acct',
      R2_ACCESS_KEY_ID: 'r2-access',
      R2_SECRET_ACCESS_KEY: 'r2-secret-0123456789',
      R2_BUCKET: 'linguacast',
      CONTENT_TEMP_ROOT: tempRoot
    }),
    port: 0
  };
  const db = openDatabase(join(tempRoot, 'content.db'), MIGRATIONS_DIR);
  const store = new JobStore(db);
  const app = createApp({ config, logger, jobRoutes: { config, store } });
  await listen(app, config, logger);
  const port = (app.server.address() as AddressInfo).port;
  return {
    baseUrl: `http://127.0.0.1:${port}`,
    store,
    app,
    cleanup: async () => {
      await app.close();
      store.close();
      await rm(tempRoot, { recursive: true, force: true });
    }
  };
}

async function createJobRequest(baseUrl: string, body: unknown, headers?: Record<string, string>) {
  return fetch(`${baseUrl}/v1/content-jobs`, {
    method: 'POST',
    headers: { ...AUTH, ...headers },
    body: JSON.stringify(body)
  });
}

test('create returns 202 queued and duplicate create reuses the job', async () => {
  const ctx = await setup();
  try {
    const res = await createJobRequest(ctx.baseUrl, PODCAST_BODY);
    assert.equal(res.status, 202);
    const job = (await res.json()) as Record<string, unknown>;
    assertWireCompliance(job, 'create');
    assert.equal(job.status, 'queued');
    assert.equal(job.reused, false);

    const res2 = await createJobRequest(ctx.baseUrl, PODCAST_BODY);
    assert.equal(res2.status, 200);
    const job2 = (await res2.json()) as Record<string, unknown>;
    assert.equal(job2.jobId, job.jobId);
    assert.equal(job2.reused, true);
  } finally {
    await ctx.cleanup();
  }
});

test('100 concurrent creates with the same variant produce exactly one job', async () => {
  const ctx = await setup();
  try {
    const responses = await Promise.all(
      Array.from({ length: 100 }, () => createJobRequest(ctx.baseUrl, PODCAST_BODY))
    );
    const jobs = (await Promise.all(responses.map((r) => r.json()))) as Array<{ jobId: string }>;
    const ids = new Set(jobs.map((j) => j.jobId));
    assert.equal(ids.size, 1);
    assert.equal(responses.filter((r) => r.status === 202).length, 1);
  } finally {
    await ctx.cleanup();
  }
});

test('different target language creates a distinct variant job', async () => {
  const ctx = await setup();
  try {
    const first = (await (await createJobRequest(ctx.baseUrl, PODCAST_BODY)).json()) as { jobId: string };
    const second = (await (
      await createJobRequest(ctx.baseUrl, { ...PODCAST_BODY, targetLanguage: 'ja' })
    ).json()) as { jobId: string };
    assert.notEqual(first.jobId, second.jobId);
  } finally {
    await ctx.cleanup();
  }
});

test('Idempotency-Key reused with a different payload returns 409', async () => {
  const ctx = await setup();
  try {
    const res = await createJobRequest(ctx.baseUrl, PODCAST_BODY, { 'idempotency-key': 'client-abc' });
    assert.equal(res.status, 202);
    const conflict = await createJobRequest(
      ctx.baseUrl,
      { ...PODCAST_BODY, targetLanguage: 'ja' },
      { 'idempotency-key': 'client-abc' }
    );
    assert.equal(conflict.status, 409);
    const body = (await conflict.json()) as { error: { code: string } };
    assert.equal(body.error.code, 'IDEMPOTENCY_CONFLICT');
  } finally {
    await ctx.cleanup();
  }
});

test('Idempotency-Key after a failed job creates a new job with the updated source URL', async () => {
  const ctx = await setup();
  try {
    const first = await createJobRequest(ctx.baseUrl, PODCAST_BODY, { 'idempotency-key': 'assistant-same' });
    assert.equal(first.status, 202);
    const created = (await first.json()) as { jobId: string };
    ctx.store.claimNextJob('w1', 30_000);
    ctx.store.failJob(created.jobId, {
      code: 'UNSUPPORTED_AUDIO',
      message: 'unexpected content type text/html',
      retryable: false,
      failedStage: 'fetching_audio',
      traceId: 'tr_test'
    });

    const enclosure = 'https://traffic.megaphone.fm/APO4554511240.mp3';
    const second = await createJobRequest(
      ctx.baseUrl,
      { ...PODCAST_BODY, source: { ...PODCAST_BODY.source, url: enclosure } },
      { 'idempotency-key': 'assistant-same' }
    );
    assert.equal(second.status, 202);
    const retried = (await second.json()) as { jobId: string; reused: boolean };
    assert.notEqual(retried.jobId, created.jobId);
    assert.equal(retried.reused, false);
    const lookup = (await (
      await fetch(
        `${ctx.baseUrl}/v1/content-jobs:lookup?contentType=podcast_episode&contentKey=${encodeURIComponent(
          PODCAST_BODY.contentKey
        )}&targetLanguage=zh-Hans&translationQuality=quality`,
        { headers: AUTH }
      )
    ).json()) as { job: { jobId: string; source: { url: string } } };
    assert.equal(lookup.job.jobId, retried.jobId);
    assert.equal(lookup.job.source.url, enclosure);
  } finally {
    await ctx.cleanup();
  }
});

test('mismatched contentKey is rejected; too-new schema version returns 422', async () => {
  const ctx = await setup();
  try {
    const bad = await createJobRequest(ctx.baseUrl, { ...PODCAST_BODY, contentKey: 'podcast:xx:yy' });
    assert.equal(bad.status, 400);

    const tooNew = await createJobRequest(ctx.baseUrl, { ...PODCAST_BODY, clientArtifactSchemaVersion: 3 });
    assert.equal(tooNew.status, 422);
    const body = (await tooNew.json()) as { error: { code: string } };
    assert.equal(body.error.code, 'PIPELINE_VERSION_UNSUPPORTED');
  } finally {
    await ctx.cleanup();
  }
});

test('unauthorized and unknown job requests are rejected', async () => {
  const ctx = await setup();
  try {
    const noAuth = await fetch(`${ctx.baseUrl}/v1/content-jobs/cj_XXXXXXXXXXXXXXXXXXXXXXXX`);
    assert.equal(noAuth.status, 401);

    const missing = await fetch(`${ctx.baseUrl}/v1/content-jobs/cj_XXXXXXXXXXXXXXXXXXXXXXXX`, {
      headers: AUTH
    });
    assert.equal(missing.status, 404);
    const body = (await missing.json()) as { error: { code: string } };
    assert.equal(body.error.code, 'JOB_NOT_FOUND');
  } finally {
    await ctx.cleanup();
  }
});

test('lookup returns the job by variant and null when absent', async () => {
  const ctx = await setup();
  try {
    const created = (await (await createJobRequest(ctx.baseUrl, PODCAST_BODY)).json()) as { jobId: string };
    const query = `contentType=podcast_episode&contentKey=${encodeURIComponent(
      PODCAST_BODY.contentKey
    )}&targetLanguage=zh-Hans&translationQuality=quality`;
    const hit = (await (
      await fetch(`${ctx.baseUrl}/v1/content-jobs:lookup?${query}`, { headers: AUTH })
    ).json()) as { job: { jobId: string } | null };
    assert.equal(hit.job?.jobId, created.jobId);

    const miss = (await (
      await fetch(
        `${ctx.baseUrl}/v1/content-jobs:lookup?contentType=video&contentKey=${encodeURIComponent(
          videoContentKey('youtube', 'nope123')
        )}&targetLanguage=zh-Hans&translationQuality=fast`,
        { headers: AUTH }
      )
    ).json()) as { job: unknown };
    assert.equal(miss.job, null);
  } finally {
    await ctx.cleanup();
  }
});

test('fake worker drives queued → running → ready and responses stay wire-compliant', async () => {
  const executor: PipelineExecutor = async ({ updateProgress, recordCheckpoint }) => {
    updateProgress({ stage: 'fetching_audio', progress: 0.2, stageProgress: 0.8 });
    recordCheckpoint({ stage: 'fetching_audio', output: { objectKey: 'audio.mp3' } });
    updateProgress({ stage: 'transcribing', progress: 0.5 });
    updateProgress({ stage: 'packaging', progress: 0.99, audioReady: true });
    return {
      schemaVersion: 1,
      pipelineVersion: 'v10.1',
      generatedAt: new Date().toISOString(),
      audioFingerprint: 'a'.repeat(64),
      sourceFingerprint: 'b'.repeat(64),
      files: [
        {
          name: 'segments.json',
          role: 'segments',
          required: true,
          status: 'ready',
          mimeType: 'application/json',
          bytes: 10,
          sha256: 'c'.repeat(64)
        }
      ]
    };
  };
  const ctx = await setup();
  try {
    const created = (await (await createJobRequest(ctx.baseUrl, PODCAST_BODY)).json()) as { jobId: string };
    const store = ctx.store;
    const worker = new ContentWorker({
      store,
      logger: new RedactingLogger(() => {}),
      workerId: 'test-worker',
      executor
    });
    const ran = await worker.runOnce();
    assert.equal(ran, true);

    const res = await fetch(`${ctx.baseUrl}/v1/content-jobs/${created.jobId}`, { headers: AUTH });
    const job = (await res.json()) as Record<string, unknown>;
    assertWireCompliance(job, 'ready job');
    assert.equal(job.status, 'ready');
    assert.equal(job.progress, 1);
    assert.ok(job.artifacts, 'ready job exposes the manifest');
  } finally {
    await ctx.cleanup();
  }
});

test('progress never regresses and is clamped to the stage band', async () => {
  const ctx = await setup();
  try {
    const created = (await (await createJobRequest(ctx.baseUrl, PODCAST_BODY)).json()) as { jobId: string };
    const job = ctx.store.claimNextJob('w1', 30_000)!;
    assert.equal(job.jobId, created.jobId);

    ctx.store.updateProgress(created.jobId, { stage: 'transcribing', progress: 0.5 });
    ctx.store.updateProgress(created.jobId, { stage: 'transcribing', progress: 0.2 }); // regression attempt
    let current = ctx.store.getJob(created.jobId)!;
    assert.equal(current.progress, 0.5);

    ctx.store.updateProgress(created.jobId, { stage: 'packaging' }); // no explicit progress
    current = ctx.store.getJob(created.jobId)!;
    assert.equal(current.progress, 0.97, 'stage floor applies');
  } finally {
    await ctx.cleanup();
  }
});

test('lease expiry recovery returns running jobs to queued without losing data', async () => {
  const ctx = await setup();
  try {
    const created = (await (await createJobRequest(ctx.baseUrl, PODCAST_BODY)).json()) as { jobId: string };
    ctx.store.claimNextJob('crashed-worker', 1_000, Date.now() - 60_000);
    let job = ctx.store.getJob(created.jobId)!;
    assert.equal(job.status, 'running');

    const reclaimed = ctx.store.recoverInterruptedJobs();
    assert.equal(reclaimed, 1);
    job = ctx.store.getJob(created.jobId)!;
    assert.equal(job.status, 'queued');
  } finally {
    await ctx.cleanup();
  }
});

test('retry resets a retryable failure; non-retryable and terminal states reject', async () => {
  const ctx = await setup();
  try {
    const created = (await (await createJobRequest(ctx.baseUrl, PODCAST_BODY)).json()) as { jobId: string };
    ctx.store.claimNextJob('w1', 30_000);
    ctx.store.failJob(created.jobId, {
      code: 'ASR_FAILED',
      message: 'provider failed',
      retryable: true,
      failedStage: 'transcribing',
      traceId: 'tr_test'
    });

    const retried = await fetch(`${ctx.baseUrl}/v1/content-jobs/${created.jobId}/retry`, {
      method: 'POST',
      headers: AUTH
    });
    assert.equal(retried.status, 202);
    const job = (await retried.json()) as { status: string; error: unknown };
    assert.equal(job.status, 'queued');
    assert.equal(job.error, null);

    const retryAgain = await fetch(`${ctx.baseUrl}/v1/content-jobs/${created.jobId}/retry`, {
      method: 'POST',
      headers: AUTH
    });
    assert.equal(retryAgain.status, 409);
  } finally {
    await ctx.cleanup();
  }
});

test('cancel stops queued jobs and is idempotent on terminal jobs', async () => {
  const ctx = await setup();
  try {
    const created = (await (await createJobRequest(ctx.baseUrl, PODCAST_BODY)).json()) as { jobId: string };
    const cancelled = await fetch(`${ctx.baseUrl}/v1/content-jobs/${created.jobId}`, {
      method: 'DELETE',
      headers: AUTH
    });
    assert.equal(cancelled.status, 200);
    const job = (await cancelled.json()) as { status: string };
    assert.equal(job.status, 'cancelled');

    const again = await fetch(`${ctx.baseUrl}/v1/content-jobs/${created.jobId}`, {
      method: 'DELETE',
      headers: AUTH
    });
    assert.equal(again.status, 200);
  } finally {
    await ctx.cleanup();
  }
});

test('schema migration is upgrade-only and idempotent across reopen', async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), 'content-migration-test-'));
  try {
    const path = join(tempRoot, 'content.db');
    const first = openDatabase(path, MIGRATIONS_DIR);
    first.close();
    const second = openDatabase(path, MIGRATIONS_DIR);
    const versions = second.prepare('SELECT version FROM schema_migration ORDER BY version').all() as Array<{
      version: number;
    }>;
    assert.deepEqual(versions.map((v) => v.version), [1, 2, 3, 4]);
    second.close();
  } finally {
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test('0002 media store upgrades without losing 0001 jobs and is idempotent', async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), 'content-media-store-'));
  try {
    const path = join(tempRoot, 'content.db');
    const db = openDatabase(path, MIGRATIONS_DIR);
    const jobs = new JobStore(db);
    const contentKey = videoContentKey('youtube', 'dQw4w9WgXcQ');
    const created = jobs.createJob({
      ownerScope: 'selfhost',
      contentType: 'video',
      contentKey,
      source: { platform: 'youtube', sourceId: 'dQw4w9WgXcQ', url: 'https://youtu.be/dQw4w9WgXcQ' },
      sourceLanguage: 'en',
      targetLanguage: 'zh-Hans',
      translationQuality: 'fast',
      pipelineVersion: 'v10.1',
      clientArtifactSchemaVersion: 1
    });
    assert.equal(created.reused, false);
    db.close();

    const reopened = openDatabase(path, MIGRATIONS_DIR);
    const jobs2 = new JobStore(reopened);
    const media2 = new ContentMediaStore(reopened);
    const restored = jobs2.getJob(created.job.jobId);
    assert.ok(restored);
    assert.equal(restored?.contentKey, contentKey);

    const first = media2.createPromoting({
      ownerScope: 'selfhost',
      contentType: 'video',
      contentKey,
      renditionKey: 'mp4-720-avc1-aac',
      fingerprint: 'aa'.repeat(32)
    });
    const duplicate = media2.createPromoting({
      ownerScope: 'selfhost',
      contentType: 'video',
      contentKey,
      renditionKey: 'mp4-720-avc1-aac',
      fingerprint: 'aa'.repeat(32)
    });
    assert.equal(duplicate.mediaId, first.mediaId);

    assert.throws(
      () =>
        media2.createPromoting({
          ownerScope: 'other-owner',
          contentType: 'video',
          contentKey,
          renditionKey: 'mp4-720-avc1-aac',
          fingerprint: 'bb'.repeat(32)
        }),
      ContentMediaStoreError
    );

    const ready = media2.markReady({
      mediaId: first.mediaId,
      objectKey: 'content-pipeline/prod/video-media/' + 'aa'.repeat(32) + '.mp4',
      mimeType: 'video/mp4',
      bytes: 1024,
      sha256: 'aa'.repeat(32),
      durationSeconds: 12.5,
      height: 720,
      videoCodec: 'avc1',
      audioCodec: 'aac',
      retainUntil: Date.now() + 30 * 86400_000
    });
    assert.equal(ready.state, 'ready');
    assert.equal(ready.isCurrent, true);

    const secondFingerprint = media2.createPromoting({
      ownerScope: 'selfhost',
      contentType: 'video',
      contentKey,
      renditionKey: 'mp4-720-avc1-aac',
      fingerprint: 'cc'.repeat(32)
    });
    media2.markReady({
      mediaId: secondFingerprint.mediaId,
      objectKey: 'content-pipeline/prod/video-media/' + 'cc'.repeat(32) + '.mp4',
      mimeType: 'video/mp4',
      bytes: 2048,
      sha256: 'cc'.repeat(32),
      durationSeconds: 12.6,
      height: 720,
      videoCodec: 'avc1',
      audioCodec: 'aac',
      retainUntil: Date.now() + 30 * 86400_000
    });
    const currents = reopened
      .prepare(
        `SELECT media_id FROM content_media_asset WHERE content_id = ? AND is_current = 1`
      )
      .all(secondFingerprint.contentId) as Array<{ media_id: string }>;
    assert.equal(currents.length, 1);
    assert.equal(currents[0].media_id, secondFingerprint.mediaId);

    const hit = media2.currentReadyForContent('selfhost', 'video', contentKey);
    assert.equal(hit?.mediaId, secondFingerprint.mediaId);
    const miss = media2.currentReadyForContent('other-owner', 'video', contentKey);
    assert.equal(miss, null);

    jobs2.close();
  } finally {
    await rm(tempRoot, { recursive: true, force: true });
  }
});
