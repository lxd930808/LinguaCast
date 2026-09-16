import type { Logger } from '../observability/logger.js';
import type { JobRow } from '../domain/job-model.js';
import { newTraceId } from '../api/http-utils.js';
import type { ClaimLimits, JobStore } from './job-store.js';

/**
 * Single content worker with database lease. Exactly one media task runs at a
 * time (DMIT guardrail). The executor is pluggable: WP4–WP6 wire the real
 * pipeline; tests inject fakes. A job whose lease dies mid-run is reclaimed
 * into 'queued' by recoverInterruptedJobs on the next start.
 */

export interface PipelineExecutionContext {
  job: JobRow;
  logger: Logger;
  signal: AbortSignal;
  heartbeat: () => void;
  updateProgress: (update: Parameters<JobStore['updateProgress']>[1]) => void;
  recordCheckpoint: (checkpoint: Parameters<JobStore['recordCheckpoint']>[1]) => void;
  reusableCheckpoints: () => Array<{ stage: NonNullable<JobRow['stage']>; output: unknown }>;
}

export type PipelineExecutor = (context: PipelineExecutionContext) => Promise<unknown>;

export interface WorkerOptions {
  store: JobStore;
  logger: Logger;
  workerId: string;
  executor: PipelineExecutor;
  leaseMs?: number;
  /** Per-owner and global running limits enforced atomically when claiming. */
  claimLimits?: ClaimLimits;
  pollIntervalMs?: number;
  heartbeatIntervalMs?: number;
}

export class ContentWorker {
  private readonly leaseMs: number;
  private readonly pollIntervalMs: number;
  private readonly heartbeatIntervalMs: number;
  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private abort: AbortController | null = null;
  private current: JobRow | null = null;

  constructor(private readonly options: WorkerOptions) {
    this.leaseMs = options.leaseMs ?? 30_000;
    this.pollIntervalMs = options.pollIntervalMs ?? 1_000;
    this.heartbeatIntervalMs = options.heartbeatIntervalMs ?? 10_000;
  }

  start(): void {
    if (this.timer) return;
    const reclaimed = this.options.store.recoverInterruptedJobs();
    if (reclaimed > 0) {
      this.options.logger.warn('reclaimed interrupted jobs', { count: reclaimed });
    }
    const tick = () => {
      void this.runOnce().catch((error) => {
        this.options.logger.error('worker tick failed', { err: String(error) });
      });
      this.timer = setTimeout(tick, this.pollIntervalMs);
      this.timer.unref?.();
    };
    this.timer = setTimeout(tick, 0);
    this.timer.unref?.();
  }

  stop(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.abort?.abort();
  }

  /** Owner of the job currently executing, if any (account purge checks). */
  get currentOwnerScope(): string | null {
    return this.current?.ownerScope ?? null;
  }

  /** Aborts the executing job; its terminal state is decided by the stored status. */
  abortCurrent(): void {
    this.abort?.abort();
  }

  /** True while a job is being executed (readiness/observability). */
  get busy(): boolean {
    return this.running;
  }

  async runOnce(): Promise<boolean> {
    if (this.running) return false;
    const { store, logger, workerId, executor } = this.options;
    const job = store.claimNextJob(workerId, this.leaseMs, Date.now(), this.options.claimLimits);
    if (!job) return false;

    this.running = true;
    this.current = job;
    this.abort = new AbortController();
    const heartbeatTimer = setInterval(() => {
      const ok = store.heartbeat(job.jobId, workerId, this.leaseMs);
      if (!ok) logger.warn('lease heartbeat lost', { jobId: job.jobId });
    }, this.heartbeatIntervalMs);
    heartbeatTimer.unref?.();

    try {
      logger.info('job claimed', { jobId: job.jobId, attempt: job.attemptCount });
      const artifacts = await executor({
        job,
        logger,
        signal: this.abort.signal,
        heartbeat: () => store.heartbeat(job.jobId, workerId, this.leaseMs),
        updateProgress: (update) => store.updateProgress(job.jobId, update),
        recordCheckpoint: (checkpoint) => store.recordCheckpoint(job.jobId, checkpoint),
        reusableCheckpoints: () => store.reusableCheckpoints(job.jobId)
      });
      // Cancellation may have won the race while the executor finished.
      const current = store.getJob(job.jobId);
      if (current?.status === 'running') {
        store.completeJob(job.jobId, artifacts ?? null);
        logger.info('job ready', { jobId: job.jobId });
      } else {
        logger.info('job finished but no longer running', {
          jobId: job.jobId,
          status: current?.status
        });
      }
    } catch (error) {
      const current = store.getJob(job.jobId);
      if (current?.status === 'running') {
        const jobError = toJobError(error);
        store.failJob(job.jobId, jobError);
        logger.warn('job failed', { jobId: job.jobId, code: jobError.code });
      }
    } finally {
      clearInterval(heartbeatTimer);
      this.running = false;
      this.current = null;
      this.abort = null;
    }
    return true;
  }
}

export class PipelineJobError extends Error {
  constructor(
    readonly jobError: Omit<import('../domain/job-model.js').JobError, 'traceId'>,
    cause?: unknown
  ) {
    super(jobError.message, { cause });
    this.name = 'PipelineJobError';
  }
}

function toJobError(error: unknown): import('../domain/job-model.js').JobError {
  if (error instanceof PipelineJobError) {
    return { ...error.jobError, traceId: newTraceId() };
  }
  return {
    code: 'INTERNAL_ERROR',
    message: error instanceof Error ? error.message : String(error),
    retryable: true,
    traceId: newTraceId()
  };
}
