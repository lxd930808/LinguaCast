import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { loadConfig } from '../src/config.js';
import { videoContentKey } from '../src/domain/content-key.js';
import { ContentMediaStore } from '../src/domain/content-media-store.js';
import { openDatabase } from '../src/jobs/migrations.js';
import { JobStore } from '../src/jobs/job-store.js';
import { RedactingLogger } from '../src/observability/logger.js';
import { KeyLayout } from '../src/storage/keys.js';
import { InMemoryObjectStore } from '../src/storage/object-store.js';
import { MediaRetentionWorker } from '../src/storage/media-retention.js';

const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url).pathname;

test('retention deletes expired assets but skips retain window and is idempotent', async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), 'media-retention-'));
  try {
    const db = openDatabase(join(tempRoot, 'content.db'), MIGRATIONS_DIR);
    const jobs = new JobStore(db);
    const mediaStore = new ContentMediaStore(db);
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
    const keys = new KeyLayout(config.r2);
    const objects = new InMemoryObjectStore();
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
    const promoting = mediaStore.createPromoting({
      ownerScope: 'selfhost',
      contentType: 'video',
      contentKey,
      renditionKey: 'mp4-720-avc1-aac',
      fingerprint: 'ee'.repeat(32)
    });
    const objectKey = keys.videoMedia('ee'.repeat(32));
    await objects.put(objectKey, Buffer.alloc(128), 'video/mp4');
    const now = Date.now();
    mediaStore.markReady({
      mediaId: promoting.mediaId,
      objectKey,
      mimeType: 'video/mp4',
      bytes: 128,
      sha256: 'ee'.repeat(32),
      durationSeconds: 5,
      height: 720,
      videoCodec: 'avc1',
      audioCodec: 'aac',
      retainUntil: now - 1_000,
      now
    });

    const worker = new MediaRetentionWorker({
      mediaStore,
      objects,
      keys,
      logger: new RedactingLogger(() => {}),
      intervalMs: 60_000,
      batchSize: 50,
      now: () => now
    });

    // Active (queued) job protects the object even though retain_until has passed.
    assert.equal(await worker.runOnce(), 0);
    assert.ok(await objects.head(objectKey));

    jobs.cancelJob(created.job.jobId);
    const first = await worker.runOnce();
    assert.ok(first >= 1);
    assert.equal(await objects.head(objectKey), null);
    assert.equal(await worker.runOnce(), 0);
    worker.stop();
    jobs.close();
  } finally {
    await rm(tempRoot, { recursive: true, force: true });
  }
});
