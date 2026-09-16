import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { ArtifactWriter } from '../../../src/artifacts/writer.js';
import { issueConfirmationToken } from '../../../src/content/v2/confirmation.js';
import {
  containsTranslationLeak,
  decodeAndStripSourceOnly,
  encodeSourceOnlyJson
} from '../../../src/content/v2/source-only.js';
import { contentKeyFor, TranscriptJobs, type TranscriptSource } from '../../../src/content/v2/transcript-jobs.js';
import { HttpV10ContentClient, type V10ContentClient, type V10Job } from '../../../src/content/v10-client.js';
import { videoContentKey } from '../../../src/content/content-key.js';
import { openDatabase } from '../../../src/db/migrations.js';
import { V2Store } from '../../../src/db/v2/store.js';
import { DomainError } from '../../../src/domain/types.js';
import { resolveTranscriptSource } from '../../../src/api/v2/sources.js';
import { newSourceId } from '../../../src/research-v2/state.js';
import { WorkspaceManager } from '../../../src/workspace/manager.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const MIGRATIONS = join(HERE, '../../../migrations');
const SEGMENTS = readFileSync(join(HERE, '../../../fixtures/transcripts/learning-segments-bilingual.json'));
const SHA = createHash('sha256').update(SEGMENTS).digest('hex');

function readyJob(jobId: string): V10Job {
  return {
    jobId,
    status: 'ready',
    stage: 'ready',
    progress: 1,
    artifacts: {
      files: [{ name: 'segments.json', role: 'segments', status: 'ready', bytes: SEGMENTS.length, sha256: SHA }]
    }
  };
}

function harness() {
  const dir = mkdtempSync(join(tmpdir(), 'transcript-v15-'));
  const db = openDatabase(join(dir, 'a.db'), MIGRATIONS);
  const store = new V2Store(db);
  const workspaceRoot = join(dir, 'workspaces');
  mkdirSync(workspaceRoot);
  const manager = new WorkspaceManager({
    root: workspaceRoot,
    store,
    diskFreeBytes: () => 8 * 1024 * 1024 * 1024
  });
  const create = (title: string) =>
    manager.create({
      ownerScope: 'selfhost',
      title,
      outputLanguage: 'zh-Hans',
      storefront: 'US',
      targetLanguage: 'zh-Hans',
      translationQuality: 'quality'
    });
  const a = create('transcript-a');
  const b = create('transcript-b');
  const writerA = new ArtifactWriter(store, a.researchId, manager.internalPath(a.researchId));
  const writerB = new ArtifactWriter(store, b.researchId, manager.internalPath(b.researchId));
  const writers = new Map([
    [a.researchId, writerA],
    [b.researchId, writerB]
  ]);
  return {
    dir,
    store,
    a,
    b,
    writerA,
    writerB,
    manager,
    writers,
    close: () => store.close()
  };
}

function youtubeSource(overrides: Partial<TranscriptSource> = {}): TranscriptSource {
  const sourceId = overrides.sourceId ?? newSourceId();
  return {
    sourceId,
    platform: 'youtube',
    nativeSourceId: 'dQw4w9WgXcQ',
    canonicalURL: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    title: 'Slow English News',
    ...overrides
  };
}

function saveYoutubeHit(writer: ArtifactWriter, source: TranscriptSource): void {
  writer.save({
    kind: 'youtube_search',
    producer: 'search_youtube',
    evidenceLevel: 'search_metadata',
    contents: `${JSON.stringify({
      schemaVersion: 1,
      platform: 'youtube',
      query: 'library',
      results: [
        {
          sourceId: source.nativeSourceId,
          title: source.title,
          canonicalURL: source.canonicalURL,
          provider: 'ytdlp',
          publishedAt: null
        }
      ]
    })}\n`
  });
}

