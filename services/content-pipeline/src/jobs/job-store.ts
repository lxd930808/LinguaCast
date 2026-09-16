import { ulid } from 'ulid';
import type { DatabaseSync } from 'node:sqlite';

import { dedupeKey } from '../domain/content-key.js';
import {
  isTerminalStatus,
  STAGE_PROGRESS_CEILING,
  STAGE_PROGRESS_FLOOR,
  type ContentSource,
  type ContentType,
  type JobError,
  type JobRow,
  type JobStage,
  type JobStatus,
  type TranslationQuality
} from '../domain/job-model.js';

export class IdempotencyConflictError extends Error {
  constructor() {
    super('Idempotency-Key was already used with a different request payload');
    this.name = 'IdempotencyConflictError';
  }
}

export class InvalidJobStateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'InvalidJobStateError';
  }
}

export interface CreateJobInput {
  ownerScope: string;
  contentType: ContentType;
  contentKey: string;
  source: ContentSource;
  sourceLanguage: string;
  targetLanguage: string;
  translationQuality: TranslationQuality;
  pipelineVersion: string;
  clientArtifactSchemaVersion: number;
  idempotencyKey?: string | null;
  requestFingerprint?: string | null;
  now?: number;
  /** Pre-generated job ID (quota flow reserves before inserting). */
  jobId?: string;
  operationKey?: string | null;
  reservationId?: string | null;
  quotaSeconds?: number | null;
  /** Return the latest ready job of the same variant instead of creating a new one. */
  reuseReady?: boolean;
}

export interface ClaimLimits {
  /** Maximum running jobs per owner. */
  perOwner: number;
  /** Maximum running jobs across the service. */
  global: number;
}

const UNLIMITED_CLAIMS: ClaimLimits = { perOwner: 1_000_000, global: 1_000_000 };

export interface SettlementRow {
  reservationId: string;
  outcome: 'consumed' | 'released';
  reason: 'succeeded' | 'failed' | 'cancelled' | 'reused_artifact' | 'rejected_before_start' | 'account_deleted';
  jobId: string | null;
  attempts: number;
}

export interface QuotaIntentRow {
  operationKey: string;
  ownerScope: string;
  jobId: string;
  amount: number;
  createdAt: number;
}

export interface CreateJobResult {
  job: JobRow;
  reused: boolean;
}

export interface ProgressUpdate {
  stage?: JobStage | null;
  progress?: number;
  stageProgress?: number | null;
  audioReady?: boolean;
  subtitlesReady?: boolean;
}

export interface CheckpointInput {
  stage: JobStage;
  inputFingerprint?: string | null;
  output?: unknown;
  schemaVersion?: number;
  checksum?: string | null;
  reusable?: boolean;
  completedAt?: number;
}

interface RawRow {
  job_id: string;
  owner_scope: string;
  content_type: string;
  content_key: string;
  platform: string;
  source_id: string;
  source_url: string;
  feed_url: string | null;
  title: string | null;
  source_language: string;
  target_language: string;
  translation_quality: string;
  pipeline_version: string;
  client_artifact_schema_version: number;
  dedupe_key: string;
  idempotency_key: string | null;
  request_fingerprint: string | null;
  status: string;
  stage: string | null;
  progress: number;
  stage_progress: number | null;
  audio_ready: number;
  subtitles_ready: number;
  error_json: string | null;
  artifacts_json: string | null;
  attempt_count: number;
  lease_owner: string | null;
  lease_expires_at: number | null;
  created_at: number;
  updated_at: number;
  operation_key: string | null;
  reservation_id: string | null;
  quota_seconds: number | null;
}

const JOB_SELECT = `
  SELECT j.job_id, j.owner_scope, c.content_type, c.content_key, c.platform, c.source_id,
         c.source_url, c.feed_url, c.title,
         v.source_language, v.target_language, v.translation_quality, v.pipeline_version,
         j.client_artifact_schema_version, v.dedupe_key,
         j.idempotency_key, j.request_fingerprint, j.status, j.stage, j.progress,
         j.stage_progress, j.audio_ready, j.subtitles_ready, j.error_json, j.artifacts_json,
         j.attempt_count, j.lease_owner, j.lease_expires_at, j.created_at, j.updated_at,
         j.operation_key, j.reservation_id, j.quota_seconds
  FROM content_job j
  JOIN generation_variant v ON v.id = j.variant_id
  JOIN content c ON c.id = v.content_id
`;

