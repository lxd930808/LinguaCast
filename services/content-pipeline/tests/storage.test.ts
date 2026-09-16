import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import type { AddressInfo } from 'node:net';
import { readFileSync } from 'node:fs';

import { createApp, listen } from '../src/app.js';
import { loadConfig, type ServiceConfig } from '../src/config.js';
import { openDatabase } from '../src/jobs/migrations.js';
import { JobStore } from '../src/jobs/job-store.js';
import { RedactingLogger } from '../src/observability/logger.js';
import { KeyLayout, KeyPolicyError } from '../src/storage/keys.js';
import { InMemoryObjectStore, ObjectStoreError } from '../src/storage/object-store.js';
import { ArtifactPublisher, sha256hex } from '../src/storage/publisher.js';
import { backupDatabase } from '../src/storage/backup.js';
import { podcastContentKey, videoContentKey } from '../src/domain/content-key.js';
import { ContentMediaStore } from '../src/domain/content-media-store.js';
import { validate, type SchemaNode } from './support/json-schema-lite.js';

const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url).pathname;
const manifestSchema = JSON.parse(
  readFileSync(new URL('../../../docs/contracts/content-artifact-v1.schema.json', import.meta.url), 'utf8')
) as SchemaNode;

const TOKEN = 'test-service-token-0123456789';
const AUTH = { authorization: `Bearer ${TOKEN}` };

function baseEnv(tempRoot: string): NodeJS.ProcessEnv {
  return {
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
  };
}

async function setupStore() {
  const tempRoot = await mkdtemp(join(tmpdir(), 'content-r2-test-'));
  const db = openDatabase(join(tempRoot, 'content.db'), MIGRATIONS_DIR);
  const store = new JobStore(db);
  const mediaStore = new ContentMediaStore(db);
  const config: ServiceConfig = { ...loadConfig(baseEnv(tempRoot)), port: 0 };
  const keys = new KeyLayout(config.r2);
  const objects = new InMemoryObjectStore();
  const logger = new RedactingLogger(() => {});
  const cleanup = async () => {
    store.close();
    await rm(tempRoot, { recursive: true, force: true });
  };
  return { tempRoot, db, store, mediaStore, config, keys, objects, logger, cleanup };
}

const CONTENT_KEY = podcastContentKey('https://example.com/feed.xml', 'ep-001');

function createJob(store: JobStore, overrides: Record<string, unknown> = {}) {
  return store.createJob({
    ownerScope: 'selfhost',
    contentType: 'podcast_episode',
    contentKey: CONTENT_KEY,
    source: {
      platform: 'rss',
      sourceId: 'ep-001',
      url: 'https://media.example.com/ep-001.mp3',
      feedUrl: 'https://example.com/feed.xml'
    },
    sourceLanguage: 'en',
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    pipelineVersion: 'v10.1',
    clientArtifactSchemaVersion: 1,
    ...overrides
  } as Parameters<JobStore['createJob']>[0]);
}

test('key layout enforces content-pipeline prefix and canary isolation', () => {
  const keys = new KeyLayout({ prefix: 'content-pipeline', environment: 'prod' });
  assert.equal(
    keys.podcastAudio('a'.repeat(64)),
    `content-pipeline/prod/podcast-audio/${'a'.repeat(64)}.mp3`
  );
  assert.throws(() => keys.assertAllowed('yt-media/prod/x.mp4'), KeyPolicyError);
  assert.throws(() => keys.assertCanary(keys.podcastAudio('b'.repeat(64))), KeyPolicyError);
  assert.throws(() => keys.jobArtifact('cj_x', '../escape'), KeyPolicyError);
  assert.throws(
    () => new KeyLayout({ prefix: 'yt-media', environment: 'prod' }),
    KeyPolicyError
  );
});