function savePodcastHit(writer: ArtifactWriter, source: TranscriptSource): void {
  writer.save({
    kind: 'podcast_search',
    producer: 'search_podcasts',
    evidenceLevel: 'search_metadata',
    contents: `${JSON.stringify({
      schemaVersion: 1,
      platform: 'podcast',
      query: 'library',
      results: [
        {
          sourceId: source.nativeSourceId,
          assistantSourceId: source.sourceId,
          nativeSourceId: source.nativeSourceId,
          title: source.title,
          canonicalURL: source.canonicalURL,
          provider: 'apple_search',
          publishedAt: null,
          sourceType: source.enclosureUrl ? 'podcast_episode' : 'podcast_show',
          feedURL: source.feedURL ?? null,
          enclosureUrl: source.enclosureUrl ?? null
        }
      ]
    })}\n`
  });
}

function jobsFor(
  ctx: ReturnType<typeof harness>,
  v10: V10ContentClient
): TranscriptJobs {
  return new TranscriptJobs({
    store: ctx.store,
    v10,
    writerFor: (id) => ctx.writers.get(id) ?? null,
    sleep: async () => undefined
  });
}

test('source-only decode drops translation and target fields', () => {
  const raw = JSON.parse(SEGMENTS.toString('utf8'));
  assert.equal(containsTranslationLeak(raw), true);
  const segments = decodeAndStripSourceOnly(raw);
  const encoded = JSON.parse(encodeSourceOnlyJson({
    schemaVersion: 1,
    contentKey: 'video:youtube:dQw4w9WgXcQ',
    v10JobId: 'job_ready',
    v10ArtifactSha256: SHA,
    sourceLanguage: 'en',
    source: { platform: 'youtube', sourceId: 'dQw4w9WgXcQ', canonicalURL: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' },
    segments
  }));
  assert.equal(containsTranslationLeak(encoded), false);
  assert.equal(encoded.segments[0]?.text, 'Welcome back to Slow English News.');
  assert.equal(encoded.segments[0]?.speaker, 'S1');
  assert.equal(encoded.segments[0]?.words[0]?.text, 'Welcome');
});

test('unconfirmed and forged tokens never call V10', async () => {
  const ctx = harness();
  const source = youtubeSource();
  saveYoutubeHit(ctx.writerA, source);
  let lookups = 0;
  let creates = 0;
  const v10: V10ContentClient = {
    async lookup() {
      lookups += 1;
      return readyJob('job_ready');
    },
    async create() {
      creates += 1;
      return readyJob('job_created');
    },
    async get() {
      return readyJob('job_ready');
    },
    async downloadSegments() {
      return { body: SEGMENTS, sha256: SHA };
    }
  };
  const jobs = jobsFor(ctx, v10);
  await assert.rejects(
    () =>
      jobs.request({
        researchId: ctx.a.researchId,
        sourceId: source.sourceId,
        confirmationToken: 'ct_forged',
        confirmed: true,
        targetLanguage: 'zh-Hans',
        translationQuality: 'quality',
        source
      }),
    (error: unknown) => error instanceof DomainError && error.code === 'TRANSCRIPT_CONFIRMATION_REQUIRED'
  );
  const forged = issueConfirmationToken();
  jobs.issue({ researchId: ctx.a.researchId, sourceId: source.sourceId, source });
  await assert.rejects(
    () =>
      jobs.request({
        researchId: ctx.a.researchId,
        sourceId: source.sourceId,
        confirmationToken: forged.token,
        confirmed: true,
        targetLanguage: 'zh-Hans',
        translationQuality: 'quality',
        source
      }),
    (error: unknown) => error instanceof DomainError && error.code === 'TRANSCRIPT_CONFIRMATION_REQUIRED'
  );
  assert.equal(lookups, 0);
  assert.equal(creates, 0);
  ctx.close();
});

test('lookup-ready reuses V10, installs source-only artifacts, and skips rewrite on same hash', async () => {
  const ctx = harness();
  const source = youtubeSource();
  saveYoutubeHit(ctx.writerA, source);
  let creates = 0;
  let downloads = 0;
  const v10: V10ContentClient = {
    async lookup() {
      return readyJob('job_ready');
    },
    async create() {
      creates += 1;
      throw new Error('create must not run when lookup is ready');
    },
    async get() {
      return readyJob('job_ready');
    },
    async downloadSegments() {
      downloads += 1;
      return { body: SEGMENTS, sha256: SHA };
    }
  };
  const jobs = jobsFor(ctx, v10);
  const issued = jobs.issue({ researchId: ctx.a.researchId, sourceId: source.sourceId, source });
  const first = await jobs.request({
    researchId: ctx.a.researchId,
    sourceId: source.sourceId,
    confirmationToken: issued.token,
    confirmed: true,
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    source
  });
  assert.equal(first.status, 'ready');
  assert.equal(first.v10JobId, 'job_ready');
  assert.equal(first.contentKey, videoContentKey('youtube', 'dQw4w9WgXcQ'));
  assert.equal(creates, 0);
  const json = ctx.writerA.get(first.artifactId!);
  assert.equal(json.kind, 'transcript');
  assert.equal(json.evidenceLevel, 'transcript');
  assert.equal(json.mediaType, 'application/json');
  assert.match(json.text, /Welcome back to Slow English News/);
  assert.equal(json.text.includes('欢迎'), false);
  assert.equal(json.text.includes('translation'), false);
  const passages = ctx.store.listPassagesForArtifact(ctx.a.researchId, first.artifactId!);
  assert.equal(passages[0]?.passageId.endsWith(':p-0001') || passages[0]?.passageId === 'p-0001', true);
  assert.equal(passages[0]?.startMs, 0);
  const markdown = ctx.store
    .listArtifacts(ctx.a.researchId, 'transcript', 'ready')
    .find((item) => item.relativePath.endsWith('transcript.md'));
  assert.ok(markdown);
  assert.match(ctx.writerA.get(markdown.artifactId).text, /### p-0001/);
  const reissued = jobs.issue({ researchId: ctx.a.researchId, sourceId: source.sourceId, source });
  const second = await jobs.request({
    researchId: ctx.a.researchId,
    sourceId: source.sourceId,
    confirmationToken: reissued.token,
    confirmed: true,
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    source
  });
  assert.equal(second.artifactId, first.artifactId);
  assert.equal(downloads, 1);
  ctx.close();
});

test('create uses a stable idempotency key and resume keeps the same V10 job id', async () => {
  const ctx = harness();
  const source = youtubeSource();
  saveYoutubeHit(ctx.writerA, source);
  const keys: string[] = [];
  let gets = 0;
  const v10: V10ContentClient = {
    async lookup() {
      return null;
    },
    async create(input) {
      keys.push(input.idempotencyKey);
      return {
        jobId: 'job_created',
        status: 'queued',
        progress: 0.2,
        retryAfterSeconds: 0,
        artifacts: { files: [] }
      };
    },
    async get() {
      gets += 1;
      if (gets === 1) {
        return { jobId: 'job_created', status: 'running', progress: 0.6, retryAfterSeconds: 0, artifacts: { files: [] } };
      }
      return readyJob('job_created');
    },
    async downloadSegments() {
      return { body: SEGMENTS, sha256: SHA };
    }
  };
  const jobs = jobsFor(ctx, v10);
  const issued = jobs.issue({ researchId: ctx.a.researchId, sourceId: source.sourceId, source });
  const done = await jobs.request({
    researchId: ctx.a.researchId,
    sourceId: source.sourceId,
    confirmationToken: issued.token,
    confirmed: true,
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    source
  });
  assert.equal(done.v10JobId, 'job_created');
  assert.equal(keys.length, 1);
  assert.equal(keys[0], `assistant:${contentKeyFor(source)}:zh-Hans:quality`);
  await jobs.reconcile(() => source);
  const resumed = await jobs.resume(ctx.a.researchId, done.transcriptJobId, source);
  assert.equal(resumed.v10JobId, 'job_created');
  assert.equal(resumed.status, 'ready');
  ctx.close();
});

test('two researches install independent snapshots while reusing one V10 job', async () => {
  const ctx = harness();
  const sourceA = youtubeSource();
  const sourceB = youtubeSource({ nativeSourceId: sourceA.nativeSourceId, canonicalURL: sourceA.canonicalURL, title: sourceA.title });
  saveYoutubeHit(ctx.writerA, sourceA);
  saveYoutubeHit(ctx.writerB, sourceB);
  let creates = 0;
  const v10: V10ContentClient = {
    async lookup() {
      return readyJob('job_shared');
    },
    async create() {
      creates += 1;
      return readyJob('job_shared');
    },
    async get() {
      return readyJob('job_shared');
    },
    async downloadSegments() {
      return { body: SEGMENTS, sha256: SHA };
    }
  };
  const jobs = jobsFor(ctx, v10);
  const issuedA = jobs.issue({ researchId: ctx.a.researchId, sourceId: sourceA.sourceId, source: sourceA });
  const issuedB = jobs.issue({ researchId: ctx.b.researchId, sourceId: sourceB.sourceId, source: sourceB });
  const a = await jobs.request({
    researchId: ctx.a.researchId,
    sourceId: sourceA.sourceId,
    confirmationToken: issuedA.token,
    confirmed: true,
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    source: sourceA
  });
  const b = await jobs.request({
    researchId: ctx.b.researchId,
    sourceId: sourceB.sourceId,
    confirmationToken: issuedB.token,
    confirmed: true,
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    source: sourceB
  });
  assert.equal(creates, 0);
  assert.equal(a.v10JobId, 'job_shared');
  assert.equal(b.v10JobId, 'job_shared');
  assert.notEqual(a.artifactId, b.artifactId);
  ctx.manager.delete(ctx.a.researchId);
  assert.equal(creates, 0);
  ctx.close();
});

test('integrity failure does not publish a ready transcript', async () => {
  const ctx = harness();
  const source = youtubeSource();
  saveYoutubeHit(ctx.writerA, source);
  const v10: V10ContentClient = {
    async lookup() {
      return readyJob('job_bad');
    },
    async create() {
      return readyJob('job_bad');
    },
    async get() {
      return readyJob('job_bad');
    },
    async downloadSegments() {
      return { body: SEGMENTS, sha256: 'ab'.repeat(32) };
    }
  };
  const jobs = jobsFor(ctx, v10);
  const issued = jobs.issue({ researchId: ctx.a.researchId, sourceId: source.sourceId, source });
  await assert.rejects(
    () =>
      jobs.request({
        researchId: ctx.a.researchId,
        sourceId: source.sourceId,
        confirmationToken: issued.token,
        confirmed: true,
        targetLanguage: 'zh-Hans',
        translationQuality: 'quality',
        source
      }),
    (error: unknown) => error instanceof DomainError && error.code === 'ARTIFACT_INTEGRITY_FAILED'
  );
  const stored = ctx.store.findTranscriptJobBySource(ctx.a.researchId, source.sourceId, contentKeyFor(source));
  assert.equal(stored?.status, 'failed_terminal');
  assert.equal(ctx.store.listArtifacts(ctx.a.researchId, 'transcript', 'ready').length, 0);
  ctx.close();
});

test('sources missing from this research cannot start transcription', async () => {
  const ctx = harness();
  const source = youtubeSource();
  const v10: V10ContentClient = {
    async lookup() {
      throw new Error('lookup must not run');
    },
    async create() {
      throw new Error('create must not run');
    },
    async get() {
      throw new Error('get must not run');
    },
    async downloadSegments() {
      throw new Error('download must not run');
    }
  };
  const jobs = jobsFor(ctx, v10);
  assert.throws(
    () => jobs.issue({ researchId: ctx.a.researchId, sourceId: source.sourceId, source }),
    (error: unknown) => error instanceof DomainError && error.code === 'SOURCE_NOT_FOUND'
  );
  const show: TranscriptSource = {
    sourceId: newSourceId(),
    platform: 'podcast',
    nativeSourceId: 'show-1',
    canonicalURL: 'https://example.test/show',
    title: 'Show',
    feedURL: 'https://example.test/feed.xml',
    enclosureUrl: null
  };
  assert.throws(
    () => jobs.issue({ researchId: ctx.a.researchId, sourceId: show.sourceId, source: show }),
    (error: unknown) => error instanceof DomainError && error.code === 'TRANSCRIPT_SOURCE_NOT_ELIGIBLE'
  );
  ctx.close();
});

test('podcast episodes with feed and enclosure can enter V10; shows cannot', () => {
  const ctx = harness();
  const episode: TranscriptSource = {
    sourceId: newSourceId(),
    platform: 'podcast',
    nativeSourceId: 'ep-1',
    canonicalURL: 'https://podcasts.apple.com/episode/id9',
    title: 'Episode 9',
    feedURL: 'https://feeds.example.test/show.xml',
    enclosureUrl: 'https://cdn.example.test/9.mp3'
  };
  savePodcastHit(ctx.writerA, episode);
  const resolved = resolveTranscriptSource(ctx.store, ctx.writerA, ctx.a.researchId, episode.sourceId);
  assert.equal(resolved.feedURL, episode.feedURL);
  assert.equal(resolved.enclosureUrl, episode.enclosureUrl);
  const jobs = jobsFor(ctx, {
    async lookup() {
      throw new Error('lookup must not run during issue');
    },
    async create() {
      throw new Error('create must not run during issue');
    },
    async get() {
      throw new Error('get must not run during issue');
    },
    async downloadSegments() {
      throw new Error('download must not run during issue');
    }
  });
  const issued = jobs.issue({ researchId: ctx.a.researchId, sourceId: episode.sourceId, source: resolved });
  assert.equal(issued.job.sourceId, episode.sourceId);

  const show: TranscriptSource = {
    sourceId: newSourceId(),
    platform: 'podcast',
    nativeSourceId: 'show-1',
    canonicalURL: 'https://podcasts.apple.com/show/id1',
    title: 'Show',
    feedURL: 'https://feeds.example.test/show.xml',
    enclosureUrl: null
  };
  savePodcastHit(ctx.writerA, show);
  const resolvedShow = resolveTranscriptSource(ctx.store, ctx.writerA, ctx.a.researchId, show.sourceId);
  assert.equal(resolvedShow.enclosureUrl, null);
  assert.throws(
    () => jobs.issue({ researchId: ctx.a.researchId, sourceId: show.sourceId, source: resolvedShow }),
    (error: unknown) => error instanceof DomainError && error.code === 'TRANSCRIPT_SOURCE_NOT_ELIGIBLE'
  );
  ctx.close();
});

test('invalid segments schema does not publish a ready transcript', async () => {
  const ctx = harness();
  const source = youtubeSource();
  saveYoutubeHit(ctx.writerA, source);
  const body = Buffer.from(JSON.stringify({ schemaVersion: 2, segments: [{ sequence: 1 }] }));
  const sha = createHash('sha256').update(body).digest('hex');
  const job: V10Job = {
    jobId: 'job_schema',
    status: 'ready',
    stage: 'ready',
    progress: 1,
    artifacts: {
      files: [{ name: 'segments.json', role: 'segments', status: 'ready', bytes: body.length, sha256: sha }]
    }
  };
  const v10: V10ContentClient = {
    async lookup() {
      return job;
    },
    async create() {
      return job;
    },
    async get() {
      return job;
    },
    async downloadSegments() {
      return { body, sha256: sha };
    }
  };
  const jobs = jobsFor(ctx, v10);
  const issued = jobs.issue({ researchId: ctx.a.researchId, sourceId: source.sourceId, source });
  await assert.rejects(
    () =>
      jobs.request({
        researchId: ctx.a.researchId,
        sourceId: source.sourceId,
        confirmationToken: issued.token,
        confirmed: true,
        targetLanguage: 'zh-Hans',
        translationQuality: 'quality',
        source
      }),
    (error: unknown) => error instanceof DomainError && error.code === 'ARTIFACT_INVALID'
  );
  assert.equal(ctx.store.listArtifacts(ctx.a.researchId, 'transcript', 'ready').length, 0);
  ctx.close();
});

test('poll budget exhaustion preserves running state and a restarted worker installs the same job', async () => {
  const ctx = harness();
  const source = youtubeSource();
  saveYoutubeHit(ctx.writerA, source);
  const running: V10Job = {
    jobId: 'job_hang',
    status: 'running',
    stage: 'asr',
    progress: 0.1,
    artifacts: { files: [] }
  };
  let complete = false;
  let unavailable = false;
  let creates = 0;
  const v10: V10ContentClient = {
    async lookup() {
      return running;
    },
    async create() {
      creates += 1;
      return running;
    },
    async get() {
      if (unavailable) throw new Error('network down');
      return complete ? readyJob('job_hang') : running;
    },
    async downloadSegments() {
      return { body: SEGMENTS, sha256: SHA };
    }
  };
  const jobs = new TranscriptJobs({
    store: ctx.store,
    v10,
    writerFor: (id) => ctx.writers.get(id) ?? null,
    sleep: async () => undefined,
    maxPollMs: 0
  });
  const issued = jobs.issue({ researchId: ctx.a.researchId, sourceId: source.sourceId, source });
  const pending = await jobs.request({
    researchId: ctx.a.researchId, sourceId: source.sourceId,
    confirmationToken: issued.token, confirmed: true,
    targetLanguage: 'zh-Hans', translationQuality: 'quality', source
  });
  assert.equal(pending.status, 'running');
  assert.equal(pending.error, null);
  const stored = ctx.store.findTranscriptJobBySource(ctx.a.researchId, source.sourceId, contentKeyFor(source));
  assert.equal(stored?.status, 'running');
  assert.equal(ctx.store.listArtifacts(ctx.a.researchId, 'transcript', 'ready').length, 0);
  const restarted = new TranscriptJobs({ store: ctx.store, v10, writerFor: (id) => ctx.writers.get(id) ?? null });
  unavailable = true;
  await restarted.reconcile(() => source);
  assert.equal(restarted.get(ctx.a.researchId, issued.job.transcriptJobId).status, 'running');
  assert.equal(restarted.get(ctx.a.researchId, issued.job.transcriptJobId).installStatus, 'retrying');
  unavailable = false;
  complete = true;
  await restarted.reconcile(() => source);
  const installed = restarted.get(ctx.a.researchId, issued.job.transcriptJobId);
  assert.equal(installed.status, 'ready');
  assert.equal(installed.v10JobId, 'job_hang');
  assert.equal(creates, 0);
  ctx.close();
});

test('concurrent requests share one create and recovery preserves confirmed settings', async () => {
  const ctx = harness();
  const source = youtubeSource();
  saveYoutubeHit(ctx.writerA, source);
  let creates = 0;
  let failLookup = true;
  const v10: V10ContentClient = {
    async lookup() {
      if (failLookup) throw new Error('offline');
      return null;
    },
    async create(input) {
      creates += 1;
      assert.equal(input.targetLanguage, 'ja');
      assert.equal(input.translationQuality, 'fast');
      return { jobId: 'job_recovery', status: 'running', progress: 0.2 };
    },
    async get() { return readyJob('job_recovery'); },
    async downloadSegments() { return { body: SEGMENTS, sha256: SHA }; }
  };
  const jobs = jobsFor(ctx, v10);
  const issued = jobs.issue({ researchId: ctx.a.researchId, sourceId: source.sourceId, source });
  const input = { researchId: ctx.a.researchId, sourceId: source.sourceId, source,
    confirmationToken: issued.token, confirmed: true as const, targetLanguage: 'ja', translationQuality: 'fast' as const };
  const pending = await jobs.request(input);
  assert.equal(pending.status, 'waiting_service');
  failLookup = false;
  const restarted = jobsFor(ctx, v10);
  await Promise.all([restarted.reconcile(() => source), restarted.request(input)]);
  assert.equal(creates, 1);
  await restarted.reconcile(() => source);
  assert.equal(restarted.get(ctx.a.researchId, issued.job.transcriptJobId).status, 'ready');
  ctx.close();
});

test('legacy timed-out jobs resume by ID, but unconfirmed and backend-failed jobs do not restart', async () => {
  const ctx = harness();
  const source = youtubeSource();
  saveYoutubeHit(ctx.writerA, source);
  let gets = 0;
  const v10: V10ContentClient = {
    async lookup() { throw new Error('must reuse old ID'); },
    async create() { throw new Error('must not create'); },
    async get(id) { gets += 1; return readyJob(id); },
    async downloadSegments() { return { body: SEGMENTS, sha256: SHA }; }
  };
  const jobs = jobsFor(ctx, v10);
  const issued = jobs.issue({ researchId: ctx.a.researchId, sourceId: source.sourceId, source });
  await jobs.reconcile(() => source);
  assert.equal(gets, 0);
  ctx.store.patchTranscriptJob(issued.job.transcriptJobId, {
    v10JobId: 'old_job', error: { code: 'V10_UNAVAILABLE', message: 'V10 poll timed out', retryable: true }
  });
  ctx.store.setTranscriptJobStatus(issued.job.transcriptJobId, 'requested', 'waiting_service');
  ctx.store.setTranscriptJobStatus(issued.job.transcriptJobId, 'waiting_service', 'failed_retryable');
  ctx.store.patchTranscriptJob(issued.job.transcriptJobId, { error: { code: 'ASR_FAILED', message: 'provider rejected media', retryable: true } });
  await jobs.reconcile(() => source);
  assert.equal(gets, 0);
  ctx.store.patchTranscriptJob(issued.job.transcriptJobId, { error: { code: 'V10_UNAVAILABLE', message: 'V10 poll timed out', retryable: true } });
  await jobs.reconcile(() => source);
  assert.equal(gets, 1);
  assert.equal(jobs.get(ctx.a.researchId, issued.job.transcriptJobId).status, 'ready');
  ctx.close();
});

 test('HTTP 422 duration rejection is terminal and preserves the service error', async () => {
  const ctx = harness();
  try {
    const source = youtubeSource();
    saveYoutubeHit(ctx.writerA, source);
    const client = new HttpV10ContentClient('https://content.example', 'test-token', async (_url, init) =>
      init?.method === 'POST'
        ? new Response(JSON.stringify({ error: { code: 'MEDIA_DURATION_UNKNOWN', message: 'media duration could not be determined', retryable: false } }), { status: 422 })
        : new Response(JSON.stringify({ job: null }), { status: 200 }));
    const jobs = jobsFor(ctx, client);
    const issued = jobs.issue({ researchId: ctx.a.researchId, sourceId: source.sourceId, source });
    await assert.rejects(jobs.request({ researchId: ctx.a.researchId, sourceId: source.sourceId,
      confirmationToken: issued.token, confirmed: true, targetLanguage: 'zh-Hans', translationQuality: 'quality', source }),
      (error: unknown) => error instanceof DomainError && error.code === 'MEDIA_DURATION_UNKNOWN' && !error.retryable && error.message === 'media duration could not be determined');
    assert.equal(ctx.store.recoverableTranscriptJobs().length, 0);
  } finally { ctx.close(); }
});