export class JobStore {
  constructor(private readonly db: DatabaseSync) {}

  private rowToJob(row: RawRow): JobRow {
    return {
      jobId: row.job_id,
      ownerScope: row.owner_scope,
      contentType: row.content_type as ContentType,
      contentKey: row.content_key,
      source: {
        platform: row.platform as ContentSource['platform'],
        sourceId: row.source_id,
        url: row.source_url,
        ...(row.feed_url ? { feedUrl: row.feed_url } : {}),
        ...(row.title ? { title: row.title } : {})
      },
      sourceLanguage: row.source_language,
      targetLanguage: row.target_language,
      translationQuality: row.translation_quality as TranslationQuality,
      pipelineVersion: row.pipeline_version,
      clientArtifactSchemaVersion: row.client_artifact_schema_version,
      dedupeKey: row.dedupe_key,
      idempotencyKey: row.idempotency_key,
      requestFingerprint: row.request_fingerprint,
      status: row.status as JobStatus,
      stage: (row.stage as JobStage | null) ?? null,
      progress: row.progress,
      stageProgress: row.stage_progress,
      audioReady: row.audio_ready === 1,
      subtitlesReady: row.subtitles_ready === 1,
      error: row.error_json ? (JSON.parse(row.error_json) as JobError) : null,
      artifacts: row.artifacts_json ? JSON.parse(row.artifacts_json) : null,
      attemptCount: row.attempt_count,
      leaseOwner: row.lease_owner,
      leaseExpiresAt: row.lease_expires_at,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
      operationKey: row.operation_key,
      reservationId: row.reservation_id,
      quotaSeconds: row.quota_seconds
    };
  }

  private getRaw(jobId: string): JobRow | null {
    const row = this.db.prepare(`${JOB_SELECT} WHERE j.job_id = ?`).get(jobId) as RawRow | undefined;
    return row ? this.rowToJob(row) : null;
  }

  getJob(jobId: string): JobRow | null {
    return this.getRaw(jobId);
  }

