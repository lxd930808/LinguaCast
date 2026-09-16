import { once } from 'node:events';
import { createApp } from '../src/app.js';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { loadConfig } from '../src/config.js';
import { videoContentKey } from '../src/domain/content-key.js';
import { VideoMediaTaskStore } from '../src/domain/video-media-task-store.js';
import { MediaRetentionWorker } from '../src/storage/media-retention.js';
import { cachedVideo } from '../src/pipeline/video/video-media-promotion.js';
import { ContentMediaStore } from '../src/domain/content-media-store.js';
import { openDatabase } from '../src/jobs/migrations.js';
import { JobStore } from '../src/jobs/job-store.js';
import type { ContainerProbe } from '../src/media/ffprobe.js';
import type { DownloadOptions, DownloadResult } from '../src/media/downloader.js';
import { RedactingLogger } from '../src/observability/logger.js';
import { KeyLayout } from '../src/storage/keys.js';
import { InMemoryObjectStore } from '../src/storage/object-store.js';
import {
  promoteVideoMedia,
  VideoPromotionError,
  type VideoPromotionDeps
} from '../src/pipeline/video/video-media-promotion.js';

const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url).pathname;
const VIDEO_ID = 'abcdefghijk';
const MP4_BYTES = Buffer.from('fake-mp4-bytes-for-promotion-tests');
const MP4_SHA = createHash('sha256').update(MP4_BYTES).digest('hex');

const GOOD_PROBE: ContainerProbe = {
  formatName: 'mov,mp4,m4a,3gp,3g2,mj2',
  durationSeconds: 3,
  videoCodec: 'h264',
  audioCodec: 'aac',
  height: 720,
  width: 1280,
  videoDurationSeconds: 3,
  audioDurationSeconds: 3,
  hasVideo: true,
  hasAudio: true
};

async function setup() {
  const tempRoot = await mkdtemp(join(tmpdir(), 'video-media-test-'));
  const config = loadConfig({
    CONTENT_IDENTITY_MODE: 'selfhost', CONTENT_SERVICE_TOKEN: 'test-service-token-0123456789',
    MEDIA_API_TOKEN: 'test-media-token-0123456789',
    MEDIA_API_BASE_URL: 'http://127.0.0.1:3210',
    DASHSCOPE_API_KEY: 'test-dashscope-key-0123456789',
    TRANSLATION_API_KEY: 'test-translation-key-0123456789',
    TRANSLATION_MODEL: 'test-model',
    R2_ACCOUNT_ID: 'acct',
    R2_ACCESS_KEY_ID: 'r2-access',
    R2_SECRET_ACCESS_KEY: 'r2-secret-0123456789',
    R2_BUCKET: 'linguacast',
    CONTENT_TEMP_ROOT: tempRoot,
    VIDEO_MEDIA_PROMOTION_ENABLED: '1'
  });
  const db = openDatabase(join(tempRoot, 'content.db'), MIGRATIONS_DIR);
  const jobs = new JobStore(db);
  const mediaStore = new ContentMediaStore(db);
  const { job } = jobs.createJob({
    ownerScope: 'selfhost',
    contentType: 'video',
    contentKey: videoContentKey('youtube', VIDEO_ID),
    source: { platform: 'youtube', sourceId: VIDEO_ID, url: `https://youtu.be/${VIDEO_ID}` },
    sourceLanguage: 'en',
    targetLanguage: 'zh-Hans',
    translationQuality: 'fast',
    pipelineVersion: 'v10.1',
    clientArtifactSchemaVersion: 1
  });
  const objects = new InMemoryObjectStore();
  const layout = new KeyLayout(config.r2);
  const logger = new RedactingLogger(() => {});
  return {
    tempRoot,
    config,
    jobs,
    db,
    mediaStore,
    job,
    objects,
    layout,
    logger,
    cleanup: async () => {
      jobs.close();
      await rm(tempRoot, { recursive: true, force: true });
    }
  };
}

function fakeDownload(bytes = MP4_BYTES) {
  return async (url: string, filePath: string, _options: DownloadOptions): Promise<DownloadResult> => {
    await writeFile(filePath, bytes);
    return {
      filePath,
      bytes: bytes.length,
      sha256: createHash('sha256').update(bytes).digest('hex'),
      contentType: 'video/mp4',
      finalUrl: url,
      redirects: 0
    };
  };
}

