import assert from 'node:assert/strict';
import {
  mkdtemp,
  readFile,
  rm,
  stat,
  writeFile
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';

import type { ServiceConfig } from '../src/config.js';
import { JobStore } from '../src/jobs/job-store.js';

function testConfig(mediaRoot: string, overrides: Partial<ServiceConfig> = {}): ServiceConfig {
  return {
    host: '127.0.0.1',
    port: 3210,
    publicBaseUrl: 'http://127.0.0.1:3210',
    bearerToken: 'test-token',
    mediaRoot,
    jobTtlMs: 60_000,
    preferredHeight: 720,
    ffmpegPath: 'ffmpeg',
    ffprobePath: 'ffprobe',
    downloadEngine: 'ytdlp',
    ytDlpBin: 'yt-dlp',
    potBaseUrl: null,
    jsRuntime: 'node',
    maxConcurrentJobs: 1,
    minFreeBytes: 1024,
    requireMediaAuth: false,
    r2: null,
    ...overrides
  };
}

describe('JobStore', () => {
  let mediaRoot = '';
  let store: JobStore;

  before(async () => {
    mediaRoot = await mkdtemp(path.join(tmpdir(), 'yt-job-store-'));
    store = new JobStore(testConfig(mediaRoot));
  });

  after(async () => {
    await rm(mediaRoot, { recursive: true, force: true });
  });

  it('dedupes active jobs with the same parameters', async () => {
    const first = await store.create('jNQXAC9IVRw', 'mp4', 1080);
    const second = await store.create('jNQXAC9IVRw', 'mp4', 1080);
    assert.equal(first.jobId, second.jobId);
  });

  it('dedupes concurrent creates before the work directory exists', async () => {
    const jobs = await Promise.all(
      Array.from({ length: 20 }, () =>
        store.create('aqz-KE-bpKQ', 'mp4', 1080)
      )
    );
    assert.equal(new Set(jobs.map((job) => job.jobId)).size, 1);
  });

  it('allows a new job after failure', async () => {
    const job = await store.create('dQw4w9WgXcQ', 'mp4', 720);
    store.fail(job.jobId, 'SABR_REQUEST_FAILED', 'boom');
    const next = await store.create('dQw4w9WgXcQ', 'mp4', 720);
    assert.notEqual(next.jobId, job.jobId);
  });

  it('preserves the last confirmed progress when a download fails', async () => {
    const job = await store.create('QN9IaiOoxY8', 'mp4', 1080);
    store.markStatus(job.jobId, 'fetching', 0.42);
    store.fail(job.jobId, 'MEDIA_DOWNLOAD_FAILED', 'socket closed');

    assert.equal(store.get(job.jobId)?.status, 'failed');
    assert.equal(store.get(job.jobId)?.progress, 0.42);
  });

  it('restores an interrupted job after service restart and requeues it', async () => {
    const job = await store.create('BaW_jenozKc', 'mp4', 1080);
    store.markStatus(job.jobId, 'fetching', 0.37);
    await store.flushPersistence();

    const restoredStore = new JobStore(testConfig(mediaRoot, { preferredHeight: 1080 }));
    const resumable = await restoredStore.restore();

    assert.equal(restoredStore.get(job.jobId)?.status, 'queued');
    assert.equal(restoredStore.get(job.jobId)?.progress, 0.37);
    assert.equal(
      resumable.some((item) => item.jobId === job.jobId),
      true
    );
  });

  it('requeues an HLS job that was playable but not fully downloaded', async () => {
    const job = await store.create('M7lc1UVf-VE', 'hls', 720);
    store.ready(
      job.jobId,
      {
        kind: 'hls',
        url: 'http://127.0.0.1/media/master.m3u8',
        height: 720,
        videoCodec: 'h264',
        audioCodec: 'aac',
        durationSeconds: 100,
        itagVideo: 136,
        itagAudio: 140
      },
      0.55
    );
    await store.flushPersistence();

    const restoredStore = new JobStore(testConfig(mediaRoot, { preferredHeight: 1080 }));
    const resumable = await restoredStore.restore();

    assert.equal(restoredStore.get(job.jobId)?.status, 'queued');
    assert.equal(
      resumable.some((item) => item.jobId === job.jobId),
      true
    );
  });

  it('removes an expired interrupted job instead of restoring a zombie', async () => {
    const job = await store.create('aircAruvnKk', 'mp4', 1080);
    store.markStatus(job.jobId, 'fetching', 0.25);
    await store.flushPersistence();
    const metadataPath = path.join(job.workDir, 'job.json');
    const metadata = JSON.parse(await readFile(metadataPath, 'utf8'));
    metadata.expiresAt = 0;
    await writeFile(metadataPath, JSON.stringify(metadata));

    const restoredStore = new JobStore(testConfig(mediaRoot, { preferredHeight: 1080 }));
    const resumable = await restoredStore.restore();

    assert.equal(restoredStore.get(job.jobId), undefined);
    assert.equal(
      resumable.some((item) => item.jobId === job.jobId),
      false
    );
    await assert.rejects(() => stat(job.workDir));
  });
});