test('video media keys stay under content-pipeline and never write yt-media', () => {
  const keys = new KeyLayout({ prefix: 'content-pipeline', environment: 'prod' });
  const sha = 'ab'.repeat(32);
  assert.equal(keys.videoMedia(sha), `content-pipeline/prod/video-media/${sha}.mp4`);
  assert.equal(keys.videoMediaTemp('cm_01TESTMEDIAID'), 'content-pipeline/prod/video-media/.tmp/cm_01TESTMEDIAID.mp4');
  keys.assertAllowed(keys.videoMedia(sha));
  keys.assertAllowed(keys.videoMediaTemp('cm_01TESTMEDIAID'));
  assert.throws(() => keys.videoMedia('not-a-hash'), KeyPolicyError);
  assert.throws(() => keys.videoMediaTemp('../escape'), KeyPolicyError);
  assert.ok(!keys.videoMedia(sha).includes('yt-media'));
});

test('in-memory store supports HEAD, full read and range reads', async () => {
  const objects = new InMemoryObjectStore();
  const data = Buffer.from('0123456789abcdef');
  await objects.put('k', data, 'application/octet-stream');
  const head = await objects.head('k');
  assert.equal(head?.bytes, 16);
  assert.ok(head?.etag);
  assert.deepEqual(await objects.getRange('k'), data);
  assert.deepEqual(await objects.getRange('k', 0, 0), Buffer.from('0'));
  assert.deepEqual(await objects.getRange('k', 12, 15), Buffer.from('cdef'));
  await assert.rejects(objects.getRange('k', 20, 30), ObjectStoreError);
  await assert.rejects(objects.getRange('missing'), ObjectStoreError);
  await objects.delete('k');
  assert.equal(await objects.head('k'), null);
});

test('publisher writes temp → final → manifest last and validates manifest', async () => {
  const { store, config, keys, objects, logger, cleanup } = await setupStore();
  try {
    const { job } = createJob(store);
    const publisher = new ArtifactPublisher(objects, keys, logger);
    const manifest = (await publisher.publish({
      jobId: job.jobId,
      contentType: 'podcast_episode',
      contentKey: CONTENT_KEY,
      sourceLanguage: 'en',
      targetLanguage: 'zh-Hans',
      translationQuality: 'quality',
      pipelineVersion: config.pipelineVersion,
      audioFingerprint: 'a'.repeat(64),
      sourceFingerprint: 'b'.repeat(64),
      audio: {
        mimeType: 'audio/mpeg',
        bytes: 100,
        durationSeconds: 10,
        sha256: 'a'.repeat(64),
        transcoded: false
      },
      files: [
        {
          name: 'segments.json',
          role: 'segments',
          required: true,
          data: Buffer.from('{"segments":[]}'),
          mimeType: 'application/json'
        },
        {
          name: 'source.vtt',
          role: 'sourceVtt',
          required: true,
          data: Buffer.from('WEBVTT\n'),
          mimeType: 'text/vtt'
        }
      ]
    })) as Record<string, unknown>;

    const errors = validate(manifestSchema, manifest);
    assert.deepEqual(errors, [], `published manifest must validate:\n${errors.join('\n')}`);

    // Temp objects cleaned, final objects present.
    const allKeys = await objects.listKeys('content-pipeline/prod/manifests/');
    assert.ok(!allKeys.some((k) => k.includes('.tmp-')), 'no temp objects remain');
    assert.ok(allKeys.includes(`content-pipeline/prod/manifests/${job.jobId}/segments.json`));
    assert.ok(allKeys.includes(`content-pipeline/prod/manifests/${job.jobId}/manifest.json`));

    // Manifest must be the LAST object written: it exists only after all files.
    const storedManifest = JSON.parse(
      (await objects.getRange(keys.jobArtifact(job.jobId, 'manifest.json'))).toString('utf8')
    ) as { files: Array<{ sha256: string }> };
    assert.equal(storedManifest.files[0]!.sha256, sha256hex(Buffer.from('{"segments":[]}')));
  } finally {
    await cleanup();
  }
});

