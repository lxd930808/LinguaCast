import { createHash } from 'node:crypto';
import type { DatabaseSync } from 'node:sqlite';

import { DomainError } from '../../domain/types.js';
import { nowIso } from '../../domain/ids.js';
import {
  assertArtifactTransition,
  assertResearchTransition,
  assertTurnTransition,
  canMemoryProposalTransition,
  canTranscriptJobTransition,
  type ArtifactStatus,
  type MemoryProposalStatus,
  type OperationStage,
  type ResearchStatus,
  type TranscriptJobStatus,
  type TurnMode,
  type V2TurnStatus,
  type WorkspaceIntegrity
} from '../../research-v2/state.js';

export interface V2ResearchRecord {
  researchId: string;
  ownerScope: string;
  title: string;
  status: ResearchStatus;
  workspaceStatus: WorkspaceIntegrity;
  outputLanguage: string;
  storefront: string;
  targetLanguage: string;
  translationQuality: string;
  activeTurnId: string | null;
  createdAt: string;
  updatedAt: string;
  deletedAt: string | null;
}

export interface V2WorkspaceRecord {
  researchId: string;
  directoryId: string;
  manifestVersion: number;
  manifestSha256: string | null;
  integrityStatus: WorkspaceIntegrity;
  lastRecoveredAt: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface V2TurnRecord {
  turnId: string;
  researchId: string;
  mode: TurnMode;
  status: V2TurnStatus;
  userText: string;
  skillName: string | null;
  skillVersion: string | null;
  skillSha256: string | null;
  errorCode: string | null;
  errorMessage: string | null;
  createdAt: string;
  startedAt: string | null;
  finishedAt: string | null;
  /** V18 quota: logical operation and reservation paying for this turn. */
  operationKey?: string | null;
  reservationId?: string | null;
}

export type TurnSettlementOutcome = 'consumed' | 'released';
export type TurnSettlementReason = 'succeeded' | 'failed' | 'cancelled' | 'reused_artifact' | 'rejected_before_start';

export interface TurnSettlementRow {
  reservationId: string;
  outcome: TurnSettlementOutcome;
  reason: TurnSettlementReason;
  turnId: string | null;
  attempts: number;
  deliveredAt: number | null;
}

/** Terminal turn statuses and how their reservation settles. */
const TURN_SETTLEMENTS: Partial<Record<string, { outcome: TurnSettlementOutcome; reason: TurnSettlementReason }>> = {
  completed: { outcome: 'consumed', reason: 'succeeded' },
  failed: { outcome: 'released', reason: 'failed' },
  cancelled: { outcome: 'released', reason: 'cancelled' },
  interrupted: { outcome: 'released', reason: 'failed' }
};

export interface V2MessageRecord {
  messageId: string;
  researchId: string;
  turnId: string;
  role: 'user' | 'assistant' | 'system_summary';
  markdown: string;
  createdAt: string;
}

export interface V2EventRecord {
  eventId: number;
  researchId: string;
  turnId: string;
  type: string;
  sequence: number;
  payload: unknown;
  occurredAt: string;
}

export interface V2ArtifactRecord {
  artifactId: string;
  researchId: string;
  kind: string;
  status: ArtifactStatus;
  relativePath: string;
  mediaType: string;
  bytes: number;
  sha256: string;
  producer: string;
  evidenceLevel: string;
  sourceReference: unknown;
  createdAt: string;
  updatedAt: string;
}

export interface V2GrantRecord {
  researchId: string;
  alias: string;
  permission: 'read' | 'read_write';
  allowedExtensions: string[];
  maxFileBytes: number;
  status: string;
  grantedAt: string;
}

export interface V2TranscriptJobRecord {
  transcriptJobId: string;
  researchId: string;
  sourceId: string;
  contentKey: string;
  v10JobId: string | null;
  status: TranscriptJobStatus;
  installStatus: string;
  progress: number;
  artifactId: string | null;
  error: unknown;
  confirmationTokenHash: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface V2CitationRecord {
  citationId: string;
  researchId: string;
  messageId: string | null;
  artifactId: string;
  evidenceLevel: string;
  label: string;
  passageId: string | null;
  startMs: number | null;
  endMs: number | null;
  sourceUrl: string | null;
  contentKey: string | null;
  quote: string;
  sha256: string;
}

export interface V2MemoryEntryRecord {
  memoryEntryId: string;
  researchId: string | null;
  sourceResearchId: string | null;
  scope: 'research' | 'global';
  type: string;
  content: string;
  status: string;
  sourceArtifactId: string | null;
  hypothesis: boolean;
  createdAt: string;
  confirmedAt: string | null;
  /** Owning account (V18); derived from the research when omitted. */
  ownerScope?: string | null;
}

export interface V2MemoryProposalRecord {
  proposalId: string;
  researchId: string;
  content: string;
  reason: string;
  status: MemoryProposalStatus;
  createdAt: string;
  expiresAt: string;
  confirmedAt: string | null;
  rejectedAt: string | null;
  memoryEntryId: string | null;
}

export interface V2OperationRecord {
  operationId: string;
  researchId: string;
  artifactId: string | null;
  tempName: string;
  targetRelativePath: string;
  expectedSha256: string | null;
  stage: OperationStage;
  errorCode: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface V2PassageRecord {
  passageId: string;
  researchId: string;
  artifactId: string;
  ordinal: number;
  text: string;
  startMs: number | null;
  endMs: number | null;
  createdAt: string;
}

function str(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

function json(value: unknown): unknown {
  if (typeof value !== 'string' || value.length === 0) return null;
  return JSON.parse(value);
}

export function v2RequestHash(payload: unknown): string {
  return createHash('sha256').update(JSON.stringify(payload)).digest('hex');
}

export class V2Store {
  constructor(private readonly db: DatabaseSync) {}

  close(): void {
    this.db.close();
  }

  getDb(): DatabaseSync {
    return this.db;
  }

  createResearch(record: V2ResearchRecord, workspace: V2WorkspaceRecord, grants: V2GrantRecord[] = []): V2ResearchRecord {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      this.db
        .prepare(
          `INSERT INTO v2_researches (research_id, owner_scope, title, status, workspace_status, output_language,
            storefront, target_language, translation_quality, active_turn_id, created_at, updated_at, deleted_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
        )
        .run(
          record.researchId,
          record.ownerScope,
          record.title,
          record.status,
          record.workspaceStatus,
          record.outputLanguage,
          record.storefront,
          record.targetLanguage,
          record.translationQuality,
          record.activeTurnId,
          record.createdAt,
          record.updatedAt,
          record.deletedAt
        );
      this.db
        .prepare(
          `INSERT INTO v2_workspaces (research_id, directory_id, manifest_version, manifest_sha256, integrity_status,
            last_recovered_at, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
        )
        .run(
          workspace.researchId,
          workspace.directoryId,
          workspace.manifestVersion,
          workspace.manifestSha256,
          workspace.integrityStatus,
          workspace.lastRecoveredAt,
          workspace.createdAt,
          workspace.updatedAt
        );
      const grantStmt = this.db.prepare(
        `INSERT INTO v2_workspace_grants (research_id, alias, permission, allowed_extensions_json, max_file_bytes, status, granted_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      );
      for (const grant of grants) {
        grantStmt.run(
          grant.researchId,
          grant.alias,
          grant.permission,
          JSON.stringify(grant.allowedExtensions),
          grant.maxFileBytes,
          grant.status,
          grant.grantedAt
        );
      }
      this.db.exec('COMMIT');
      return record;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  getResearch(researchId: string, includeDeleted = false): V2ResearchRecord | null {
    const row = this.db
      .prepare(
        includeDeleted
          ? 'SELECT * FROM v2_researches WHERE research_id = ?'
          : `SELECT * FROM v2_researches WHERE research_id = ? AND status NOT IN ('deleted') AND deleted_at IS NULL`
      )
      .get(researchId) as Record<string, unknown> | undefined;
    return row ? mapResearch(row) : null;
  }

  listResearches(
    ownerScope: string,
    limit: number,
    cursor: { updatedAt: string; researchId: string } | null
  ): V2ResearchRecord[] {
    const rows = (
      cursor
        ? this.db
            .prepare(
              `SELECT * FROM v2_researches
               WHERE owner_scope = ? AND status NOT IN ('deleted', 'creating') AND deleted_at IS NULL
               AND (updated_at < ? OR (updated_at = ? AND research_id < ?))
               ORDER BY updated_at DESC, research_id DESC LIMIT ?`
            )
            .all(ownerScope, cursor.updatedAt, cursor.updatedAt, cursor.researchId, limit)
        : this.db
            .prepare(
              `SELECT * FROM v2_researches
               WHERE owner_scope = ? AND status NOT IN ('deleted', 'creating') AND deleted_at IS NULL
               ORDER BY updated_at DESC, research_id DESC LIMIT ?`
            )
            .all(ownerScope, limit)
    ) as Array<Record<string, unknown>>;
    return rows.map(mapResearch);
  }

  setResearchStatus(researchId: string, from: ResearchStatus, to: ResearchStatus, updatedAt = nowIso()): void {
    assertResearchTransition(from, to);
    const result = this.db
      .prepare(
        `UPDATE v2_researches SET status = ?, workspace_status = ?, updated_at = ?,
           deleted_at = CASE WHEN ? IN ('deleting', 'deleted') THEN COALESCE(deleted_at, ?) ELSE deleted_at END
         WHERE research_id = ? AND status = ?`
      )
      .run(to, to, updatedAt, to, updatedAt, researchId, from);
    if (result.changes !== 1) {
      throw new DomainError('INVALID_RESEARCH_STATUS', 'research status changed concurrently', true, 409);
    }
  }

  getWorkspace(researchId: string): V2WorkspaceRecord | null {
    const row = this.db.prepare('SELECT * FROM v2_workspaces WHERE research_id = ?').get(researchId) as
      | Record<string, unknown>
      | undefined;
    return row ? mapWorkspace(row) : null;
  }

  updateResearchTitleIf(researchId: string, title: string, allowedCurrent: readonly string[]): boolean {
    if (!allowedCurrent.length) return false;
    const placeholders = allowedCurrent.map(() => '?').join(',');
    const result = this.db
      .prepare(
        `UPDATE v2_researches SET title = ?, updated_at = ?
         WHERE research_id = ? AND deleted_at IS NULL AND title IN (${placeholders})`
      )
      .run(title, nowIso(), researchId, ...allowedCurrent);
    return result.changes === 1;
  }

  setActiveTurn(researchId: string, turnId: string | null): void {
    this.db
      .prepare('UPDATE v2_researches SET active_turn_id = ?, updated_at = ? WHERE research_id = ?')
      .run(turnId, nowIso(), researchId);
  }

  insertTurn(record: V2TurnRecord): V2TurnRecord {
    this.db
      .prepare(
        `INSERT INTO v2_turns (turn_id, research_id, mode, status, user_text, skill_name, skill_version, skill_sha256,
          error_code, error_message, created_at, started_at, finished_at, operation_key, reservation_id)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        record.turnId,
        record.researchId,
        record.mode,
        record.status,
        record.userText,
        record.skillName,
        record.skillVersion,
        record.skillSha256,
        record.errorCode,
        record.errorMessage,
        record.createdAt,
        record.startedAt,
        record.finishedAt,
        record.operationKey ?? null,
        record.reservationId ?? null
      );
    return record;
  }

  getTurn(turnId: string): V2TurnRecord | null {
    const row = this.db.prepare('SELECT * FROM v2_turns WHERE turn_id = ?').get(turnId) as
      | Record<string, unknown>
      | undefined;
    return row ? mapTurn(row) : null;
  }

  activeTurn(researchId: string): V2TurnRecord | null {
    const row = this.db
      .prepare(
        `SELECT * FROM v2_turns WHERE research_id = ? AND status IN ('queued', 'running')
         ORDER BY created_at DESC LIMIT 1`
      )
      .get(researchId) as Record<string, unknown> | undefined;
    return row ? mapTurn(row) : null;
  }

  setTurnStatus(turnId: string, from: V2TurnStatus, to: V2TurnStatus, extra: { errorCode?: string; errorMessage?: string } = {}): void {
    assertTurnTransition(from, to);
    const now = nowIso();
    const startedAt = to === 'running' ? now : null;
    const finishedAt = ['completed', 'failed', 'cancelled', 'interrupted'].includes(to) ? now : null;
    const result = this.db
      .prepare(
        `UPDATE v2_turns SET status = ?, error_code = COALESCE(?, error_code), error_message = COALESCE(?, error_message),
          started_at = COALESCE(started_at, ?), finished_at = COALESCE(?, finished_at)
         WHERE turn_id = ? AND status = ?`
      )
      .run(to, extra.errorCode ?? null, extra.errorMessage ?? null, startedAt, finishedAt, turnId, from);
    if (result.changes !== 1) {
      throw new DomainError('INVALID_RESEARCH_STATUS', 'turn status changed concurrently', true, 409);
    }
    this.enqueueTurnSettlement(turnId, to);
  }

  /** Oldest queued turns first, with their owning account (turn scheduler input). */
  listQueuedTurns(limit: number): Array<{ turnId: string; ownerScope: string }> {
    const rows = this.db
      .prepare(
        `SELECT t.turn_id, r.owner_scope FROM v2_turns t JOIN v2_researches r ON r.research_id = t.research_id
          WHERE t.status = 'queued' ORDER BY t.created_at ASC, t.turn_id ASC LIMIT ?`
      )
      .all(limit) as Array<{ turn_id: string; owner_scope: string }>;
    return rows.map((row) => ({ turnId: row.turn_id, ownerScope: row.owner_scope }));
  }

  private enqueueTurnSettlement(turnId: string, status: string): void {
    const settlement = TURN_SETTLEMENTS[status];
    if (!settlement) return;
    const row = this.db.prepare('SELECT reservation_id FROM v2_turns WHERE turn_id = ?').get(turnId) as
      | { reservation_id: string | null }
      | undefined;
    if (row?.reservation_id) this.enqueueSettlement(row.reservation_id, settlement.outcome, settlement.reason, turnId);
  }

  /** Re-creates settlements lost between a terminal status update and its outbox insert. */
  repairMissingSettlements(): number {
    const rows = this.db
      .prepare(
        `SELECT t.turn_id, t.status FROM v2_turns t
           LEFT JOIN quota_settlement_outbox o ON o.reservation_id = t.reservation_id
          WHERE t.reservation_id IS NOT NULL AND o.reservation_id IS NULL
            AND t.status IN ('completed', 'failed', 'cancelled', 'interrupted')`
      )
      .all() as Array<{ turn_id: string; status: string }>;
    for (const row of rows) this.enqueueTurnSettlement(row.turn_id, row.status);
    return rows.length;
  }

  enqueueSettlement(
    reservationId: string,
    outcome: TurnSettlementOutcome,
    reason: TurnSettlementReason,
    turnId: string | null,
    now = Date.now()
  ): void {
    this.db
      .prepare(
        `INSERT OR IGNORE INTO quota_settlement_outbox (reservation_id, outcome, reason, turn_id, created_at)
         VALUES (?, ?, ?, ?, ?)`
      )
      .run(reservationId, outcome, reason, turnId, now);
  }

  pendingSettlements(limit: number): TurnSettlementRow[] {
    const rows = this.db
      .prepare('SELECT * FROM quota_settlement_outbox WHERE delivered_at IS NULL ORDER BY created_at ASC LIMIT ?')
      .all(limit) as Array<Record<string, unknown>>;
    return rows.map(mapSettlement);
  }

  settlementFor(reservationId: string): TurnSettlementRow | null {
    const row = this.db.prepare('SELECT * FROM quota_settlement_outbox WHERE reservation_id = ?').get(reservationId) as
      | Record<string, unknown>
      | undefined;
    return row ? mapSettlement(row) : null;
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

  recordQuotaIntent(operationKey: string, ownerScope: string, turnId: string, amount: number, now = Date.now()): void {
    this.db
      .prepare(
        `INSERT INTO quota_intents (operation_key, owner_scope, turn_id, amount, created_at) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT (operation_key) DO UPDATE SET turn_id = excluded.turn_id, amount = excluded.amount, created_at = excluded.created_at`
      )
      .run(operationKey, ownerScope, turnId, amount, now);
  }

  deleteQuotaIntent(operationKey: string): void {
    this.db.prepare('DELETE FROM quota_intents WHERE operation_key = ?').run(operationKey);
  }

  listQuotaIntents(createdBefore: number): Array<{ operationKey: string; ownerScope: string; turnId: string; amount: number }> {
    const rows = this.db
      .prepare('SELECT * FROM quota_intents WHERE created_at <= ? ORDER BY created_at ASC')
      .all(createdBefore) as Array<Record<string, unknown>>;
    return rows.map((row) => ({
      operationKey: String(row.operation_key),
      ownerScope: String(row.owner_scope),
      turnId: String(row.turn_id),
      amount: Number(row.amount)
    }));
  }

  insertMessage(record: V2MessageRecord): V2MessageRecord {
    this.db
      .prepare(
        `INSERT INTO v2_messages (message_id, research_id, turn_id, role, markdown, created_at)
         VALUES (?, ?, ?, ?, ?, ?)`
      )
      .run(record.messageId, record.researchId, record.turnId, record.role, record.markdown, record.createdAt);
    return record;
  }

  listMessages(researchId: string): V2MessageRecord[] {
    const rows = this.db
      .prepare('SELECT * FROM v2_messages WHERE research_id = ? ORDER BY created_at ASC')
      .all(researchId) as Array<Record<string, unknown>>;
    return rows.map(mapMessage);
  }

  appendEvent(record: Omit<V2EventRecord, 'eventId'>): V2EventRecord {
    const result = this.db
      .prepare(
        `INSERT INTO v2_events (research_id, turn_id, type, sequence, payload_json, occurred_at)
         VALUES (?, ?, ?, ?, ?, ?)`
      )
      .run(
        record.researchId,
        record.turnId,
        record.type,
        record.sequence,
        JSON.stringify(record.payload ?? {}),
        record.occurredAt
      );
    return { ...record, eventId: Number(result.lastInsertRowid) };
  }

  eventsSince(turnId: string, afterEventId: number): V2EventRecord[] {
    const rows = this.db
      .prepare('SELECT * FROM v2_events WHERE turn_id = ? AND event_id > ? ORDER BY event_id ASC')
      .all(turnId, afterEventId) as Array<Record<string, unknown>>;
    return rows.map(mapEvent);
  }

  listEvents(researchId: string): V2EventRecord[] {
    const rows = this.db
      .prepare('SELECT * FROM v2_events WHERE research_id = ? ORDER BY event_id ASC')
      .all(researchId) as Array<Record<string, unknown>>;
    return rows.map(mapEvent);
  }

  listTurns(researchId: string): V2TurnRecord[] {
    const rows = this.db
      .prepare('SELECT * FROM v2_turns WHERE research_id = ? ORDER BY created_at ASC')
      .all(researchId) as Array<Record<string, unknown>>;
    return rows.map(mapTurn);
  }

  insertArtifact(record: V2ArtifactRecord): V2ArtifactRecord {
    this.db
      .prepare(
        `INSERT INTO v2_artifacts (artifact_id, research_id, kind, status, relative_path, media_type, bytes, sha256,
          producer, evidence_level, source_reference_json, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        record.artifactId,
        record.researchId,
        record.kind,
        record.status,
        record.relativePath,
        record.mediaType,
        record.bytes,
        record.sha256,
        record.producer,
        record.evidenceLevel,
        record.sourceReference == null ? null : JSON.stringify(record.sourceReference),
        record.createdAt,
        record.updatedAt
      );
    return record;
  }

  getArtifact(researchId: string, artifactId: string): V2ArtifactRecord | null {
    const row = this.db
      .prepare('SELECT * FROM v2_artifacts WHERE research_id = ? AND artifact_id = ?')
      .get(researchId, artifactId) as Record<string, unknown> | undefined;
    return row ? mapArtifact(row) : null;
  }

  setArtifactStatus(artifactId: string, from: ArtifactStatus, to: ArtifactStatus): void {
    assertArtifactTransition(from, to);
    const result = this.db
      .prepare('UPDATE v2_artifacts SET status = ?, updated_at = ? WHERE artifact_id = ? AND status = ?')
      .run(to, nowIso(), artifactId, from);
    if (result.changes !== 1) {
      throw new DomainError('ARTIFACT_WRITE_FAILED', 'artifact status changed concurrently', true, 409);
    }
  }

  listArtifacts(researchId: string, kind?: string, status?: string): V2ArtifactRecord[] {
    const rows = (
      kind && status
        ? this.db
            .prepare(
              'SELECT * FROM v2_artifacts WHERE research_id = ? AND kind = ? AND status = ? ORDER BY created_at DESC'
            )
            .all(researchId, kind, status)
        : kind
          ? this.db
              .prepare('SELECT * FROM v2_artifacts WHERE research_id = ? AND kind = ? ORDER BY created_at DESC')
              .all(researchId, kind)
          : this.db
              .prepare('SELECT * FROM v2_artifacts WHERE research_id = ? ORDER BY created_at DESC')
              .all(researchId)
    ) as Array<Record<string, unknown>>;
    return rows.map(mapArtifact);
  }

  listGrants(researchId: string): V2GrantRecord[] {
    const rows = this.db
      .prepare('SELECT * FROM v2_workspace_grants WHERE research_id = ?')
      .all(researchId) as Array<Record<string, unknown>>;
    return rows.map(mapGrant);
  }

  insertTranscriptJob(record: V2TranscriptJobRecord): V2TranscriptJobRecord {
    this.db
      .prepare(
        `INSERT INTO v2_transcript_jobs (transcript_job_id, research_id, source_id, content_key, v10_job_id, status,
          install_status, progress, artifact_id, error_json, confirmation_token_hash, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        record.transcriptJobId,
        record.researchId,
        record.sourceId,
        record.contentKey,
        record.v10JobId,
        record.status,
        record.installStatus,
        record.progress,
        record.artifactId,
        record.error == null ? null : JSON.stringify(record.error),
        record.confirmationTokenHash,
        record.createdAt,
        record.updatedAt
      );
    return record;
  }

  getTranscriptJob(researchId: string, transcriptJobId: string): V2TranscriptJobRecord | null {
    const row = this.db
      .prepare('SELECT * FROM v2_transcript_jobs WHERE research_id = ? AND transcript_job_id = ?')
      .get(researchId, transcriptJobId) as Record<string, unknown> | undefined;
    return row ? mapTranscriptJob(row) : null;
  }

  findTranscriptJobBySource(researchId: string, sourceId: string, contentKey: string): V2TranscriptJobRecord | null {
    const row = this.db
      .prepare('SELECT * FROM v2_transcript_jobs WHERE research_id = ? AND source_id = ? AND content_key = ?')
      .get(researchId, sourceId, contentKey) as Record<string, unknown> | undefined;
    return row ? mapTranscriptJob(row) : null;
  }

  findTranscriptJobByV10(researchId: string, v10JobId: string): V2TranscriptJobRecord | null {
    const row = this.db
      .prepare('SELECT * FROM v2_transcript_jobs WHERE research_id = ? AND v10_job_id = ? ORDER BY created_at DESC')
      .get(researchId, v10JobId) as Record<string, unknown> | undefined;
    return row ? mapTranscriptJob(row) : null;
  }

  listTranscriptJobs(researchId: string): V2TranscriptJobRecord[] {
    const rows = this.db
      .prepare('SELECT * FROM v2_transcript_jobs WHERE research_id = ? ORDER BY created_at ASC')
      .all(researchId) as Array<Record<string, unknown>>;
    return rows.map(mapTranscriptJob);
  }

  transcriptProgressUpdatedAt(transcriptJobId: string): string | null {
    const row = this.db.prepare('SELECT progress_updated_at FROM v2_transcript_jobs WHERE transcript_job_id = ?')
      .get(transcriptJobId) as { progress_updated_at: string | null } | undefined;
    return row?.progress_updated_at ?? null;
  }

  saveTranscriptRequest(transcriptJobId: string, request: unknown): void {
    this.db.prepare('UPDATE v2_transcript_jobs SET request_json = ? WHERE transcript_job_id = ?')
      .run(JSON.stringify(request), transcriptJobId);
  }

  transcriptRequest(transcriptJobId: string): unknown {
    const row = this.db.prepare('SELECT request_json FROM v2_transcript_jobs WHERE transcript_job_id = ?')
      .get(transcriptJobId) as { request_json: string | null } | undefined;
    return row?.request_json ? JSON.parse(row.request_json) : null;
  }

  recoverableTranscriptJobs(): V2TranscriptJobRecord[] {
    const rows = this.db.prepare(`SELECT j.* FROM v2_transcript_jobs j
      JOIN v2_researches r ON r.research_id = j.research_id
      WHERE r.status NOT IN ('deleted', 'deleting', 'creating')
      AND (j.request_json IS NOT NULL OR j.v10_job_id IS NOT NULL)
      AND (j.status IN ('requested', 'waiting_service', 'running', 'installing')
        OR (j.status = 'failed_retryable' AND json_extract(j.error_json, '$.message') = 'V10 poll timed out'))
      ORDER BY j.updated_at ASC`).all() as Array<Record<string, unknown>>;
    return rows.map(mapTranscriptJob);
  }

  setTranscriptJobStatus(transcriptJobId: string, from: TranscriptJobStatus, to: TranscriptJobStatus): void {
    if (!canTranscriptJobTransition(from, to)) {
      throw new DomainError('INVALID_RESEARCH_STATUS', `cannot move transcript job from ${from} to ${to}`, false, 409);
    }
    const result = this.db
      .prepare('UPDATE v2_transcript_jobs SET status = ?, install_status = ?, updated_at = ? WHERE transcript_job_id = ? AND status = ?')
      .run(to, to, nowIso(), transcriptJobId, from);
    if (result.changes !== 1) {
      throw new DomainError('INVALID_RESEARCH_STATUS', 'transcript job status changed concurrently', true, 409);
    }
  }

  patchTranscriptJob(
    transcriptJobId: string,
    patch: {
      v10JobId?: string | null;
      artifactId?: string | null;
      progress?: number;
      error?: unknown;
      confirmationTokenHash?: string | null;
      installStatus?: string;
    }
  ): void {
    const current = this.db
      .prepare('SELECT * FROM v2_transcript_jobs WHERE transcript_job_id = ?')
      .get(transcriptJobId) as Record<string, unknown> | undefined;
    if (!current) {
      throw new DomainError('TRANSCRIPT_JOB_NOT_FOUND', 'transcript job is missing', false, 404);
    }
    if (patch.progress !== undefined && (patch.progress !== Number(current.progress) || !current.progress_updated_at)) {
      this.db.prepare('UPDATE v2_transcript_jobs SET progress_updated_at = ? WHERE transcript_job_id = ?')
        .run(nowIso(), transcriptJobId);
    }
    const errorJson =
      patch.error === undefined
        ? (typeof current.error_json === 'string' ? current.error_json : null)
        : patch.error == null
          ? null
          : JSON.stringify(patch.error);
    this.db
      .prepare(
        `UPDATE v2_transcript_jobs SET v10_job_id = ?, artifact_id = ?, progress = ?, error_json = ?,
          confirmation_token_hash = ?, install_status = ?, updated_at = ? WHERE transcript_job_id = ?`
      )
      .run(
        patch.v10JobId === undefined ? (current.v10_job_id as string | null) : patch.v10JobId,
        patch.artifactId === undefined ? (current.artifact_id as string | null) : patch.artifactId,
        patch.progress === undefined ? Number(current.progress) : patch.progress,
        errorJson,
        patch.confirmationTokenHash === undefined
          ? (current.confirmation_token_hash as string | null)
          : patch.confirmationTokenHash,
        patch.installStatus === undefined ? String(current.install_status) : patch.installStatus,
        nowIso(),
        transcriptJobId
      );
  }

  insertCitation(record: V2CitationRecord): V2CitationRecord {
    this.db
      .prepare(
        `INSERT INTO v2_citations (citation_id, research_id, message_id, artifact_id, evidence_level, label, passage_id,
          start_ms, end_ms, source_url, content_key, quote, sha256)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        record.citationId,
        record.researchId,
        record.messageId,
        record.artifactId,
        record.evidenceLevel,
        record.label,
        record.passageId,
        record.startMs,
        record.endMs,
        record.sourceUrl,
        record.contentKey,
        record.quote,
        record.sha256
      );
    return record;
  }

  listCitations(researchId: string, messageId?: string | null): V2CitationRecord[] {
    const rows = (
      messageId
        ? this.db
            .prepare('SELECT * FROM v2_citations WHERE research_id = ? AND message_id = ? ORDER BY citation_id ASC')
            .all(researchId, messageId)
        : this.db
            .prepare('SELECT * FROM v2_citations WHERE research_id = ? ORDER BY citation_id ASC')
            .all(researchId)
    ) as Array<Record<string, unknown>>;
    return rows.map(mapCitation);
  }

  nextEventSequence(turnId: string): number {
    const row = this.db.prepare('SELECT COALESCE(MAX(sequence), 0) AS max_seq FROM v2_events WHERE turn_id = ?').get(turnId) as {
      max_seq: number;
    };
    return Number(row.max_seq) + 1;
  }

  insertMemoryEntry(record: V2MemoryEntryRecord): V2MemoryEntryRecord {
    this.db
      .prepare(
        `INSERT INTO v2_memory_entries (memory_entry_id, research_id, source_research_id, scope, type, content, status,
          source_artifact_id, hypothesis, created_at, confirmed_at, owner_scope)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
           COALESCE(?, (SELECT owner_scope FROM v2_researches WHERE research_id = COALESCE(?, ?)), 'selfhost'))`
      )
      .run(
        record.memoryEntryId,
        record.researchId,
        record.sourceResearchId,
        record.scope,
        record.type,
        record.content,
        record.status,
        record.sourceArtifactId,
        record.hypothesis ? 1 : 0,
        record.createdAt,
        record.confirmedAt,
        record.ownerScope ?? null,
        record.researchId,
        record.sourceResearchId
      );
    return record;
  }

  listMemoryEntries(researchId: string): V2MemoryEntryRecord[] {
    const rows = this.db
      .prepare(`SELECT * FROM v2_memory_entries WHERE research_id = ? AND scope = 'research'`)
      .all(researchId) as Array<Record<string, unknown>>;
    return rows.map(mapMemoryEntry);
  }

  /** Confirmed preferences of one account; "global" never crosses accounts. */
  listConfirmedGlobalMemory(ownerScope: string): V2MemoryEntryRecord[] {
    const rows = this.db
      .prepare(`SELECT * FROM v2_memory_entries WHERE scope = 'global' AND status = 'confirmed' AND owner_scope = ?`)
      .all(ownerScope) as Array<Record<string, unknown>>;
    return rows.map(mapMemoryEntry);
  }

  getMemoryEntry(memoryEntryId: string): V2MemoryEntryRecord | null {
    const row = this.db.prepare('SELECT * FROM v2_memory_entries WHERE memory_entry_id = ?').get(memoryEntryId) as
      | Record<string, unknown>
      | undefined;
    return row ? mapMemoryEntry(row) : null;
  }

  listMemoryProposals(researchId: string): V2MemoryProposalRecord[] {
    const rows = this.db
      .prepare('SELECT * FROM v2_memory_proposals WHERE research_id = ? ORDER BY created_at ASC')
      .all(researchId) as Array<Record<string, unknown>>;
    return rows.map(mapProposal);
  }

  replaceResearchMemoryEntries(researchId: string, entries: V2MemoryEntryRecord[]): void {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      this.db.prepare(`DELETE FROM v2_memory_entries WHERE research_id = ? AND scope = 'research'`).run(researchId);
      const stmt = this.db.prepare(
        `INSERT INTO v2_memory_entries (memory_entry_id, research_id, source_research_id, scope, type, content, status,
          source_artifact_id, hypothesis, created_at, confirmed_at, owner_scope)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
           COALESCE(?, (SELECT owner_scope FROM v2_researches WHERE research_id = COALESCE(?, ?)), 'selfhost'))`
      );
      for (const record of entries) {
        stmt.run(
          record.memoryEntryId,
          record.researchId,
          record.sourceResearchId,
          record.scope,
          record.type,
          record.content,
          record.status,
          record.sourceArtifactId,
          record.hypothesis ? 1 : 0,
          record.createdAt,
          record.confirmedAt,
          record.ownerScope ?? null,
          record.researchId,
          record.sourceResearchId
        );
      }
      this.db.exec('COMMIT');
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  setMemoryEntryStatus(memoryEntryId: string, from: string, to: string): void {
    const now = nowIso();
    const result = this.db
      .prepare(
        `UPDATE v2_memory_entries SET status = ?, confirmed_at = CASE WHEN ? = 'confirmed' THEN ? ELSE confirmed_at END
         WHERE memory_entry_id = ? AND status = ?`
      )
      .run(to, to, now, memoryEntryId, from);
    if (result.changes !== 1) {
      throw new DomainError('MEMORY_PROPOSAL_ALREADY_RESOLVED', 'memory entry status changed concurrently', true, 409);
    }
  }

  insertMemoryProposal(record: V2MemoryProposalRecord): V2MemoryProposalRecord {
    this.db
      .prepare(
        `INSERT INTO v2_memory_proposals (proposal_id, research_id, content, reason, status, created_at, expires_at,
          confirmed_at, rejected_at, memory_entry_id)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        record.proposalId,
        record.researchId,
        record.content,
        record.reason,
        record.status,
        record.createdAt,
        record.expiresAt,
        record.confirmedAt,
        record.rejectedAt,
        record.memoryEntryId
      );
    return record;
  }

  getMemoryProposal(proposalId: string): V2MemoryProposalRecord | null {
    const row = this.db.prepare('SELECT * FROM v2_memory_proposals WHERE proposal_id = ?').get(proposalId) as
      | Record<string, unknown>
      | undefined;
    return row ? mapProposal(row) : null;
  }

  setMemoryProposalStatus(proposalId: string, from: MemoryProposalStatus, to: MemoryProposalStatus, memoryEntryId?: string): void {
    if (!canMemoryProposalTransition(from, to)) {
      throw new DomainError('MEMORY_PROPOSAL_ALREADY_RESOLVED', `cannot move proposal from ${from} to ${to}`, false, 409);
    }
    const now = nowIso();
    const result = this.db
      .prepare(
        `UPDATE v2_memory_proposals SET status = ?, confirmed_at = CASE WHEN ? = 'confirmed' THEN ? ELSE confirmed_at END,
          rejected_at = CASE WHEN ? = 'rejected' THEN ? ELSE rejected_at END,
          memory_entry_id = COALESCE(?, memory_entry_id)
         WHERE proposal_id = ? AND status = ?`
      )
      .run(to, to, now, to, now, memoryEntryId ?? null, proposalId, from);
    if (result.changes !== 1) {
      throw new DomainError('MEMORY_PROPOSAL_ALREADY_RESOLVED', 'proposal status changed concurrently', true, 409);
    }
  }

  insertOperation(record: V2OperationRecord): V2OperationRecord {
    this.db
      .prepare(
        `INSERT INTO v2_workspace_operations (operation_id, research_id, artifact_id, temp_name, target_relative_path,
          expected_sha256, stage, error_code, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        record.operationId,
        record.researchId,
        record.artifactId,
        record.tempName,
        record.targetRelativePath,
        record.expectedSha256,
        record.stage,
        record.errorCode,
        record.createdAt,
        record.updatedAt
      );
    return record;
  }

  listOperationsByStage(stage: OperationStage): V2OperationRecord[] {
    const rows = this.db
      .prepare('SELECT * FROM v2_workspace_operations WHERE stage = ? ORDER BY created_at ASC')
      .all(stage) as Array<Record<string, unknown>>;
    return rows.map(mapOperation);
  }

  setOperationStage(operationId: string, stage: OperationStage, errorCode: string | null = null): void {
    this.db
      .prepare('UPDATE v2_workspace_operations SET stage = ?, error_code = ?, updated_at = ? WHERE operation_id = ?')
      .run(stage, errorCode, nowIso(), operationId);
  }

  insertPassage(record: V2PassageRecord): V2PassageRecord {
    this.db
      .prepare(
        `INSERT INTO v2_passages (passage_id, research_id, artifact_id, ordinal, text, start_ms, end_ms, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        record.passageId,
        record.researchId,
        record.artifactId,
        record.ordinal,
        record.text,
        record.startMs,
        record.endMs,
        record.createdAt
      );
    return record;
  }

  searchPassages(researchId: string, query: string, limit = 20): V2PassageRecord[] {
    const rows = this.db
      .prepare(
        `SELECT p.* FROM v2_passages p
         JOIN v2_passages_fts fts ON fts.rowid = p.rowid
         JOIN v2_artifacts a ON a.artifact_id = p.artifact_id
         WHERE p.research_id = ? AND a.status = 'ready' AND v2_passages_fts MATCH ?
         LIMIT ?`
      )
      .all(researchId, query, limit) as Array<Record<string, unknown>>;
    return rows.map(mapPassage);
  }

  removePassagesForArtifact(artifactId: string): void {
    this.db.prepare('DELETE FROM v2_passages WHERE artifact_id = ?').run(artifactId);
  }

  listPassagesForArtifact(researchId: string, artifactId: string): V2PassageRecord[] {
    const rows = this.db
      .prepare('SELECT * FROM v2_passages WHERE research_id = ? AND artifact_id = ? ORDER BY ordinal ASC')
      .all(researchId, artifactId) as Array<Record<string, unknown>>;
    return rows.map(mapPassage);
  }

  getPassage(researchId: string, passageId: string): V2PassageRecord | null {
    const row = this.db
      .prepare('SELECT * FROM v2_passages WHERE research_id = ? AND passage_id = ?')
      .get(researchId, passageId) as Record<string, unknown> | undefined;
    return row ? mapPassage(row) : null;
  }

  listPassages(researchId: string): V2PassageRecord[] {
    const rows = this.db
      .prepare(
        `SELECT p.* FROM v2_passages p
         JOIN v2_artifacts a ON a.artifact_id = p.artifact_id
         WHERE p.research_id = ? AND a.status = 'ready'
         ORDER BY p.created_at ASC, p.ordinal ASC`
      )
      .all(researchId) as Array<Record<string, unknown>>;
    return rows.map(mapPassage);
  }

  getIdempotency(
    ownerScope: string,
    routeScope: string,
    key: string
  ): { hash: string; status: number; body: string } | null {
    const row = this.db
      .prepare(
        'SELECT request_hash, status, response_json FROM v2_idempotency_keys WHERE owner_scope = ? AND route_scope = ? AND key = ?'
      )
      .get(ownerScope, routeScope, key) as { request_hash: string; status: number; response_json: string } | undefined;
    return row ? { hash: row.request_hash, status: Number(row.status), body: row.response_json } : null;
  }

  putIdempotency(ownerScope: string, routeScope: string, key: string, hash: string, status: number, body: unknown): void {
    this.db
      .prepare(
        `INSERT INTO v2_idempotency_keys (owner_scope, route_scope, key, request_hash, response_json, status, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      )
      .run(ownerScope, routeScope, key, hash, JSON.stringify(body), status, nowIso());
  }

  claimTurnLease(turnId: string, workerId: string, ttlMs: number, leaseId: string): boolean {
    const now = Date.now();
    this.db.prepare('DELETE FROM v2_worker_leases WHERE expires_at <= ?').run(now);
    try {
      this.db
        .prepare('INSERT INTO v2_worker_leases (lease_id, turn_id, worker_id, expires_at) VALUES (?, ?, ?, ?)')
        .run(leaseId, turnId, workerId, now + ttlMs);
      return true;
    } catch {
      return false;
    }
  }

  releaseTurnLease(turnId: string, workerId: string): void {
    this.db.prepare('DELETE FROM v2_worker_leases WHERE turn_id = ? AND worker_id = ?').run(turnId, workerId);
  }

  listExpiredLeases(now = Date.now()): Array<{ leaseId: string; turnId: string; workerId: string }> {
    return this.db
      .prepare('SELECT lease_id AS leaseId, turn_id AS turnId, worker_id AS workerId FROM v2_worker_leases WHERE expires_at <= ?')
      .all(now) as Array<{ leaseId: string; turnId: string; workerId: string }>;
  }

  markDeleting(researchId: string): V2ResearchRecord | null {
    const research = this.getResearch(researchId, true);
    if (!research) return null;
    if (research.status === 'deleted' || research.status === 'deleting') return research;
    this.setResearchStatus(researchId, research.status, 'deleting');
    return this.getResearch(researchId, true);
  }

  /** Every research of one account, in any status. */
  researchIdsForOwner(ownerScope: string): string[] {
    const rows = this.db.prepare('SELECT research_id FROM v2_researches WHERE owner_scope = ?').all(ownerScope) as Array<{
      research_id: string;
    }>;
    return rows.map((row) => row.research_id);
  }

  /**
   * Removes every V2 row of one account in one transaction (account deletion).
   * Children are deleted before parents to satisfy foreign keys.
   */
  purgeOwnerRows(ownerScope: string): number {
    const owned = 'SELECT research_id FROM v2_researches WHERE owner_scope = ?';
    const statements = [
      `DELETE FROM v2_worker_leases WHERE turn_id IN (SELECT turn_id FROM v2_turns WHERE research_id IN (${owned}))`,
      `DELETE FROM v2_passages WHERE research_id IN (${owned})`,
      `DELETE FROM v2_workspace_operations WHERE research_id IN (${owned})`,
      `DELETE FROM v2_citations WHERE research_id IN (${owned})`,
      `DELETE FROM v2_memory_proposals WHERE research_id IN (${owned})`,
      `DELETE FROM v2_memory_entries WHERE owner_scope = ? OR research_id IN (${owned})`,
      `DELETE FROM v2_transcript_jobs WHERE research_id IN (${owned})`,
      `DELETE FROM v2_workspace_grants WHERE research_id IN (${owned})`,
      `DELETE FROM v2_events WHERE research_id IN (${owned})`,
      `DELETE FROM v2_messages WHERE research_id IN (${owned})`,
      `DELETE FROM v2_artifacts WHERE research_id IN (${owned})`,
      `DELETE FROM quota_settlement_outbox WHERE turn_id IN (SELECT turn_id FROM v2_turns WHERE research_id IN (${owned}))`,
      'DELETE FROM quota_intents WHERE owner_scope = ?',
      `DELETE FROM v2_turns WHERE research_id IN (${owned})`,
      `DELETE FROM v2_workspaces WHERE research_id IN (${owned})`,
      'DELETE FROM v2_researches WHERE owner_scope = ?',
      'DELETE FROM v2_idempotency_keys WHERE owner_scope = ?'
    ];
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const count = this.researchIdsForOwner(ownerScope).length;
      for (const sql of statements) {
        const params = Array.from({ length: (sql.match(/\?/g) ?? []).length }, () => ownerScope);
        this.db.prepare(sql).run(...params);
      }
      this.db.exec('COMMIT');
      return count;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  finalizeDeleted(researchId: string): void {
    const research = this.getResearch(researchId, true);
    if (!research) return;
    if (research.status !== 'deleting') {
      throw new DomainError('INVALID_RESEARCH_STATUS', 'research is not deleting', false, 409);
    }
    this.db.exec('BEGIN IMMEDIATE');
    try {
      this.db.prepare('DELETE FROM v2_events WHERE research_id = ?').run(researchId);
      this.db.prepare('DELETE FROM v2_citations WHERE research_id = ?').run(researchId);
      this.db.prepare('DELETE FROM v2_messages WHERE research_id = ?').run(researchId);
      this.db.prepare('DELETE FROM v2_passages WHERE research_id = ?').run(researchId);
      this.db.prepare('DELETE FROM v2_workspace_operations WHERE research_id = ?').run(researchId);
      this.db.prepare('DELETE FROM v2_transcript_jobs WHERE research_id = ?').run(researchId);
      this.db.prepare(`DELETE FROM v2_memory_proposals WHERE research_id = ? AND status = 'pending'`).run(researchId);
      this.db.prepare(`DELETE FROM v2_memory_entries WHERE research_id = ? AND scope = 'research'`).run(researchId);
      this.db.prepare('DELETE FROM v2_artifacts WHERE research_id = ?').run(researchId);
      this.db.prepare('DELETE FROM v2_workspace_grants WHERE research_id = ?').run(researchId);
      this.db.prepare('DELETE FROM v2_workspaces WHERE research_id = ?').run(researchId);
      this.db.prepare(`DELETE FROM v2_worker_leases WHERE turn_id IN (SELECT turn_id FROM v2_turns WHERE research_id = ?)`).run(
        researchId
      );
      this.db.prepare('DELETE FROM v2_turns WHERE research_id = ?').run(researchId);
      this.db
        .prepare(`UPDATE v2_researches SET status = 'deleted', workspace_status = 'deleted', updated_at = ?, deleted_at = ? WHERE research_id = ?`)
        .run(nowIso(), nowIso(), researchId);
      this.db.exec('COMMIT');
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }
}

function mapResearch(row: Record<string, unknown>): V2ResearchRecord {
  return {
    researchId: String(row.research_id),
    ownerScope: String(row.owner_scope),
    title: String(row.title),
    status: row.status as ResearchStatus,
    workspaceStatus: row.workspace_status as WorkspaceIntegrity,
    outputLanguage: String(row.output_language),
    storefront: String(row.storefront),
    targetLanguage: String(row.target_language),
    translationQuality: String(row.translation_quality),
    activeTurnId: str(row.active_turn_id),
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
    deletedAt: str(row.deleted_at)
  };
}

function mapWorkspace(row: Record<string, unknown>): V2WorkspaceRecord {
  return {
    researchId: String(row.research_id),
    directoryId: String(row.directory_id),
    manifestVersion: Number(row.manifest_version),
    manifestSha256: str(row.manifest_sha256),
    integrityStatus: row.integrity_status as WorkspaceIntegrity,
    lastRecoveredAt: str(row.last_recovered_at),
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at)
  };
}

function mapTurn(row: Record<string, unknown>): V2TurnRecord {
  return {
    turnId: String(row.turn_id),
    researchId: String(row.research_id),
    mode: row.mode as TurnMode,
    status: row.status as V2TurnStatus,
    userText: String(row.user_text),
    skillName: str(row.skill_name),
    skillVersion: str(row.skill_version),
    skillSha256: str(row.skill_sha256),
    errorCode: str(row.error_code),
    errorMessage: str(row.error_message),
    createdAt: String(row.created_at),
    startedAt: str(row.started_at),
    finishedAt: str(row.finished_at),
    operationKey: str(row.operation_key),
    reservationId: str(row.reservation_id)
  };
}

function mapSettlement(row: Record<string, unknown>): TurnSettlementRow {
  return {
    reservationId: String(row.reservation_id),
    outcome: row.outcome as TurnSettlementOutcome,
    reason: row.reason as TurnSettlementReason,
    turnId: str(row.turn_id),
    attempts: Number(row.attempts),
    deliveredAt: row.delivered_at === null || row.delivered_at === undefined ? null : Number(row.delivered_at)
  };
}

function mapMessage(row: Record<string, unknown>): V2MessageRecord {
  return {
    messageId: String(row.message_id),
    researchId: String(row.research_id),
    turnId: String(row.turn_id),
    role: row.role as V2MessageRecord['role'],
    markdown: String(row.markdown),
    createdAt: String(row.created_at)
  };
}

function mapEvent(row: Record<string, unknown>): V2EventRecord {
  return {
    eventId: Number(row.event_id),
    researchId: String(row.research_id),
    turnId: String(row.turn_id),
    type: String(row.type),
    sequence: Number(row.sequence),
    payload: json(row.payload_json) ?? {},
    occurredAt: String(row.occurred_at)
  };
}

function mapArtifact(row: Record<string, unknown>): V2ArtifactRecord {
  return {
    artifactId: String(row.artifact_id),
    researchId: String(row.research_id),
    kind: String(row.kind),
    status: row.status as ArtifactStatus,
    relativePath: String(row.relative_path),
    mediaType: String(row.media_type),
    bytes: Number(row.bytes),
    sha256: String(row.sha256),
    producer: String(row.producer),
    evidenceLevel: String(row.evidence_level),
    sourceReference: json(row.source_reference_json),
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at)
  };
}

function mapGrant(row: Record<string, unknown>): V2GrantRecord {
  return {
    researchId: String(row.research_id),
    alias: String(row.alias),
    permission: row.permission as V2GrantRecord['permission'],
    allowedExtensions: json(row.allowed_extensions_json) as string[],
    maxFileBytes: Number(row.max_file_bytes),
    status: String(row.status),
    grantedAt: String(row.granted_at)
  };
}

function mapTranscriptJob(row: Record<string, unknown>): V2TranscriptJobRecord {
  return {
    transcriptJobId: String(row.transcript_job_id),
    researchId: String(row.research_id),
    sourceId: String(row.source_id),
    contentKey: String(row.content_key),
    v10JobId: str(row.v10_job_id),
    status: row.status as TranscriptJobStatus,
    installStatus: String(row.install_status),
    progress: Number(row.progress),
    artifactId: str(row.artifact_id),
    error: json(row.error_json),
    confirmationTokenHash: str(row.confirmation_token_hash),
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at)
  };
}

function mapCitation(row: Record<string, unknown>): V2CitationRecord {
  return {
    citationId: String(row.citation_id),
    researchId: String(row.research_id),
    messageId: str(row.message_id),
    artifactId: String(row.artifact_id),
    evidenceLevel: String(row.evidence_level),
    label: String(row.label),
    passageId: str(row.passage_id),
    startMs: row.start_ms == null ? null : Number(row.start_ms),
    endMs: row.end_ms == null ? null : Number(row.end_ms),
    sourceUrl: str(row.source_url),
    contentKey: str(row.content_key),
    quote: String(row.quote),
    sha256: String(row.sha256)
  };
}

function mapMemoryEntry(row: Record<string, unknown>): V2MemoryEntryRecord {
  return {
    memoryEntryId: String(row.memory_entry_id),
    researchId: str(row.research_id),
    sourceResearchId: str(row.source_research_id),
    scope: row.scope as V2MemoryEntryRecord['scope'],
    type: String(row.type),
    content: String(row.content),
    status: String(row.status),
    sourceArtifactId: str(row.source_artifact_id),
    hypothesis: Number(row.hypothesis) === 1,
    createdAt: String(row.created_at),
    confirmedAt: str(row.confirmed_at),
    ownerScope: str(row.owner_scope)
  };
}

function mapProposal(row: Record<string, unknown>): V2MemoryProposalRecord {
  return {
    proposalId: String(row.proposal_id),
    researchId: String(row.research_id),
    content: String(row.content),
    reason: String(row.reason),
    status: row.status as MemoryProposalStatus,
    createdAt: String(row.created_at),
    expiresAt: String(row.expires_at),
    confirmedAt: str(row.confirmed_at),
    rejectedAt: str(row.rejected_at),
    memoryEntryId: str(row.memory_entry_id)
  };
}

function mapOperation(row: Record<string, unknown>): V2OperationRecord {
  return {
    operationId: String(row.operation_id),
    researchId: String(row.research_id),
    artifactId: str(row.artifact_id),
    tempName: String(row.temp_name),
    targetRelativePath: String(row.target_relative_path),
    expectedSha256: str(row.expected_sha256),
    stage: row.stage as OperationStage,
    errorCode: str(row.error_code),
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at)
  };
}

function mapPassage(row: Record<string, unknown>): V2PassageRecord {
  return {
    passageId: String(row.passage_id),
    researchId: String(row.research_id),
    artifactId: String(row.artifact_id),
    ordinal: Number(row.ordinal),
    text: String(row.text),
    startMs: row.start_ms == null ? null : Number(row.start_ms),
    endMs: row.end_ms == null ? null : Number(row.end_ms),
    createdAt: String(row.created_at)
  };
}