  /** Transactional idempotent create (WP2 task 4). */
  createJob(input: CreateJobInput): CreateJobResult {
    const now = input.now ?? Date.now();
    const key = dedupeKey({
      ownerScope: input.ownerScope,
      contentType: input.contentType,
      contentKey: input.contentKey,
      sourceLanguage: input.sourceLanguage,
      targetLanguage: input.targetLanguage,
      translationQuality: input.translationQuality,
      pipelineVersion: input.pipelineVersion
    });

    this.db.exec('BEGIN IMMEDIATE');
    try {
      if (input.idempotencyKey) {
        const existing = this.db
          .prepare(
            `${JOB_SELECT} WHERE j.owner_scope = ? AND j.idempotency_key = ? ORDER BY j.created_at DESC LIMIT 1`
          )
          .get(input.ownerScope, input.idempotencyKey) as RawRow | undefined;
        if (existing) {
          const job = this.rowToJob(existing);
          const terminal =
            job.status === 'failed' || job.status === 'cancelled' || job.status === 'expired';
          if (!terminal) {
            if (
              input.requestFingerprint &&
              job.requestFingerprint &&
              job.requestFingerprint !== input.requestFingerprint
            ) {
              this.db.exec('ROLLBACK');
              throw new IdempotencyConflictError();
            }
            this.db.exec('COMMIT');
            return { job, reused: true };
          }
        }
      }

      this.db
        .prepare(
          `INSERT INTO content (owner_scope, content_type, content_key, platform, source_id, source_url, feed_url, title, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT (owner_scope, content_type, content_key)
           DO UPDATE SET source_url = excluded.source_url, title = COALESCE(excluded.title, content.title)`
        )
        .run(
          input.ownerScope,
          input.contentType,
          input.contentKey,
          input.source.platform,
          input.source.sourceId,
          input.source.url,
          input.source.feedUrl ?? null,
          input.source.title ?? null,
          now
        );
      const content = this.db
        .prepare('SELECT id FROM content WHERE owner_scope = ? AND content_type = ? AND content_key = ?')
        .get(input.ownerScope, input.contentType, input.contentKey) as { id: number };

      this.db
        .prepare(
          `INSERT INTO generation_variant
             (content_id, source_language, target_language, translation_quality, pipeline_version, dedupe_key, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT (dedupe_key) DO NOTHING`
        )
        .run(
          content.id,
          input.sourceLanguage,
          input.targetLanguage,
          input.translationQuality,
          input.pipelineVersion,
          key,
          now
        );
      const variant = this.db
        .prepare('SELECT id FROM generation_variant WHERE dedupe_key = ?')
        .get(key) as { id: number };

      const active = this.db
        .prepare(
          `${JOB_SELECT} WHERE j.variant_id = ? AND j.status IN ('queued', 'running') ORDER BY j.created_at DESC`
        )
        .get(variant.id) as RawRow | undefined;
      if (active) {
        this.db.exec('COMMIT');
        return { job: this.rowToJob(active), reused: true };
      }
      if (input.reuseReady) {
        const ready = this.db
          .prepare(`${JOB_SELECT} WHERE j.variant_id = ? AND j.status = 'ready' ORDER BY j.created_at DESC LIMIT 1`)
          .get(variant.id) as RawRow | undefined;
        if (ready) {
          this.db.exec('COMMIT');
          return { job: this.rowToJob(ready), reused: true };
        }
      }

      const jobId = input.jobId ?? `cj_${ulid()}`;
      this.db
        .prepare(
          `INSERT INTO content_job
             (job_id, variant_id, owner_scope, idempotency_key, request_fingerprint, status, stage,
              progress, stage_progress, audio_ready, subtitles_ready, attempt_count, created_at, updated_at,
              client_artifact_schema_version, operation_key, reservation_id, quota_seconds)
           VALUES (?, ?, ?, ?, ?, 'queued', NULL, 0, NULL, 0, 0, 0, ?, ?, ?, ?, ?, ?)`
        )
        .run(
          jobId,
          variant.id,
          input.ownerScope,
          input.idempotencyKey ?? null,
          input.requestFingerprint ?? null,
          now,
          now,
          input.clientArtifactSchemaVersion,
          input.operationKey ?? null,
          input.reservationId ?? null,
          input.quotaSeconds ?? null
        );
      this.db.exec('COMMIT');
      return { job: this.getRaw(jobId)!, reused: false };
    } catch (error) {
      try {
        this.db.exec('ROLLBACK');
      } catch {
        // Transaction already closed by an earlier COMMIT/ROLLBACK.
      }
      throw error;
    }
  }

  /**
   * Job an identical submission would reuse, without side effects. The quota
   * flow calls this before probing and reserving so reuse is always free.
   */
  peekReusable(input: CreateJobInput): JobRow | null {
    if (input.idempotencyKey) {
      const existing = this.db
        .prepare(`${JOB_SELECT} WHERE j.owner_scope = ? AND j.idempotency_key = ? ORDER BY j.created_at DESC LIMIT 1`)
        .get(input.ownerScope, input.idempotencyKey) as RawRow | undefined;
      if (existing) {
        const job = this.rowToJob(existing);
        if (job.status !== 'failed' && job.status !== 'cancelled' && job.status !== 'expired') {
          if (input.requestFingerprint && job.requestFingerprint && job.requestFingerprint !== input.requestFingerprint) {
            throw new IdempotencyConflictError();
          }
          return job;
        }
      }
    }
    const key = dedupeKey({
      ownerScope: input.ownerScope,
      contentType: input.contentType,
      contentKey: input.contentKey,
      sourceLanguage: input.sourceLanguage,
      targetLanguage: input.targetLanguage,
      translationQuality: input.translationQuality,
      pipelineVersion: input.pipelineVersion
    });
    const statuses = input.reuseReady ? "('queued', 'running', 'ready')" : "('queued', 'running')";
    const row = this.db
      .prepare(
        `${JOB_SELECT} WHERE v.dedupe_key = ? AND j.status IN ${statuses}
         ORDER BY CASE WHEN j.status = 'ready' THEN 1 ELSE 0 END, j.created_at DESC LIMIT 1`
      )
      .get(key) as RawRow | undefined;
    return row ? this.rowToJob(row) : null;
  }

