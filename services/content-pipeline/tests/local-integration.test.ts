/**
 * WP15 Step 1 — local integration verification. Boots the real content
 * service (HTTP API + worker + real provider clients) against loopback fakes
 * and drives complete podcast/video job flows plus the WP15 fault-injection
 * matrix: ASR poll failure, translation batch failure, process kill, object
 * storage publish failure and signed-URL expiry. No external network access.
 */

import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { promisify } from 'node:util';

import { podcastContentKey, videoContentKey } from '../src/domain/content-key.js';
import { RedactingLogger } from '../src/observability/logger.js';

import { LocalStack, SERVICE_TOKEN, type JobSnapshot } from './support/local-stack.js';

const execFileAsync = promisify(execFile);
const TEST_TIMEOUT = { timeout: 120_000 };

let fixtureDir = '';
let audioBytes: Buffer;

before(async () => {
  fixtureDir = await mkdtemp(join(tmpdir(), 'wp15-fixture-'));
  const mp3Path = join(fixtureDir, 'episode.mp3');
  await execFileAsync('ffmpeg', [
    '-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=3',
    '-codec:a', 'libmp3lame', '-q:a', '6',
    mp3Path
  ]);
  audioBytes = await readFile(mp3Path);
});

after(async () => {
  await rm(fixtureDir, { recursive: true, force: true });
});

function podcastJobBody(stack: LocalStack, episodeId: string) {
  const feedUrl = 'https://feeds.example.com/show.xml';
  return {
    contentType: 'podcast_episode',
    contentKey: podcastContentKey(feedUrl, episodeId),
    source: {
      platform: 'rss',
      sourceId: episodeId,
      url: stack.fakes.podcast.episodeUrl,
      feedUrl,
      title: `Episode ${episodeId}`
    },
    sourceLanguage: 'en',
    targetLanguage: 'zh-Hans',
    translationQuality: 'fast',
    clientArtifactSchemaVersion: 1
  };
}

function videoJobBody(videoId: string) {
  return {
    contentType: 'video',
    contentKey: videoContentKey('youtube', videoId),
    source: {
      platform: 'youtube',
      sourceId: videoId,
      url: `https://www.youtube.com/watch?v=${videoId}`
    },
    sourceLanguage: 'en',
    targetLanguage: 'zh-Hans',
    translationQuality: 'fast',
    clientArtifactSchemaVersion: 1
  };
}

async function submitJob(stack: LocalStack, body: unknown): Promise<string> {
  const { status, json } = await stack.api('POST', '/v1/content-jobs', body);
  assert.ok(status === 202 || status === 200, `submit failed: HTTP ${status} ${JSON.stringify(json)}`);
  return json.jobId as string;
}

async function fetchArtifact(stack: LocalStack, jobId: string, name: string): Promise<Buffer> {
  const res = await fetch(`${stack.baseUrl}/v1/content-artifacts/${jobId}/${name}`, {
    headers: { authorization: `Bearer ${SERVICE_TOKEN}` }
  });
  assert.equal(res.status, 200, `artifact ${name}: HTTP ${res.status}`);
  return Buffer.from(await res.arrayBuffer());
}

async function requestPlaybackUrl(
  stack: LocalStack,
  jobId: string
): Promise<{ url: string; expiresAt: string; bytes: number; sha256: string }> {
  const { status, json } = await stack.api('POST', `/v1/content-jobs/${jobId}/audio-playback-url`);
  assert.equal(status, 200, `playback url: HTTP ${status} ${JSON.stringify(json)}`);
  return json as { url: string; expiresAt: string; bytes: number; sha256: string };
}

// --- 1. Podcast happy path over the real HTTP API --------------------------