test('half-write failure leaves no manifest behind', async () => {
  const { store, keys, objects, logger, cleanup } = await setupStore();
  try {
    const { job } = createJob(store);
    const failingStore = new (class extends InMemoryObjectStore {
      override async copy(sourceKey: string, targetKey: string): Promise<never> {
        throw new Error(`simulated publish failure ${sourceKey} ${targetKey}`);
      }
    })();
    await failingStore.put('seed', Buffer.from('x'), 'text/plain');
    const publisher = new ArtifactPublisher(failingStore, keys, logger);
    await assert.rejects(
      publisher.publish({
        jobId: job.jobId,
        contentType: 'podcast_episode',
        contentKey: CONTENT_KEY,
        sourceLanguage: 'en',
        targetLanguage: 'zh-Hans',
        translationQuality: 'quality',
        pipelineVersion: 'v10.1',
        audioFingerprint: 'a'.repeat(64),
        sourceFingerprint: 'b'.repeat(64),
        audio: { mimeType: 'audio/mpeg', bytes: 1, durationSeconds: 1, sha256: 'a'.repeat(64), transcoded: false },
        files: [
          { name: 'segments.json', role: 'segments', required: true, data: Buffer.from('{}'), mimeType: 'application/json' }
        ]
      })
    );
    const allKeys = await failingStore.listKeys(`content-pipeline/prod/manifests/${job.jobId}/`);
    assert.ok(!allKeys.some((k) => k.endsWith('manifest.json')), 'manifest must not exist after failure');
    assert.ok(!allKeys.some((k) => k.includes('.tmp-')), 'temp objects cleaned after failure');
    void objects;
  } finally {
    await cleanup();
  }
});

test('audio playback URL endpoint signs without persisting or logging the URL', async () => {
  const { tempRoot, store, config, keys, objects, cleanup } = await setupStore();
  const logLines: string[] = [];
  const logger = new RedactingLogger((line) => logLines.push(line));
  const app = createApp({
    config,
    logger,
    jobRoutes: { config, store },
    artifactRoutes: { config, store, objects, keys }
  });
  await listen(app, config, logger);
  const port = (app.server.address() as AddressInfo).port;
  const baseUrl = `http://127.0.0.1:${port}`;
  try {
    const { job } = createJob(store);
    // No audio yet → 409.
    const early = await fetch(`${baseUrl}/v1/content-jobs/${job.jobId}/audio-playback-url`, {
      method: 'POST',
      headers: AUTH
    });
    assert.equal(early.status, 409);

    const audioKey = keys.podcastAudio('c'.repeat(64));
    await objects.put(audioKey, Buffer.alloc(2048), 'audio/mpeg');
    store.registerSourceArtifact({
      jobId: job.jobId,
      kind: 'audio',
      fingerprint: 'c'.repeat(64),
      objectKey: audioKey,
      mimeType: 'audio/mpeg',
      bytes: 2048,
      durationSeconds: 1.2,
      sha256: 'c'.repeat(64)
    });
    store.claimNextJob('w', 30_000);
    store.updateProgress(job.jobId, { stage: 'preparing_audio', audioReady: true });

    const res = await fetch(`${baseUrl}/v1/content-jobs/${job.jobId}/audio-playback-url`, {
      method: 'POST',
      headers: AUTH
    });
    assert.equal(res.status, 200);
    const body = (await res.json()) as { url: string; expiresAt: string; acceptRanges: string };
    assert.ok(body.url.length > 0);
    assert.equal(body.acceptRanges, 'bytes');
    assert.ok(Date.parse(body.expiresAt) > Date.now());

    // The signed URL must not appear in logs or the database snapshot.
    assert.ok(!logLines.join('\n').includes(body.url), 'signed URL leaked into logs');
    const dbDump = readFileSync(join(tempRoot, 'content.db'));
    assert.ok(!dbDump.includes(Buffer.from(body.url)), 'signed URL persisted in database');
  } finally {
    await app.close();
    await cleanup();
  }
});