  /** Re-queues a retryable failed job with a new reservation (quota flow). */
  retryJobWithReservation(jobId: string, operationKey: string, reservationId: string, quotaSeconds: number, now = Date.now()): JobRow {
    this.retryJob(jobId, now);
    this.db
      .prepare('UPDATE content_job SET operation_key = ?, reservation_id = ?, quota_seconds = ? WHERE job_id = ?')
      .run(operationKey, reservationId, quotaSeconds, jobId);
    return this.getRaw(jobId)!;
  }

  recordIntent(operationKey: string, ownerScope: string, jobId: string, amount: number, now = Date.now()): void {
    this.db
      .prepare(
        `INSERT INTO quota_intents (operation_key, owner_scope, job_id, amount, created_at) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT (operation_key) DO UPDATE SET job_id = excluded.job_id, amount = excluded.amount, created_at = excluded.created_at`
      )
      .run(operationKey, ownerScope, jobId, amount, now);
  }

  deleteIntent(operationKey: string): void {
    this.db.prepare('DELETE FROM quota_intents WHERE operation_key = ?').run(operationKey);
  }

  listIntents(createdBefore: number): QuotaIntentRow[] {
    const rows = this.db
      .prepare('SELECT * FROM quota_intents WHERE created_at <= ? ORDER BY created_at ASC')
      .all(createdBefore) as Array<Record<string, unknown>>;
    return rows.map((row) => ({
      operationKey: String(row.operation_key),
      ownerScope: String(row.owner_scope),
      jobId: String(row.job_id),
      amount: Number(row.amount),
      createdAt: Number(row.created_at)
    }));
  }

  /** Idempotent: one settlement per reservation; later requests for the same reservation are ignored. */
  enqueueSettlement(
    reservationId: string,
    outcome: SettlementRow['outcome'],
    reason: SettlementRow['reason'],
    jobId: string | null,
    now = Date.now()
  ): void {
    this.db
      .prepare(
        `INSERT OR IGNORE INTO quota_settlement_outbox (reservation_id, outcome, reason, job_id, created_at)
         VALUES (?, ?, ?, ?, ?)`
      )
      .run(reservationId, outcome, reason, jobId, now);
  }

  pendingSettlements(limit: number): SettlementRow[] {
    const rows = this.db
      .prepare('SELECT * FROM quota_settlement_outbox WHERE delivered_at IS NULL ORDER BY created_at ASC LIMIT ?')
      .all(limit) as Array<Record<string, unknown>>;
    return rows.map((row) => ({
      reservationId: String(row.reservation_id),
      outcome: row.outcome as SettlementRow['outcome'],
      reason: row.reason as SettlementRow['reason'],
      jobId: (row.job_id as string | null) ?? null,
      attempts: Number(row.attempts)
    }));
  }

  markSettlementDelivered(reservationId: string, now = Date.now(), note: string | null = null): void {
    this.db
      .prepare('UPDATE quota_settlement_outbox SET delivered_at = ?, attempts = attempts + 1, last_error = ? WHERE reservation_id = ?')
      .run(now, note, reservationId);
  }

  markSettlementAttempt(reservationId: string, error: string): void {
    this.db
      .prepare('UPDATE quota_settlement_outbox SET attempts = attempts + 1, last_error = ? WHERE reservation_id = ?')
      .run(error, reservationId);
  }

  settlementFor(reservationId: string): (SettlementRow & { deliveredAt: number | null }) | null {
    const row = this.db.prepare('SELECT * FROM quota_settlement_outbox WHERE reservation_id = ?').get(reservationId) as
      | Record<string, unknown>
      | undefined;
    if (!row) return null;
    return {
      reservationId: String(row.reservation_id),
      outcome: row.outcome as SettlementRow['outcome'],
      reason: row.reason as SettlementRow['reason'],
      jobId: (row.job_id as string | null) ?? null,
      attempts: Number(row.attempts),
      deliveredAt: row.delivered_at === null ? null : Number(row.delivered_at)
    };
  }