test('podcast: full pipeline via API — ready, artifacts, ranged playback URL', TEST_TIMEOUT, async () => {
  const stack = await LocalStack.start(audioBytes);
  try {
    const jobId = await submitJob(stack, podcastJobBody(stack, 'ep-happy'));
    const { job, history } = await stack.waitForJob(jobId, (j) => j.status === 'ready');

    // audioReady is observable while the job is still running (audio-first).
    assert.ok(
      history.some((h) => h.audioReady && h.status === 'running'),
      `audioReady was never observed mid-run: ${history.map((h) => `${h.status}@${h.stage}`).join(',')}`
    );
    assert.equal(job.progress, 1);
    assert.equal(job.subtitlesReady, true);

    const files = job.artifacts?.files ?? [];
    for (const name of ['segments.json', 'source.vtt', 'target.vtt']) {
      assert.ok(
        files.some((f) => f.name === name && f.status === 'ready'),
        `manifest missing ready ${name}`
      );
    }

    const segments = JSON.parse((await fetchArtifact(stack, jobId, 'segments.json')).toString('utf8'));
    assert.ok(Array.isArray(segments.segments) && segments.segments.length === 2);
    const sourceVtt = (await fetchArtifact(stack, jobId, 'source.vtt')).toString('utf8');
    assert.match(sourceVtt, /Hello world\./);
    const targetVtt = (await fetchArtifact(stack, jobId, 'target.vtt')).toString('utf8');
    assert.match(targetVtt, /译文/);

    const playback = await requestPlaybackUrl(stack, jobId);
    const full = await fetch(playback.url);
    assert.equal(full.status, 200);
    const body = Buffer.from(await full.arrayBuffer());
    assert.equal(body.length, playback.bytes);
    assert.equal(createHash('sha256').update(body).digest('hex'), playback.sha256);

    const ranged = await fetch(playback.url, { headers: { range: 'bytes=0-99' } });
    assert.equal(ranged.status, 206);
    assert.equal((await ranged.arrayBuffer()).byteLength, 100);
  } finally {
    await stack.cleanup();
  }
});

// --- 2. Video happy path through the fake media-api -------------------------

test('video: media-api audio copied, pipeline ready, media job cancelled', TEST_TIMEOUT, async () => {
  const stack = await LocalStack.start(audioBytes);
  try {
    const jobId = await submitJob(stack, videoJobBody('vid-happy'));
    const { job } = await stack.waitForJob(jobId, (j) => j.status === 'ready');

    assert.equal(stack.fakes.media.prepareCount, 1);
    assert.deepEqual(stack.fakes.media.preparedVideoIds, ['vid-happy']);
    // The upstream media job is cancelled once the audio is safely in our
    // storage (45-minute TTL is never trusted as a durable reference).
    assert.equal(stack.fakes.media.cancelCount, 1);
    assert.equal(job.subtitlesReady, true);

    const targetVtt = (await fetchArtifact(stack, jobId, 'target.vtt')).toString('utf8');
    assert.match(targetVtt, /译文/);
  } finally {
    await stack.cleanup();
  }
});

// --- 3. Fault injection: transient ASR poll failures ------------------------

test('fault: ASR poll 500s are retried inside the bounded poll loop', TEST_TIMEOUT, async () => {
  const stack = await LocalStack.start(audioBytes);
  try {
    // Two 500s, then normal service — absorbed by the provider's bounded
    // retry (3 attempts with fixed backoff) without failing the job.
    stack.fakes.dashscope.failPolls = 2;
    const jobId = await submitJob(stack, podcastJobBody(stack, 'ep-asr-flaky'));
    const { job } = await stack.waitForJob(jobId, (j) => j.status === 'ready', 90_000);
    assert.equal(job.status, 'ready');
    assert.equal(stack.fakes.dashscope.submitCount, 1);
  } finally {
    await stack.cleanup();
  }
});

// --- 4. Fault injection: persistent translation batch failure + retry -------

test('fault: translation outage fails retryable; POST retry resumes from checkpoints', TEST_TIMEOUT, async () => {
  const stack = await LocalStack.start(audioBytes);
  try {
    stack.fakes.translation.failAll = true;
    const jobId = await submitJob(stack, podcastJobBody(stack, 'ep-translation-down'));
    const { job: failed } = await stack.waitForJob(jobId, (j) => j.status === 'failed');
    assert.equal(failed.error?.retryable, true, `expected retryable failure, got ${JSON.stringify(failed.error)}`);
    const requestsBeforeRetry = stack.fakes.translation.requestCount;
    assert.ok(requestsBeforeRetry > 0);

    stack.fakes.translation.failAll = false;
    const retry = await stack.api('POST', `/v1/content-jobs/${jobId}/retry`);
    assert.equal(retry.status, 202);
    const { job } = await stack.waitForJob(jobId, (j) => j.status === 'ready');

    // The ASR checkpoint is reused — no duplicate provider task.
    assert.equal(stack.fakes.dashscope.submitCount, 1, 'retry must not resubmit ASR');
    assert.equal(job.status, 'ready');
  } finally {
    await stack.cleanup();
  }
});

// --- 5. Fault injection: process kill mid-ASR, restart resumes --------------