function deps(fx: Awaited<ReturnType<typeof setup>>, overrides: Partial<VideoPromotionDeps> = {}): VideoPromotionDeps {
  return {
    mediaStore: fx.mediaStore,
    layout: fx.layout,
    objectStore: fx.objects,
    config: fx.config,
    logger: fx.logger,
    download: fakeDownload(),
    probe: async () => GOOD_PROBE,
    ...overrides
  };
}

test('happy path uploads temp, verifies, publishes ready current asset', async () => {
  const fx = await setup();
  try {
    const result = await promoteVideoMedia(
      {
        job: fx.job,
        playbackUrl: 'http://127.0.0.1:3210/media/mj-1/output.mp4',
        localDir: join(fx.tempRoot, fx.job.jobId),
        signal: new AbortController().signal
      },
      deps(fx)
    );
    assert.equal(result.status, 'ready');
    if (result.status !== 'ready') return;
    assert.equal(result.reused, false);
    assert.equal(result.asset.state, 'ready');
    assert.equal(result.asset.isCurrent, true);
    assert.equal(result.asset.sha256, MP4_SHA);
    assert.ok(result.asset.objectKey?.endsWith(`${MP4_SHA}.mp4`));
    assert.ok(!result.asset.objectKey?.includes('yt-media'));
    const head = await fx.objects.head(result.asset.objectKey!);
    assert.equal(head?.bytes, MP4_BYTES.length);
    const temps = (await fx.objects.listKeys(fx.layout.base + '/video-media/.tmp/'));
    assert.equal(temps.length, 0, 'temp object must be deleted after publish');
    assert.ok(result.localMp4Path);
    assert.equal((await readFile(result.localMp4Path!)).length, MP4_BYTES.length);
  } finally {
    await fx.cleanup();
  }
});

test('duplicate promotion reuses the ready fingerprint object', async () => {
  const fx = await setup();
  try {
    const input = {
      job: fx.job,
      playbackUrl: 'http://127.0.0.1:3210/media/mj-1/output.mp4',
      localDir: join(fx.tempRoot, fx.job.jobId),
      signal: new AbortController().signal
    };
    const first = await promoteVideoMedia(input, deps(fx));
    const second = await promoteVideoMedia(input, deps(fx));
    assert.equal(first.status, 'ready');
    assert.equal(second.status, 'ready');
    if (first.status !== 'ready' || second.status !== 'ready') return;
    assert.equal(second.reused, true);
    assert.equal(second.asset.mediaId, first.asset.mediaId);
    const keys = await fx.objects.listKeys(fx.layout.base + '/video-media/');
    assert.equal(keys.filter((k) => k.endsWith('.mp4') && !k.includes('/.tmp/')).length, 1);
  } finally {
    await fx.cleanup();
  }
});

test('HEAD mismatch refuses ready and cleans temp', async () => {
  const fx = await setup();
  try {
    const lying = new InMemoryObjectStore();
    const originalHead = lying.head.bind(lying);
    lying.head = async (key) => {
      const meta = await originalHead(key);
      if (!meta) return null;
      return { ...meta, bytes: meta.bytes + 7 };
    };
    await assert.rejects(
      () =>
        promoteVideoMedia(
          {
            job: fx.job,
            playbackUrl: 'http://127.0.0.1:3210/media/mj-1/output.mp4',
            localDir: join(fx.tempRoot, fx.job.jobId),
            signal: new AbortController().signal
          },
          deps(fx, { objectStore: lying })
        ),
      (error: unknown) => error instanceof VideoPromotionError && error.failureCode === 'MEDIA_INTEGRITY_FAILED'
    );
    const current = fx.mediaStore.currentReadyForContent('selfhost', 'video', fx.job.contentKey);
    assert.equal(current, null);
  } finally {
    await fx.cleanup();
  }
});

test('missing video or audio track is not marked ready', async () => {
  const fx = await setup();
  try {
    await assert.rejects(
      () =>
        promoteVideoMedia(
          {
            job: fx.job,
            playbackUrl: 'http://127.0.0.1:3210/media/mj-1/output.mp4',
            localDir: join(fx.tempRoot, fx.job.jobId),
            signal: new AbortController().signal
          },
          deps(fx, { probe: async () => ({ ...GOOD_PROBE, hasVideo: false, videoCodec: null }) })
        ),
      VideoPromotionError
    );
    await assert.rejects(
      () =>
        promoteVideoMedia(
          {
            job: fx.job,
            playbackUrl: 'http://127.0.0.1:3210/media/mj-1/output.mp4',
            localDir: join(fx.tempRoot, 'job-2'),
            signal: new AbortController().signal
          },
          deps(fx, { probe: async () => ({ ...GOOD_PROBE, hasAudio: false, audioCodec: null }) })
        ),
      VideoPromotionError
    );
    assert.equal(fx.mediaStore.currentReadyForContent('selfhost', 'video', fx.job.contentKey), null);
  } finally {
    await fx.cleanup();
  }
});

