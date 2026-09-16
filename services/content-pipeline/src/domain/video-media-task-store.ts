import type { DatabaseSync } from 'node:sqlite';
import type { JobRow } from './job-model.js';

export interface VideoMediaTask {
  content_id: number;
  job_id: string;
  state: 'queued' | 'running' | 'ready' | 'failed';
  attempts: number;
  failure_code: string | null;
  updated_at: number;
}

/** One durable work item per content; subtitle jobs and media retries share it. */
export class VideoMediaTaskStore {
  constructor(private readonly db: DatabaseSync) {}
  get(contentId: number): VideoMediaTask | null {
    return this.db.prepare('SELECT * FROM video_media_task WHERE content_id=?').get(contentId) as unknown as VideoMediaTask ?? null;
  }
  enqueue(contentId: number, jobId: string): VideoMediaTask {
    this.db.prepare(`INSERT INTO video_media_task(content_id,job_id,state,updated_at) VALUES(?,?,'queued',?)
      ON CONFLICT(content_id) DO UPDATE SET job_id=excluded.job_id,state='queued',failure_code=NULL,updated_at=excluded.updated_at
      WHERE video_media_task.state NOT IN ('queued','running')`).run(contentId,jobId,Date.now());
    return this.get(contentId)!;
  }
  start(contentId: number, jobId: string): void {
    this.enqueue(contentId,jobId);
    this.db.prepare("UPDATE video_media_task SET state='running',attempts=attempts+1,failure_code=NULL,updated_at=? WHERE content_id=?").run(Date.now(),contentId);
  }
  finish(contentId: number, failureCode: string | null): void {
    this.db.prepare('UPDATE video_media_task SET state=?,failure_code=?,updated_at=? WHERE content_id=?')
      .run(failureCode ? 'failed' : 'ready',failureCode,Date.now(),contentId);
  }
  recover(): void {
    this.db.prepare("UPDATE video_media_task SET state='queued',updated_at=? WHERE state='running'").run(Date.now());
  }
  next(): VideoMediaTask | null {
    return this.db.prepare("SELECT * FROM video_media_task WHERE state='queued' ORDER BY updated_at LIMIT 1").get() as unknown as VideoMediaTask ?? null;
  }
  latestJobId(contentId: number): string | null {
    const row=this.db.prepare(`SELECT j.job_id FROM content_job j JOIN generation_variant v ON v.id=j.variant_id
      WHERE v.content_id=? ORDER BY j.created_at DESC LIMIT 1`).get(contentId) as {job_id:string} | undefined;
    return row?.job_id ?? null;
  }
  contentId(job: JobRow): number {
    const row=this.db.prepare('SELECT v.content_id FROM generation_variant v JOIN content_job j ON j.variant_id=v.id WHERE j.job_id=?').get(job.jobId) as {content_id:number};
    return row.content_id;
  }
  active(contentId: number): boolean {
    const task=this.get(contentId);
    return task?.state==='queued'||task?.state==='running';
  }
}