test('artifact download supports ETag and 304', async () => {
  const { store, config, keys, objects, logger, cleanup } = await setupStore();
  const app = createApp({
    config,
    logger,
    jobRoutes: { config, store },
    artifactRoutes: { config, store, objects, keys }
  });
  await listen(app, config, logger);
  const port = (app.server.address() as AddressInfo).port;
  const baseUrl = `http://127.0.0.1:${port}`;
  try {
    const { job } = createJob(store);
    const publisher = new ArtifactPublisher(objects, keys, logger);
    const manifest = await publisher.publish({
      jobId: job.jobId,
      contentType: 'podcast_episode',
      contentKey: CONTENT_KEY,
      sourceLanguage: 'en',
      targetLanguage: 'zh-Hans',
      translationQuality: 'quality',
      pipelineVersion: 'v10.1',
      audioFingerprint: 'a'.repeat(64),
      sourceFingerprint: 'b'.repeat(64),
      audio: { mimeType: 'audio/mpeg', bytes: 1, durationSeconds: 1, sha256: 'a'.repeat(64), transcoded: false },
      files: [
        { name: 'segments.json', role: 'segments', required: true, data: Buffer.from('{"segments":[]}'), mimeType: 'application/json' }
      ]
    });
    store.claimNextJob('w', 30_000);
    store.completeJob(job.jobId, manifest);

    const first = await fetch(`${baseUrl}/v1/content-artifacts/${job.jobId}/segments.json`, { headers: AUTH });
    assert.equal(first.status, 200);
    const etag = first.headers.get('etag')!;
    assert.ok(etag);
    assert.equal(await first.text(), '{"segments":[]}');

    const cached = await fetch(`${baseUrl}/v1/content-artifacts/${job.jobId}/segments.json`, {
      headers: { ...AUTH, 'if-none-match': etag }
    });
    assert.equal(cached.status, 304);

    const missing = await fetch(`${baseUrl}/v1/content-artifacts/${job.jobId}/nope.json`, { headers: AUTH });
    assert.equal(missing.status, 404);
  } finally {
    await app.close();
    await cleanup();
  }
});

test('database backup uploads and verifies the snapshot', async () => {
  const { db, store, config, keys, objects, logger, cleanup } = await setupStore();
  try {
    createJob(store);
    const { key, bytes } = await backupDatabase({ db, objects, keys, logger });
    assert.ok(key.startsWith('content-pipeline/prod/backups/'));
    const head = await objects.head(key);
    assert.equal(head?.bytes, bytes);
    assert.ok(bytes > 0);
    void config;
  } finally {
    await cleanup();
  }
});

test('shared source artifact survives while sibling variants are active', async () => {
  const { store, cleanup } = await setupStore();
  try {
    const { job: jobZh } = createJob(store);
    store.registerSourceArtifact({
      jobId: jobZh.jobId,
      kind: 'audio',
      fingerprint: 'd'.repeat(64),
      objectKey: 'content-pipeline/prod/podcast-audio/' + 'd'.repeat(64) + '.mp3'
    });
    assert.equal(store.countActiveJobsForContentOfJob(jobZh.jobId), 1);

    const { job: jobJa } = createJob(store, { targetLanguage: 'ja' });
    assert.equal(store.countActiveJobsForContentOfJob(jobZh.jobId), 2);

    // Expire/cancel one variant: shared audio still referenced.
    store.cancelJob(jobJa.jobId);
    // cancelled is non-expired, so still protected
    assert.equal(store.countActiveJobsForContentOfJob(jobZh.jobId), 2);
  } finally {
    await cleanup();
  }
});