test('audio/video duration mismatch beyond threshold is rejected', async () => {
  const fx = await setup();
  try {
    await assert.rejects(
      () =>
        promoteVideoMedia(
          {
            job: fx.job,
            playbackUrl: 'http://127.0.0.1:3210/media/mj-1/output.mp4',
            localDir: join(fx.tempRoot, fx.job.jobId),
            signal: new AbortController().signal
          },
          deps(fx, {
            probe: async () => ({
              ...GOOD_PROBE,
              durationSeconds: 100,
              videoDurationSeconds: 100,
              audioDurationSeconds: 90
            })
          })
        ),
      (error: unknown) => error instanceof VideoPromotionError && error.failureCode === 'UNSUPPORTED_AUDIO'
    );
  } finally {
    await fx.cleanup();
  }
});

test('promotion disabled or over budget skips without creating ready assets', async () => {
  const fx = await setup();
  try {
    const disabled = await promoteVideoMedia(
      {
        job: fx.job,
        playbackUrl: 'http://127.0.0.1:3210/media/mj-1/output.mp4',
        localDir: join(fx.tempRoot, fx.job.jobId),
        signal: new AbortController().signal
      },
      deps(fx, { config: { ...fx.config, videoMediaPromotionEnabled: false } })
    );
    assert.equal(disabled.status, 'skipped');

    const budget = await promoteVideoMedia(
      {
        job: fx.job,
        playbackUrl: 'http://127.0.0.1:3210/media/mj-1/output.mp4',
        localDir: join(fx.tempRoot, fx.job.jobId + '-b'),
        signal: new AbortController().signal
      },
      deps(fx, { config: { ...fx.config, videoMediaBudgetBytes: 1 } })
    );
    assert.equal(budget.status, 'skipped');
    if (budget.status === 'skipped') assert.equal(budget.reason, 'budget');
    assert.equal(fx.mediaStore.currentReadyForContent('selfhost', 'video', fx.job.contentKey), null);
  } finally {
    await fx.cleanup();
  }
});

test('cancelled download does not leave a ready record', async () => {
  const fx = await setup();
  try {
    const controller = new AbortController();
    await assert.rejects(
      () =>
        promoteVideoMedia(
          {
            job: fx.job,
            playbackUrl: 'http://127.0.0.1:3210/media/mj-1/output.mp4',
            localDir: join(fx.tempRoot, fx.job.jobId),
            signal: controller.signal
          },
          deps(fx, {
            download: async () => {
              controller.abort();
              throw new Error('aborted');
            }
          })
        ),
      VideoPromotionError
    );
    assert.equal(fx.mediaStore.currentReadyForContent('selfhost', 'video', fx.job.contentKey), null);
  } finally {
    await fx.cleanup();
  }
});


test('video upload retry uses completed MP4 cache and preserves subtitle checkpoints', async () => {
  const fx=await setup();
  try {
    fx.jobs.recordCheckpoint(fx.job.jobId,{stage:'transcribing',output:{segments:[{text:'retained'}]}});
    let downloads=0;
    const originalPut=fx.objects.putStream.bind(fx.objects);
    fx.objects.putStream=async()=>{throw new Error('R2 unavailable');};
    const options=deps(fx,{download:async(...args)=>{downloads++;return fakeDownload()(...args);}});
    const input={job:fx.job,playbackUrl:'http://127.0.0.1:3210/media/video.mp4',localDir:fx.tempRoot,signal:new AbortController().signal};
    await assert.rejects(promoteVideoMedia(input,options));
    assert.ok(await cachedVideo(fx.tempRoot,400*1024*1024));
    fx.objects.putStream=originalPut;
    const result=await promoteVideoMedia({...input,playbackUrl:''},options);
    assert.equal(result.status,'ready');assert.equal(downloads,1);
    assert.deepEqual(fx.jobs.reusableCheckpoints(fx.job.jobId).find(c=>c.stage==='transcribing')?.output,{segments:[{text:'retained'}]});
    assert.equal(await cachedVideo(fx.tempRoot,400*1024*1024,Date.now()+86_400_001),null);
    await writeFile(join(fx.tempRoot,'source.mp4'),Buffer.alloc(MP4_BYTES.length));
    assert.equal(await cachedVideo(fx.tempRoot,400*1024*1024),null);
  } finally {await fx.cleanup();}
});

