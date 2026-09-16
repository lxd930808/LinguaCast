import { join } from 'node:path';
import { readdir, rm, stat } from 'node:fs/promises';
import type { JobRow } from '../../domain/job-model.js';
import type { VideoMediaTaskStore } from '../../domain/video-media-task-store.js';
import type { VideoAudioDeps, VideoAudioHooks } from './video-audio.js';
import { ingestVideoAudio } from './video-audio.js';
import { scopeDepsToOwner } from '../executor.js';

/** Serializes the entire media lifetime, including reads after media-api is ready. */
export class MediaTaskRunner {
  private tail: Promise<void> = Promise.resolve();
  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private abort = new AbortController();
  private current: JobRow | null = null;
  constructor(readonly tasks: VideoMediaTaskStore, private readonly deps: VideoAudioDeps) {}

  /** Owner of the media lifetime currently executing, if any (account purge checks). */
  get currentOwnerScope(): string | null {
    return this.current?.ownerScope ?? null;
  }

  async ingest(job: JobRow, hooks: VideoAudioHooks): Promise<void> {
    const previous=this.tail;
    let release!: () => void;
    this.tail=new Promise<void>(resolve => { release=resolve; });
    await previous;
    try {
      hooks.signal.throwIfAborted();
      const id=this.tasks.contentId(job);
      if (this.deps.config.videoMediaPromotionEnabled) this.tasks.start(id,job.jobId);
      this.current=job;
      try {
        await ingestVideoAudio(job,scopeDepsToOwner(this.deps,job.ownerScope),hooks);
        if (this.deps.config.videoMediaPromotionEnabled) {
          const asset=this.deps.mediaStore?.currentReadyForContent(job.ownerScope,'video',job.contentKey);
          const cp=this.deps.store.reusableCheckpoints(job.jobId).find(c=>c.stage==='fetching_audio')?.output as {promotionFailureCode?:string} | undefined;
          this.tasks.finish(id,asset ? null : cp?.promotionFailureCode ?? 'VIDEO_SAVE_FAILED');
          if(asset) await rm(join(this.deps.config.tempRoot,'media-cache',String(id)),{recursive:true,force:true});
        }
      } catch(error) {
        if(this.deps.config.videoMediaPromotionEnabled) this.tasks.finish(id,'VIDEO_SAVE_FAILED');
        throw error;
      }
    } finally { this.current=null; release(); }
  }

  start(): void {
    if(this.timer) return;
    this.tasks.recover();
    this.timer=setInterval(()=>void this.runOnce().catch(()=>this.deps.logger.warn('video media retry failed')),1000);
    this.timer.unref();
  }
  stop(): void { if(this.timer) clearInterval(this.timer); this.timer=null;this.abort.abort(); }
  async runOnce(): Promise<void> {
    if(this.running || !this.deps.config.videoMediaPromotionEnabled) return;
    const task=this.tasks.next();
    if(!task) return;
    this.running=true;
    try {
      const job=this.deps.store.getJob(task.job_id);
      if(!job) { this.tasks.finish(task.content_id,'JOB_NOT_FOUND');return; }
      await this.ingest(job,{signal:this.abort.signal,heartbeat:()=>{},updateProgress:()=>{}});
    } finally { this.running=false; }
  }
  async cleanupCache(): Promise<void> {
    const root=join(this.deps.config.tempRoot,'media-cache');
    for(const name of await readdir(root).catch(()=>[] as string[])) {
      if(!/^\d+$/.test(name)||this.tasks.active(Number(name))) continue;
      const dir=join(root,name);const info=await stat(dir).catch(()=>null);
      if(info && Date.now()-info.mtimeMs>86_400_000) await rm(dir,{recursive:true,force:true});
    }
  }
}
