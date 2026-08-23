import { mkdir, readdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { ulid } from 'ulid';

import type { MediaMode, ServiceConfig } from '../config.js';
import {
  isTerminalStatus,
  isValidVideoId,
  jobDedupeKey,
  type JobErrorCode,
  type JobPlaybackInfo,
  type JobStatus,
  type MediaJob
} from './job-model.js';

export class JobStore {
  private readonly jobs = new Map<string, MediaJob>();
  private readonly dedupe = new Map<string, string>();
  private readonly creations = new Map<string, Promise<MediaJob>>();
  private readonly persistence = new Map<string, Promise<void>>();
  private cleanupTimer: NodeJS.Timeout | null = null;

  constructor(private readonly config: ServiceConfig) {}

  startCleanupLoop(intervalMs = 5 * 60 * 1000): void {
    if (this.cleanupTimer) return;
    this.cleanupTimer = setInterval(() => {
      void this.cleanupExpired();
    }, intervalMs);
    this.cleanupTimer.unref?.();
  }

  stopCleanupLoop(): void {
    if (!this.cleanupTimer) return;
    clearInterval(this.cleanupTimer);
    this.cleanupTimer = null;
  }

  get(jobId: string): MediaJob | undefined {
    return this.jobs.get(jobId);
  }

  findActiveDedupe(
    videoId: string,
    mode: MediaMode,
    preferredHeight: number
  ): MediaJob | undefined {
    const key = jobDedupeKey(videoId, mode, preferredHeight);
    const existingId = this.dedupe.get(key);
    if (!existingId) return undefined;
    const job = this.jobs.get(existingId);
    if (!job) {
      this.dedupe.delete(key);
      return undefined;
    }
    if (
      job.status === 'failed' ||
      (isTerminalStatus(job.status) && Date.now() >= job.expiresAt)
    ) {
      this.dedupe.delete(key);
      return undefined;
    }
    return job;
  }

  async create(
    videoId: string,
    mode: MediaMode,
    preferredHeight: number
  ): Promise<MediaJob> {
    const existing = this.findActiveDedupe(videoId, mode, preferredHeight);
    if (existing) return existing;
    const key = jobDedupeKey(videoId, mode, preferredHeight);
    const inFlight = this.creations.get(key);
    if (inFlight) return inFlight;

    const creation = this.createNew(videoId, mode, preferredHeight);
    this.creations.set(key, creation);
    try {
      return await creation;
    } finally {
      if (this.creations.get(key) === creation) this.creations.delete(key);
    }
  }

  private async createNew(
    videoId: string,
    mode: MediaMode,
    preferredHeight: number
  ): Promise<MediaJob> {
    const now = Date.now();
    const jobId = ulid();
    const workDir = path.join(this.config.mediaRoot, jobId);
    await mkdir(workDir, { recursive: true });

    const job: MediaJob = {
      jobId,
      videoId,
      mode,
      preferredHeight,
      status: 'queued',
      progress: 0,
      createdAt: now,
      updatedAt: now,
      expiresAt: now + this.config.jobTtlMs,
      workDir,
      diagnostics: {}
    };

    this.jobs.set(jobId, job);
    this.dedupe.set(jobDedupeKey(videoId, mode, preferredHeight), jobId);
    await this.queuePersistence(job);
    return job;
  }

  update(
    jobId: string,
    patch: Partial<
      Pick<
        MediaJob,
        | 'status'
        | 'progress'
        | 'errorCode'
        | 'errorMessage'
        | 'playback'
        | 'diagnostics'
      >
    >
  ): MediaJob | undefined {
    const job = this.jobs.get(jobId);
    if (!job) return undefined;
    if (patch.status !== undefined) job.status = patch.status;
    if (patch.progress !== undefined) job.progress = patch.progress;
    if (patch.errorCode !== undefined) job.errorCode = patch.errorCode;
    if (patch.errorMessage !== undefined) job.errorMessage = patch.errorMessage;
    if (patch.playback !== undefined) job.playback = patch.playback;
    if (patch.diagnostics !== undefined) {
      job.diagnostics = { ...job.diagnostics, ...patch.diagnostics };
    }
    job.updatedAt = Date.now();
    job.expiresAt = Math.max(
      job.expiresAt,
      job.updatedAt + this.config.jobTtlMs
    );
    void this.queuePersistence(job);
    return job;
  }

  fail(jobId: string, errorCode: JobErrorCode, errorMessage: string): MediaJob | undefined {
    return this.update(jobId, {
      status: 'failed',
      errorCode,
      errorMessage
    });
  }

  ready(jobId: string, playback: JobPlaybackInfo, progress = 1): MediaJob | undefined {
    return this.update(jobId, {
      status: 'ready',
      progress,
      playback
    });
  }

  markStatus(jobId: string, status: JobStatus, progress?: number): MediaJob | undefined {
    return this.update(jobId, { status, progress });
  }

  async cleanupExpired(now = Date.now()): Promise<number> {
    let removed = 0;
    for (const job of [...this.jobs.values()]) {
      if (now < job.expiresAt || !isTerminalStatus(job.status)) continue;
      await this.remove(job.jobId);
      removed += 1;
    }
    return removed;
  }

  async remove(jobId: string): Promise<void> {
    const job = this.jobs.get(jobId);
    if (!job) return;
    this.jobs.delete(jobId);
    const key = jobDedupeKey(job.videoId, job.mode, job.preferredHeight);
    if (this.dedupe.get(key) === jobId) this.dedupe.delete(key);
    await this.persistence.get(jobId)?.catch(() => undefined);
    this.persistence.delete(jobId);
    await rm(job.workDir, { recursive: true, force: true });
  }

  list(): MediaJob[] {
    return [...this.jobs.values()];
  }

  async flushPersistence(): Promise<void> {
    await Promise.all(this.persistence.values());
  }

  async restore(): Promise<MediaJob[]> {
    await mkdir(this.config.mediaRoot, { recursive: true });
    const entries = await readdir(this.config.mediaRoot, { withFileTypes: true });
    const resumable: MediaJob[] = [];

    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const workDir = path.join(this.config.mediaRoot, entry.name);
      let job: MediaJob;
      try {
        const raw = JSON.parse(
          await readFile(path.join(workDir, 'job.json'), 'utf8')
        ) as unknown;
        job = this.parsePersistedJob(raw, entry.name, workDir);
      } catch {
        continue;
      }

      if (Date.now() >= job.expiresAt) {
        await rm(workDir, { recursive: true, force: true });
        continue;
      }
      this.jobs.set(job.jobId, job);
      if (job.status !== 'failed') {
        this.dedupe.set(
          jobDedupeKey(job.videoId, job.mode, job.preferredHeight),
          job.jobId
        );
      }

      const incompleteStreamingHls =
        job.mode === 'hls' && job.status === 'ready' && job.progress < 1;
      if (
        (!isTerminalStatus(job.status) || incompleteStreamingHls) &&
        Date.now() < job.expiresAt
      ) {
        job.status = 'queued';
        job.updatedAt = Date.now();
        resumable.push(job);
        void this.queuePersistence(job);
      }
    }

    await this.flushPersistence();
    return resumable;
  }

  private queuePersistence(job: MediaJob): Promise<void> {
    const previous = this.persistence.get(job.jobId);
    const snapshot = this.persistedSnapshot(job);
    const pending = (previous ?? Promise.resolve())
      .catch(() => undefined)
      .then(() => this.writePersistedSnapshot(job.workDir, snapshot));
    this.persistence.set(job.jobId, pending);
    void pending.catch((error) => {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`[job ${job.jobId}] persistence failed: ${message}`);
    });
    return pending;
  }

  private persistedSnapshot(job: MediaJob): Omit<MediaJob, 'workDir'> {
    return {
      jobId: job.jobId,
      videoId: job.videoId,
      mode: job.mode,
      preferredHeight: job.preferredHeight,
      status: job.status,
      progress: job.progress,
      createdAt: job.createdAt,
      updatedAt: job.updatedAt,
      expiresAt: job.expiresAt,
      errorCode: job.errorCode,
      errorMessage: job.errorMessage,
      playback: job.playback,
      r2Keys: job.r2Keys,
      diagnostics: job.diagnostics
    };
  }

  private async writePersistedSnapshot(
    workDir: string,
    snapshot: Omit<MediaJob, 'workDir'>
  ): Promise<void> {
    await mkdir(workDir, { recursive: true });
    const destination = path.join(workDir, 'job.json');
    const temporary = path.join(
      workDir,
      `.job.json.${process.pid}.${Date.now()}.tmp`
    );
    await writeFile(temporary, `${JSON.stringify(snapshot)}\n`, 'utf8');
    await rename(temporary, destination);
  }

  private parsePersistedJob(
    raw: unknown,
    directoryName: string,
    workDir: string
  ): MediaJob {
    if (!raw || typeof raw !== 'object') throw new Error('invalid job metadata');
    const value = raw as Record<string, unknown>;
    const statuses: JobStatus[] = [
      'queued',
      'resolving',
      'fetching',
      'packaging',
      'ready',
      'failed'
    ];
    if (value.jobId !== directoryName) throw new Error('job id mismatch');
    if (typeof value.videoId !== 'string' || !isValidVideoId(value.videoId)) {
      throw new Error('invalid video id');
    }
    if (value.mode !== 'mp4' && value.mode !== 'hls') {
      throw new Error('invalid media mode');
    }
    if (
      typeof value.status !== 'string' ||
      !statuses.includes(value.status as JobStatus)
    ) {
      throw new Error('invalid job status');
    }
    for (const field of [
      'preferredHeight',
      'progress',
      'createdAt',
      'updatedAt',
      'expiresAt'
    ] as const) {
      if (typeof value[field] !== 'number' || !Number.isFinite(value[field])) {
        throw new Error(`invalid ${field}`);
      }
    }
    if (
      !value.diagnostics ||
      typeof value.diagnostics !== 'object' ||
      Array.isArray(value.diagnostics)
    ) {
      throw new Error('invalid diagnostics');
    }

    return {
      ...(value as unknown as Omit<MediaJob, 'workDir'>),
      workDir
    };
  }
}