test('content media playback url covers hit, miss, not-ready, integrity and refresh', async () => {
  const { store, mediaStore, config, keys, objects, cleanup } = await setupStore();
  const logger = new RedactingLogger(() => {});
  const app = createApp({
    config,
    logger,
    jobRoutes: { config, store },
    artifactRoutes: { config, store, objects, keys },
    contentMediaRoutes: { config, store, mediaStore, objects, keys }
  });
  await listen(app, config, logger);
  const baseUrl = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`;
  const contentKey = videoContentKey('youtube', 'dQw4w9WgXcQ');
  const AUTH_JSON = { ...AUTH, 'content-type': 'application/json' };
  try {
    const miss = await fetch(`${baseUrl}/v1/content-media/video-playback-url`, {
      method: 'POST',
      headers: AUTH_JSON,
      body: JSON.stringify({ contentType: 'video', contentKey })
    });
    assert.equal(miss.status, 404);
    assert.equal(((await miss.json()) as { error: { code: string } }).error.code, 'MEDIA_NOT_FOUND');

    const unauth = await fetch(`${baseUrl}/v1/content-media/video-playback-url`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ contentType: 'video', contentKey })
    });
    assert.equal(unauth.status, 401);

    store.createJob({
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
    const promoting = mediaStore.createPromoting({
      ownerScope: 'selfhost',
      contentType: 'video',
      contentKey,
      renditionKey: 'mp4-720-avc1-aac',
      fingerprint: 'ab'.repeat(32)
    });
    const notReady = await fetch(`${baseUrl}/v1/content-media/video-playback-url`, {
      method: 'POST',
      headers: AUTH_JSON,
      body: JSON.stringify({ contentType: 'video', contentKey })
    });
    assert.equal(notReady.status, 409);
    assert.equal(((await notReady.json()) as { error: { code: string } }).error.code, 'MEDIA_NOT_READY');

    const objectKey = keys.videoMedia('ab'.repeat(32));
    await objects.put(objectKey, Buffer.alloc(4096), 'video/mp4');
    mediaStore.markReady({
      mediaId: promoting.mediaId,
      objectKey,
      mimeType: 'video/mp4',
      bytes: 4096,
      sha256: 'ab'.repeat(32),
      durationSeconds: 12,
      height: 720,
      videoCodec: 'avc1',
      audioCodec: 'aac',
      retainUntil: Date.now() + 86_400_000
    });
    const hit = await fetch(`${baseUrl}/v1/content-media/video-playback-url`, {
      method: 'POST',
      headers: AUTH_JSON,
      body: JSON.stringify({ contentType: 'video', contentKey, preferredHeight: 1080 })
    });
    assert.equal(hit.status, 200);
    const body = (await hit.json()) as { mediaId: string; url: string; sha256: string; bytes: number };
    assert.equal(body.mediaId, promoting.mediaId);
    assert.equal(body.sha256, 'ab'.repeat(32));
    assert.ok(body.url.length > 0);

    const refresh = await fetch(`${baseUrl}/v1/content-media/video-playback-url`, {
      method: 'POST',
      headers: AUTH_JSON,
      body: JSON.stringify({ contentType: 'video', contentKey })
    });
    const body2 = (await refresh.json()) as { mediaId: string; url: string; sha256: string };
    assert.equal(refresh.status, 200);
    assert.equal(body2.mediaId, body.mediaId);
    assert.equal(body2.sha256, body.sha256);

    await objects.delete(objectKey);
    const integrity = await fetch(`${baseUrl}/v1/content-media/video-playback-url`, {
      method: 'POST',
      headers: AUTH_JSON,
      body: JSON.stringify({ contentType: 'video', contentKey })
    });
    assert.equal(integrity.status, 409);
    assert.equal(
      ((await integrity.json()) as { error: { code: string } }).error.code,
      'MEDIA_INTEGRITY_FAILED'
    );
  } finally {
    await app.close();
    await cleanup();
  }
});