test('media task queue deduplicates, survives reopen, and keeps retry independent of subtitle state', async()=>{
 const fx=await setup();
 try {
  const tasks=new VideoMediaTaskStore(fx.db);const id=tasks.contentId(fx.job);
  tasks.enqueue(id,fx.job.jobId);tasks.enqueue(id,fx.job.jobId);
  assert.equal((fx.db.prepare('SELECT count(*) n FROM video_media_task').get() as {n:number}).n,1);
  tasks.start(id,fx.job.jobId);const recovered=new VideoMediaTaskStore(fx.db);recovered.recover();
  assert.equal(recovered.next()?.state,'queued');
  recovered.start(id,fx.job.jobId);recovered.finish(id,'ARTIFACT_PUBLISH_FAILED');
  assert.equal(recovered.get(id)?.attempts,2);
  assert.equal(fx.jobs.getJob(fx.job.jobId)?.status,'queued');
  recovered.enqueue(id,fx.job.jobId);assert.equal(recovered.get(id)?.failure_code,null);
 } finally {await fx.cleanup();}
});

test('failed object deletion retains deleting record for a later cleanup attempt', async()=>{
 const fx=await setup();
 try {
  const result=await promoteVideoMedia({job:fx.job,playbackUrl:'http://127.0.0.1:3210/media/video.mp4',localDir:fx.tempRoot,signal:new AbortController().signal},deps(fx));
  assert.equal(result.status,'ready');if(result.status!=='ready') return;
  fx.jobs.cancelJob(fx.job.jobId);
  const originalDelete=fx.objects.delete.bind(fx.objects);
  fx.objects.delete=async()=>{throw new Error('temporary failure');};
  const worker=new MediaRetentionWorker({mediaStore:fx.mediaStore,objects:fx.objects,keys:fx.layout,logger:fx.logger,intervalMs:1000,batchSize:50,now:()=>Date.now()+31*86_400_000});
  assert.equal(await worker.runOnce(),0);
  assert.equal(fx.mediaStore.listByState('deleting',50).length,1);
  fx.objects.delete=originalDelete;
  assert.equal(await worker.runOnce(),1);
  assert.equal(fx.mediaStore.listByState('deleting',50).length,0);
 } finally {await fx.cleanup();}
});


test('media status/retry API authenticates, deduplicates, and never creates subtitle jobs', async()=>{
 const fx=await setup();
 const tasks=new VideoMediaTaskStore(fx.db);
 const app=createApp({config:fx.config,logger:fx.logger,contentMediaRoutes:{config:fx.config,store:fx.jobs,mediaStore:fx.mediaStore,objects:fx.objects,keys:fx.layout,mediaTasks:tasks}});
 app.server.listen(0,'127.0.0.1');await once(app.server,'listening');
 try {
  const address=app.server.address();assert.ok(address&&typeof address==='object');
  const base=`http://127.0.0.1:${address.port}/v1/content-media/`;
  const request={method:'POST',headers:{'Content-Type':'application/json','Authorization':`Bearer ${fx.config.serviceToken}`},body:JSON.stringify({contentType:'video',contentKey:fx.job.contentKey})};
  const denied=await fetch(base+'video-retry',{...request,headers:{'Content-Type':'application/json'}});assert.equal(denied.status,401);
  const status=await fetch(base+'video-status',request);assert.equal((await status.json() as {state:string}).state,'not_saved');
  for(let i=0;i<2;i++) {const res=await fetch(base+'video-retry',request);assert.equal(res.status,202);assert.equal((await res.json() as {state:string}).state,'queued');}
  assert.equal((fx.db.prepare('SELECT count(*) n FROM content_job').get() as {n:number}).n,1);
  assert.equal((fx.db.prepare('SELECT count(*) n FROM video_media_task').get() as {n:number}).n,1);
  assert.equal(fx.jobs.reusableCheckpoints(fx.job.jobId).filter(c=>c.stage==='transcribing').length,0);
 } finally {await app.close();await fx.cleanup();}
});