test('fault: process kill mid-ASR — restart resumes the same provider task', TEST_TIMEOUT, async () => {
  const stack = await LocalStack.start(audioBytes, { autoStartWorker: false });
  try {
    stack.fakes.dashscope.holdPending = true;
    const jobId = await submitJob(stack, podcastJobBody(stack, 'ep-crash'));

    // Simulate a process that claimed the job and died mid-stage: claim with
    // a dead-owner lease and run the executor manually, then abort it without
    // failing the job row (a real SIGKILL never reaches failJob either).
    const claimed = stack.store.claimNextJob('dead-worker', 100);
    assert.equal(claimed?.jobId, jobId);
    const abort = new AbortController();
    const run = stack.executor({
      job: claimed!,
      logger: new RedactingLogger(() => {}),
      signal: abort.signal,
      heartbeat: () => {},
      updateProgress: (update) => stack.store.updateProgress(jobId, update),
      recordCheckpoint: (checkpoint) => stack.store.recordCheckpoint(jobId, checkpoint),
      reusableCheckpoints: () => stack.store.reusableCheckpoints(jobId)
    });
    run.catch(() => {}); // the abort rejection is expected

    // Wait until the ASR task is submitted (checkpoint durable), then "kill".
    const deadline = Date.now() + 30_000;
    while (stack.fakes.dashscope.submitCount === 0) {
      if (Date.now() > deadline) throw new Error('ASR task was never submitted');
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    abort.abort();
    await run.catch(() => {});

    const crashed = await stack.getJob(jobId);
    assert.equal(crashed.status, 'running', 'a killed process leaves the job running');

    // New process: worker start reclaims the expired lease and resumes.
    await new Promise((resolve) => setTimeout(resolve, 150)); // let the 100ms lease expire
    stack.startWorker('worker-2');
    stack.fakes.dashscope.holdPending = false;
    const { job } = await stack.waitForJob(jobId, (j) => j.status === 'ready');

    assert.equal(stack.fakes.dashscope.submitCount, 1, 'ASR submit must not be repeated after a crash');
    assert.equal(job.status, 'ready');
  } finally {
    await stack.cleanup();
  }
});

// --- 6. Fault injection: object storage publish failure ---------------------

test('fault: storage publish failure is retryable; retry completes', TEST_TIMEOUT, async () => {
  const stack = await LocalStack.start(audioBytes);
  try {
    stack.fakes.s3.failNextPuts = 1;
    const jobId = await submitJob(stack, podcastJobBody(stack, 'ep-s3-down'));
    const { job: failed } = await stack.waitForJob(jobId, (j) => j.status === 'failed');
    assert.equal(failed.error?.retryable, true, `expected retryable failure, got ${JSON.stringify(failed.error)}`);

    const retry = await stack.api('POST', `/v1/content-jobs/${jobId}/retry`);
    assert.equal(retry.status, 202);
    const { job } = await stack.waitForJob(jobId, (j) => j.status === 'ready');
    assert.equal(job.status, 'ready');
  } finally {
    await stack.cleanup();
  }
});

// --- 7. Fault injection: signed URL expiry ----------------------------------

test('fault: expired signed URL is rejected; a fresh one is issued per request', TEST_TIMEOUT, async () => {
  const stack = await LocalStack.start(audioBytes);
  try {
    const jobId = await submitJob(stack, podcastJobBody(stack, 'ep-url-expiry'));
    await stack.waitForJob(jobId, (j) => j.status === 'ready');

    const first = await requestPlaybackUrl(stack, jobId);
    stack.fakes.s3.clockSkewMs = 120_000; // fake storage clock jumps past expiry
    const expired = await fetch(first.url);
    assert.equal(expired.status, 403, 'expired signed URL must be rejected');
    stack.fakes.s3.clockSkewMs = 0;

    const ok = await fetch(first.url);
    assert.equal(ok.status, 200, 'unexpired URL works again');

    // URLs are re-issued per request, never persisted: a fresh request
    // carries a later expiry than the first one.
    const second = await requestPlaybackUrl(stack, jobId);
    const firstExpires = Number(new URL(first.url).searchParams.get('expires'));
    const secondExpires = Number(new URL(second.url).searchParams.get('expires'));
    assert.ok(secondExpires > firstExpires, 'each request issues a fresh URL');
  } finally {
    await stack.cleanup();
  }
});

// --- 8. Restart recovery of a queued (never-started) job --------------------

test('restart: a job queued while no worker runs is picked up on start', TEST_TIMEOUT, async () => {
  const stack = await LocalStack.start(audioBytes, { autoStartWorker: false });
  try {
    const jobId = await submitJob(stack, podcastJobBody(stack, 'ep-queued'));
    const queued: JobSnapshot = await stack.getJob(jobId);
    assert.equal(queued.status, 'queued');

    stack.startWorker();
    const { job } = await stack.waitForJob(jobId, (j) => j.status === 'ready');
    assert.equal(job.status, 'ready');
  } finally {
    await stack.cleanup();
  }
});