  /** Latest job for a generation variant, any status. */
  lookupJob(
    ownerScope: string,
    contentType: ContentType,
    contentKey: string,
    targetLanguage: string,
    translationQuality: TranslationQuality,
    sourceLanguage: string | null = null
  ): JobRow | null {
    const row = this.db
      .prepare(
        `${JOB_SELECT}
         WHERE j.owner_scope = ? AND c.content_type = ? AND c.content_key = ?
           AND v.target_language = ? AND v.translation_quality = ?
           AND (? IS NULL OR v.source_language = ?)
         ORDER BY j.created_at DESC LIMIT 1`
      )
      .get(ownerScope, contentType, contentKey, targetLanguage, translationQuality, sourceLanguage, sourceLanguage) as
      | RawRow
      | undefined;
    return row ? this.rowToJob(row) : null;
  }

  /** Job visible to one owner; foreign or unknown jobs are indistinguishable (null). */
  getJobForOwner(jobId: string, ownerScope: string): JobRow | null {
    const job = this.getRaw(jobId);
    return job && job.ownerScope === ownerScope ? job : null;
  }

  retryJobForOwner(jobId: string, ownerScope: string, now = Date.now()): JobRow | null {
    return this.getJobForOwner(jobId, ownerScope) ? this.retryJob(jobId, now) : null;
  }

  cancelJobForOwner(jobId: string, ownerScope: string, now = Date.now()): JobRow | null {
    return this.getJobForOwner(jobId, ownerScope) ? this.cancelJob(jobId, now) : null;
  }

  /** Cancels every queued/running job of an owner; returns the affected job IDs. */
  cancelActiveJobsForOwner(ownerScope: string, now = Date.now()): string[] {
    const rows = this.db
      .prepare("SELECT job_id FROM content_job WHERE owner_scope = ? AND status IN ('queued', 'running')")
      .all(ownerScope) as Array<{ job_id: string }>;
    for (const row of rows) this.cancelJob(row.job_id, now);
    return rows.map((row) => row.job_id);
  }

  /**
   * Deletes every row owned by one account in a single transaction and
   * returns the object keys and job IDs whose storage must also be removed.
   */
  purgeOwnerRows(ownerScope: string): { jobIds: string[]; objectKeys: string[] } {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const jobIds = (
        this.db.prepare('SELECT job_id FROM content_job WHERE owner_scope = ?').all(ownerScope) as Array<{ job_id: string }>
      ).map((row) => row.job_id);
      const ownedContent = 'SELECT id FROM content WHERE owner_scope = ?';
      const objectKeys = [
        ...(this.db
          .prepare(`SELECT object_key FROM source_artifact WHERE object_key IS NOT NULL AND content_id IN (${ownedContent})`)
          .all(ownerScope) as Array<{ object_key: string }>),
        ...(this.db
          .prepare(`SELECT object_key FROM content_media_asset WHERE object_key IS NOT NULL AND content_id IN (${ownedContent})`)
          .all(ownerScope) as Array<{ object_key: string }>)
      ].map((row) => row.object_key);
      const ownedJobs = 'SELECT job_id FROM content_job WHERE owner_scope = ?';
      this.db.prepare(`DELETE FROM stage_checkpoint WHERE job_id IN (${ownedJobs})`).run(ownerScope);
      this.db.prepare(`DELETE FROM artifact_manifest WHERE job_id IN (${ownedJobs})`).run(ownerScope);
      this.db.prepare('DELETE FROM content_job WHERE owner_scope = ?').run(ownerScope);
      this.db.prepare(`DELETE FROM video_media_task WHERE content_id IN (${ownedContent})`).run(ownerScope);
      this.db.prepare(`DELETE FROM content_media_asset WHERE content_id IN (${ownedContent})`).run(ownerScope);
      this.db.prepare(`DELETE FROM source_artifact WHERE content_id IN (${ownedContent})`).run(ownerScope);
      this.db.prepare(`DELETE FROM generation_variant WHERE content_id IN (${ownedContent})`).run(ownerScope);
      this.db.prepare('DELETE FROM content WHERE owner_scope = ?').run(ownerScope);
      this.db.exec('COMMIT');
      return { jobIds, objectKeys: [...new Set(objectKeys)] };
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  retryJob(jobId: string, now = Date.now()): JobRow {
    const job = this.getRaw(jobId);
    if (!job) throw new InvalidJobStateError(`unknown job ${jobId}`);
    if (job.status !== 'failed' || !job.error?.retryable) {
      throw new InvalidJobStateError(`job ${jobId} is not in a retryable failed state`);
    }
    this.db
      .prepare(
        `UPDATE content_job
         SET status = 'queued', stage = NULL, stage_progress = NULL, error_json = NULL,
             lease_owner = NULL, lease_expires_at = NULL, updated_at = ?
         WHERE job_id = ?`
      )
      .run(now, jobId);
    return this.getRaw(jobId)!;
  }

  cancelJob(jobId: string, now = Date.now()): JobRow {
    const job = this.getRaw(jobId);
    if (!job) throw new InvalidJobStateError(`unknown job ${jobId}`);
    if (isTerminalStatus(job.status)) {
      if (job.status === 'ready') {
        throw new InvalidJobStateError('job is ready; use artifact purge flow instead of cancel');
      }
      return job; // idempotent cancel on failed/cancelled/expired
    }
    this.inTransaction(() => {
      const changed = this.db
        .prepare(
          `UPDATE content_job
           SET status = 'cancelled', lease_owner = NULL, lease_expires_at = NULL, updated_at = ?
           WHERE job_id = ? AND status IN ('queued', 'running')`
        )
        .run(now, jobId);
      if (Number(changed.changes) === 1 && job.reservationId) {
        this.enqueueSettlement(job.reservationId, 'released', 'cancelled', jobId, now);
      }
    });
    return this.getRaw(jobId)!;
  }

  private inTransaction(fn: () => void): void {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      fn();
      this.db.exec('COMMIT');
    } catch (error) {
      try {
        this.db.exec('ROLLBACK');
      } catch {
        // Transaction already closed.
      }
      throw error;
    }
  }

  /** Single-worker lease claim: oldest queued job becomes running. */
  /**
   * FIFO claim that respects per-owner and global running limits atomically;
   * jobs over a limit stay queued (queueing is a status, not an error).
   */
  claimNextJob(workerId: string, leaseMs: number, now = Date.now(), limits: ClaimLimits = UNLIMITED_CLAIMS): JobRow | null {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const row = this.db
        .prepare(
          `SELECT j.job_id FROM content_job j
            WHERE j.status = 'queued'
              AND (SELECT COUNT(*) FROM content_job r WHERE r.status = 'running' AND r.owner_scope = j.owner_scope) < ?
              AND (SELECT COUNT(*) FROM content_job g WHERE g.status = 'running') < ?
            ORDER BY j.created_at ASC, j.id ASC LIMIT 1`
        )
        .get(limits.perOwner, limits.global) as { job_id: string } | undefined;
      if (!row) {
        this.db.exec('COMMIT');
        return null;
      }
      this.db
        .prepare(
          `UPDATE content_job
           SET status = 'running', lease_owner = ?, lease_expires_at = ?,
               attempt_count = attempt_count + 1, updated_at = ?
           WHERE job_id = ? AND status = 'queued'`
        )
        .run(workerId, now + leaseMs, now, row.job_id);
      this.db.exec('COMMIT');
      return this.getRaw(row.job_id);
    } catch (error) {
      try {
        this.db.exec('ROLLBACK');
      } catch {
        // Transaction already closed by an earlier COMMIT/ROLLBACK.
      }
      throw error;
    }
  }

  heartbeat(jobId: string, workerId: string, leaseMs: number, now = Date.now()): boolean {
    const result = this.db
      .prepare(
        `UPDATE content_job SET lease_expires_at = ?, updated_at = ?
         WHERE job_id = ? AND status = 'running' AND lease_owner = ?`
      )
      .run(now + leaseMs, now, jobId, workerId);
    return result.changes === 1;
  }

  /** Progress is clamped monotone and within the stage band (contract §5). */
  updateProgress(jobId: string, update: ProgressUpdate, now = Date.now()): void {
    const job = this.getRaw(jobId);
    if (!job) throw new InvalidJobStateError(`unknown job ${jobId}`);
    if (job.status !== 'running') {
      throw new InvalidJobStateError(`cannot update progress of ${job.status} job`);
    }
    const stage = update.stage !== undefined ? update.stage : job.stage;
    let progress = update.progress !== undefined ? update.progress : job.progress;
    if (stage) {
      progress = Math.max(progress, STAGE_PROGRESS_FLOOR[stage]);
      progress = Math.min(progress, STAGE_PROGRESS_CEILING[stage]);
    }
    progress = Math.max(progress, job.progress); // never regress
    this.db
      .prepare(
        `UPDATE content_job
         SET stage = ?, progress = ?, stage_progress = ?, audio_ready = ?, subtitles_ready = ?, updated_at = ?
         WHERE job_id = ?`
      )
      .run(
        stage,
        progress,
        update.stageProgress !== undefined ? update.stageProgress : job.stageProgress,
        update.audioReady !== undefined ? (update.audioReady ? 1 : 0) : job.audioReady ? 1 : 0,
        update.subtitlesReady !== undefined ? (update.subtitlesReady ? 1 : 0) : job.subtitlesReady ? 1 : 0,
        now,
        jobId
      );
  }

  completeJob(jobId: string, artifacts: unknown, now = Date.now()): void {
    const job = this.getRaw(jobId);
    if (!job) throw new InvalidJobStateError(`unknown job ${jobId}`);
    if (job.status !== 'running') {
      throw new InvalidJobStateError(`cannot complete ${job.status} job`);
    }
    this.db.exec('BEGIN IMMEDIATE');
    try {
      this.db
        .prepare('INSERT INTO artifact_manifest (job_id, manifest_json, published_at) VALUES (?, ?, ?)')
        .run(jobId, JSON.stringify(artifacts), now);
      this.db
        .prepare(
          `UPDATE content_job
           SET status = 'ready', stage = 'completed', progress = 1, stage_progress = NULL,
               subtitles_ready = 1, artifacts_json = ?, lease_owner = NULL, lease_expires_at = NULL,
               updated_at = ?
           WHERE job_id = ?`
        )
        .run(JSON.stringify(artifacts), now, jobId);
      if (job.reservationId) this.enqueueSettlement(job.reservationId, 'consumed', 'succeeded', jobId, now);
      this.db.exec('COMMIT');
    } catch (error) {
      try {
        this.db.exec('ROLLBACK');
      } catch {
        // Transaction already closed by an earlier COMMIT/ROLLBACK.
      }
      throw error;
    }
  }

  failJob(jobId: string, error: JobError, now = Date.now()): void {
    const job = this.getRaw(jobId);
    if (!job) throw new InvalidJobStateError(`unknown job ${jobId}`);
    if (job.status !== 'running') {
      throw new InvalidJobStateError(`cannot fail ${job.status} job`);
    }
    this.inTransaction(() => {
      this.db
        .prepare(
          `UPDATE content_job
           SET status = 'failed', error_json = ?, lease_owner = NULL, lease_expires_at = NULL, updated_at = ?
           WHERE job_id = ?`
        )
        .run(JSON.stringify(error), now, jobId);
      if (job.reservationId) this.enqueueSettlement(job.reservationId, 'released', 'failed', jobId, now);
    });
  }

  /** Crash reclaim: running jobs whose lease expired return to queued. */
  recoverInterruptedJobs(now = Date.now()): number {
    const result = this.db
      .prepare(
        `UPDATE content_job
         SET status = 'queued', stage_progress = NULL, lease_owner = NULL, lease_expires_at = NULL,
             updated_at = ?
         WHERE status = 'running' AND lease_expires_at IS NOT NULL AND lease_expires_at < ?`
      )
      .run(now, now);
    return Number(result.changes);
  }

  recordCheckpoint(jobId: string, checkpoint: CheckpointInput): void {
    this.db
      .prepare(
        `INSERT INTO stage_checkpoint
           (job_id, stage, input_fingerprint, output_json, schema_version, checksum, reusable, completed_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (job_id, stage)
         DO UPDATE SET input_fingerprint = excluded.input_fingerprint,
                       output_json = excluded.output_json,
                       schema_version = excluded.schema_version,
                       checksum = excluded.checksum,
                       reusable = excluded.reusable,
                       completed_at = excluded.completed_at`
      )
      .run(
        jobId,
        checkpoint.stage,
        checkpoint.inputFingerprint ?? null,
        checkpoint.output !== undefined ? JSON.stringify(checkpoint.output) : null,
        checkpoint.schemaVersion ?? 1,
        checkpoint.checksum ?? null,
        checkpoint.reusable === false ? 0 : 1,
        checkpoint.completedAt ?? Date.now()
      );
  }

  reusableCheckpoints(jobId: string): Array<{ stage: JobStage; output: unknown }> {
    const rows = this.db
      .prepare(
        `SELECT stage, output_json FROM stage_checkpoint WHERE job_id = ? AND reusable = 1 ORDER BY completed_at ASC`
      )
      .all(jobId) as Array<{ stage: string; output_json: string | null }>;
    return rows.map((row) => ({
      stage: row.stage as JobStage,
      output: row.output_json ? JSON.parse(row.output_json) : null
    }));
  }

  // ---- Source artifacts (shared across variants; reference-protected) ----

  registerSourceArtifact(input: {
    jobId: string;
    kind: 'audio' | 'raw_transcript' | 'source_segments';
    fingerprint: string;
    objectKey?: string | null;
    mimeType?: string | null;
    bytes?: number | null;
    durationSeconds?: number | null;
    sha256?: string | null;
    transcoded?: boolean;
    now?: number;
  }): number {
    const row = this.db
      .prepare(
        `SELECT c.id AS content_id FROM content_job j
         JOIN generation_variant v ON v.id = j.variant_id
         JOIN content c ON c.id = v.content_id WHERE j.job_id = ?`
      )
      .get(input.jobId) as { content_id: number } | undefined;
    if (!row) throw new InvalidJobStateError(`unknown job ${input.jobId}`);
    this.db
      .prepare(
        `INSERT INTO source_artifact
           (content_id, kind, fingerprint, object_key, mime_type, bytes, duration_seconds, sha256, transcoded, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (content_id, kind, fingerprint)
         DO UPDATE SET object_key = COALESCE(excluded.object_key, source_artifact.object_key),
                       mime_type = COALESCE(excluded.mime_type, source_artifact.mime_type),
                       bytes = COALESCE(excluded.bytes, source_artifact.bytes),
                       duration_seconds = COALESCE(excluded.duration_seconds, source_artifact.duration_seconds),
                       sha256 = COALESCE(excluded.sha256, source_artifact.sha256),
                       transcoded = excluded.transcoded`
      )
      .run(
        row.content_id,
        input.kind,
        input.fingerprint,
        input.objectKey ?? null,
        input.mimeType ?? null,
        input.bytes ?? null,
        input.durationSeconds ?? null,
        input.sha256 ?? null,
        input.transcoded ? 1 : 0,
        input.now ?? Date.now()
      );
    return row.content_id;
  }

  audioArtifactForJob(jobId: string): {
    objectKey: string;
    mimeType: string;
    bytes: number;
    durationSeconds: number;
    sha256: string;
    transcoded: boolean;
  } | null {
    const row = this.db
      .prepare(
        `SELECT sa.object_key, sa.mime_type, sa.bytes, sa.duration_seconds, sa.sha256, sa.transcoded
         FROM content_job j
         JOIN generation_variant v ON v.id = j.variant_id
         JOIN source_artifact sa ON sa.content_id = v.content_id AND sa.kind = 'audio'
         WHERE j.job_id = ? AND sa.object_key IS NOT NULL
         ORDER BY sa.id DESC LIMIT 1`
      )
      .get(jobId) as
      | {
          object_key: string;
          mime_type: string | null;
          bytes: number | null;
          duration_seconds: number | null;
          sha256: string | null;
          transcoded: number;
        }
      | undefined;
    if (!row) return null;
    return {
      objectKey: row.object_key,
      mimeType: row.mime_type ?? 'audio/mpeg',
      bytes: row.bytes ?? 0,
      durationSeconds: row.duration_seconds ?? 0,
      sha256: row.sha256 ?? '',
      transcoded: row.transcoded === 1
    };
  }

  /**
   * Reference protection: a shared source artifact may only be physically
   * deleted when no non-expired job of ANY variant of the same content still
   * exists (WP3 task 9).
   */
  countActiveJobsForContentOfJob(jobId: string): number {
    const row = this.db
      .prepare(
        `SELECT COUNT(*) AS n FROM content_job j
         WHERE j.variant_id IN (
           SELECT v2.id FROM generation_variant v2
           WHERE v2.content_id = (
             SELECT v1.content_id FROM content_job j1
             JOIN generation_variant v1 ON v1.id = j1.variant_id
             WHERE j1.job_id = ?
           )
         ) AND j.status NOT IN ('expired')`
      )
      .get(jobId) as { n: number };
    return Number(row.n);
  }

  close(): void {
    this.db.close();
  }
}
