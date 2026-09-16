import type { V2EventRecord, V2Store } from '../../db/v2/store.js';
import { v2RequestHash } from '../../db/v2/store.js';
import { DomainError } from '../../domain/types.js';
import { GRANT_ALIAS_PATTERN } from '../../workspace/virtual-path.js';
import type { AdminGrant } from '../../workspace/grants.js';
import type { WorkspaceGrantInput } from '../../workspace/manager.js';
import type { V2ResearchOrchestrator } from '../../research-v2/orchestrator.js';
import { newTurnId, type TurnMode } from '../../research-v2/state.js';
import { QuotaError, type QuotaClient } from '../../quota/quota-client.js';
import type { TurnScheduler } from '../../quota/turn-scheduler.js';
import { resolveTranscriptSource } from './sources.js';
import {
  decodeListCursor,
  encodeListCursor,
  projectArtifact,
  projectResearch,
  projectSnapshot,
  projectTranscriptJob,
  projectTurn,
  projectTurnAccepted,
  rejectPathQuery,
  truncateArtifactText
} from './project.js';
import { projectTurnWork } from './turn-work.js';

const EVENT_RETENTION_MS = 24 * 60 * 60 * 1000;
const RESEARCH_ID = /^[0-9A-HJKMNP-TV-Z]{26}$/;
const TURN_ID = /^vt_[0-9A-HJKMNP-TV-Z]{26}$/;
const ARTIFACT_ID = /^[0-9A-HJKMNP-TV-Z]{26}$/;
const SOURCE_ID = /^so_[0-9A-HJKMNP-TV-Z]{26}$/;
const TRANSCRIPT_JOB_ID = /^tj_[0-9A-HJKMNP-TV-Z]{26}$/;
const PROPOSAL_ID = /^mp_[0-9A-HJKMNP-TV-Z]{26}$/;

export interface V2AssistantApplicationOptions {
  store: V2Store;
  orchestrator: V2ResearchOrchestrator;
  adminGrants: AdminGrant[];
  sharedWriteEnabled: boolean;
  /** V18 WP04: present when assistant turn quota is enforced. */
  quota?: QuotaClient | null;
  /** Dispatches queued turns within per-account and global limits. */
  scheduler?: TurnScheduler;
}

export class V2AssistantApplication {
  constructor(private readonly deps: V2AssistantApplicationOptions) {}

  get store(): V2Store {
    return this.deps.store;
  }

  get orchestrator(): V2ResearchOrchestrator {
    return this.deps.orchestrator;
  }

  createResearch(owner: string, body: Record<string, unknown>, idempotencyKey: string | undefined): Record<string, unknown> {
    const key = requireIdempotency(idempotencyKey);
    const title = optionalString(body.title, 80);
    const outputLanguage = optionalString(body.outputLanguage) ?? 'zh-Hans';
    const storefront = (optionalString(body.storefront, 2) ?? 'US').toUpperCase();
    const targetLanguage = optionalString(body.targetLanguage) ?? outputLanguage;
    const translationQuality = body.translationQuality === 'fast' ? 'fast' : 'quality';
    const grants = this.grantsFromAliases(body.sharedAliases);
    const research = this.deps.orchestrator.createResearch({
      ownerScope: owner,
      title,
      outputLanguage,
      storefront,
      targetLanguage,
      translationQuality,
      grants,
      idempotencyKey: key
    });
    return this.projectResearchId(owner, research.researchId);
  }

  listResearches(owner: string, limitRaw: string | null, cursorRaw: string | null): Record<string, unknown> {
    const limit = Math.min(50, Math.max(1, Number(limitRaw ?? 20) || 20));
    const cursor = decodeListCursor(cursorRaw);
    const rows = this.deps.store.listResearches(
      owner,
      limit + 1,
      cursor ? { updatedAt: cursor.updatedAt, researchId: cursor.id } : null
    );
    const next = rows.length > limit ? rows[limit] : null;
    const page = rows.slice(0, limit);
    return {
      researches: page.map((row) => this.projectResearchId(owner, row.researchId)),
      nextCursor: next ? encodeListCursor(next.updatedAt, next.researchId) : null
    };
  }

  getSnapshot(owner: string, researchId: string): Record<string, unknown> {
    const research = this.requireOwnedResearch(owner, researchId);
    const snap = this.deps.orchestrator.snapshot(research.researchId);
    return projectSnapshot({
      research: snap.research,
      messages: snap.messages,
      artifacts: this.deps.store.listArtifacts(research.researchId),
      grants: this.deps.store.listGrants(research.researchId),
      citations: snap.citations,
      memory: snap.memory,
      activeTurn: snap.activeTurn,
      turnWork: projectTurnWork(
        this.deps.store.listEvents(research.researchId),
        this.deps.store.listTurns(research.researchId)
      )
    });
  }

  deleteResearch(
    owner: string,
    researchId: string,
    idempotencyKey: string | undefined
  ): { status: 202 | 204; body?: Record<string, unknown> } {
    const key = requireIdempotency(idempotencyKey);
    const route = `DELETE /v2/assistant/researches/${researchId}`;
    const hash = v2RequestHash({ researchId });
    const replay = this.replayIdempotency(owner, route, key, hash);
    if (replay) {
      return replay.status === 204
        ? { status: 204 }
        : { status: 202, body: replay.body as Record<string, unknown> };
    }
    const existing = this.deps.store.getResearch(researchId, true);
    if (!existing || existing.status === 'deleted') {
      this.deps.store.putIdempotency(owner, route, key, hash, 204, {});
      return { status: 204 };
    }
    this.assertOwner(owner, existing.ownerScope);
    this.deps.orchestrator.deleteResearch(researchId);
    const deleted = this.deps.store.getResearch(researchId, true);
    const body = deleted
      ? projectResearch(deleted, this.deps.store.listArtifacts(researchId), this.deps.store.listGrants(researchId))
      : projectResearch(existing, [], []);
    this.deps.store.putIdempotency(owner, route, key, hash, 202, body);
    return { status: 202, body };
  }

  async createTurn(
    owner: string,
    researchId: string,
    body: Record<string, unknown>,
    idempotencyKey: string | undefined
  ): Promise<Record<string, unknown>> {
    const key = requireIdempotency(idempotencyKey);
    this.requireOwnedResearch(owner, researchId);
    const message = typeof body.message === 'string' ? body.message.trim() : '';
    if (!message) throw new DomainError('INVALID_REQUEST', 'message is required', false, 400, { field: 'message' });
    if (message.length > 4000) {
      throw new DomainError('INVALID_REQUEST', 'message exceeds 4000 characters', false, 400, { field: 'message' });
    }
    const mode = body.mode;
    if (mode !== 'research' && mode !== 'content_qa') {
      throw new DomainError('INVALID_REQUEST', 'mode must be research or content_qa', false, 400, { field: 'mode' });
    }
    const route = `POST /v2/assistant/researches/${researchId}/turns`;
    const prior = this.deps.store.getIdempotency(owner, route, key);
    const reservation = this.deps.quota && !prior ? await this.reserveTurn(owner) : null;
    let turn;
    try {
      turn = this.deps.orchestrator.createTurn(researchId, {
        mode: mode as TurnMode,
        text: message,
        idempotencyKey: key,
        ...(reservation ?? {})
      });
    } catch (error) {
      if (reservation) {
        this.deps.store.enqueueSettlement(reservation.reservationId, 'released', 'rejected_before_start', null);
        this.deps.store.deleteQuotaIntent(reservation.operationKey);
      }
      throw error;
    }
    if (reservation) {
      this.deps.store.deleteQuotaIntent(reservation.operationKey);
      if (turn.turnId !== reservation.turnId) {
        this.deps.store.enqueueSettlement(reservation.reservationId, 'released', 'reused_artifact', turn.turnId);
      }
    }
    const reused = Boolean(prior);
    const accepted = projectTurnAccepted(turn, reused);
    if (!reused || turn.status === 'queued') this.scheduleTurn(turn.turnId);
    return accepted;
  }

  /** Reserves one assistant unit for a new turn before it is inserted (account-v1-integration §3.3). */
  private async reserveTurn(owner: string): Promise<{ turnId: string; operationKey: string; reservationId: string }> {
    const quota = this.deps.quota!;
    const turnId = newTurnId();
    const operationKey = `assistant-turn:${turnId}`;
    this.deps.store.recordQuotaIntent(operationKey, owner, turnId, 1);
    try {
      const reservation = await quota.reserve({ accountId: owner, operationKey, amount: 1, subjectRef: turnId });
      return { turnId, operationKey, reservationId: reservation.reservationId };
    } catch (error) {
      this.deps.store.deleteQuotaIntent(operationKey);
      if (error instanceof QuotaError) {
        throw new DomainError(error.code, error.message, error.retryable, error.status, error.params ?? {});
      }
      throw error;
    }
  }

  private scheduleTurn(turnId: string): void {
    if (this.deps.scheduler) {
      this.deps.scheduler.enqueue();
      return;
    }
    queueMicrotask(() => {
      this.deps.orchestrator.runTurn(turnId).catch(() => undefined);
    });
  }

  cancelTurn(owner: string, turnId: string, idempotencyKey: string | undefined): Record<string, unknown> {
    const key = requireIdempotency(idempotencyKey);
    const turn = this.requireOwnedTurn(owner, turnId);
    const route = `POST /v2/assistant/turns/${turnId}/cancel`;
    const hash = v2RequestHash({ turnId });
    const replay = this.replayIdempotency(owner, route, key, hash);
    if (replay) return replay.body as Record<string, unknown>;
    const cancelled = this.deps.orchestrator.cancelTurn(turn.turnId);
    const body = projectTurn(cancelled);
    this.deps.store.putIdempotency(owner, route, key, hash, 200, body);
    return body;
  }

  eventsSince(
    owner: string,
    turnId: string,
    lastEventId: string | undefined
  ): { events: V2EventRecord[]; expired: boolean } {
    this.requireOwnedTurn(owner, turnId);
    const after = lastEventId ? Number(lastEventId) : 0;
    if (lastEventId && Number.isFinite(after) && after > 0) {
      const named = this.deps.store.eventsSince(turnId, after - 1).find((event) => event.eventId === after);
      if (named && Date.now() - Date.parse(named.occurredAt) > EVENT_RETENTION_MS) {
        return { events: [], expired: true };
      }
      const oldest = this.deps.store.eventsSince(turnId, 0)[0];
      if (oldest && after + 1 < oldest.eventId) {
        return { events: [], expired: true };
      }
    }
    return {
      events: this.deps.store.eventsSince(turnId, Number.isFinite(after) ? after : 0),
      expired: false
    };
  }

  listArtifacts(owner: string, researchId: string, search: URLSearchParams): Record<string, unknown> {
    rejectPathQuery(search);
    this.requireOwnedResearch(owner, researchId);
    const kind = search.get('kind')?.trim() || undefined;
    const status = search.get('status')?.trim() || undefined;
    const all = this.deps.store
      .listArtifacts(researchId, kind)
      .filter((row) => (status ? row.status === status : true));
    const limit = Math.min(50, Math.max(1, Number(search.get('limit') ?? 20) || 20));
    const cursor = decodeListCursor(search.get('cursor'));
    const sliced = cursor
      ? all.filter(
          (row) =>
            row.createdAt < cursor.updatedAt || (row.createdAt === cursor.updatedAt && row.artifactId < cursor.id)
        )
      : all;
    const page = sliced.slice(0, limit);
    const next = sliced[limit];
    return {
      artifacts: page.map(projectArtifact),
      nextCursor: next ? encodeListCursor(next.createdAt, next.artifactId) : null
    };
  }

  getArtifactBody(owner: string, researchId: string, artifactId: string, search: URLSearchParams): Record<string, unknown> {
    rejectPathQuery(search);
    this.requireOwnedResearch(owner, researchId);
    if (!ARTIFACT_ID.test(artifactId)) {
      throw new DomainError('ARTIFACT_NOT_FOUND', 'artifactId missing or not in this Research', false, 404);
    }
    const record = this.deps.store.getArtifact(researchId, artifactId);
    if (!record) {
      throw new DomainError('ARTIFACT_NOT_FOUND', 'artifactId missing or not in this Research', false, 404);
    }
    const body = this.deps.orchestrator.writerFor(researchId).get(artifactId);
    const clipped = truncateArtifactText(body.text);
    return {
      artifact: projectArtifact(record),
      text: clipped.text,
      truncated: clipped.truncated,
      encoding: 'utf-8'
    };
  }

  async createTranscription(
    owner: string,
    researchId: string,
    sourceId: string,
    body: Record<string, unknown>,
    idempotencyKey: string | undefined
  ): Promise<Record<string, unknown>> {
    const key = requireIdempotency(idempotencyKey);
    this.requireOwnedResearch(owner, researchId);
    if (!SOURCE_ID.test(sourceId)) {
      throw new DomainError('SOURCE_NOT_FOUND', 'sourceId is missing or not in this Research', false, 404);
    }
    if (body.confirmed !== true) {
      throw new DomainError('TRANSCRIPT_CONFIRMATION_REQUIRED', 'missing or invalid user confirmation token', false, 400);
    }
    const targetLanguage = optionalString(body.targetLanguage);
    if (!targetLanguage || targetLanguage.length < 2) {
      throw new DomainError('INVALID_REQUEST', 'targetLanguage is required', false, 400, { field: 'targetLanguage' });
    }
    const translationQuality = body.translationQuality === 'fast' ? 'fast' : 'quality';
    const route = `POST /v2/assistant/researches/${researchId}/sources/${sourceId}/transcription`;
    const hash = v2RequestHash({ researchId, sourceId, targetLanguage, translationQuality });
    const replay = this.replayIdempotency(owner, route, key, hash);
    if (replay) return replay.body as Record<string, unknown>;
    const source = resolveTranscriptSource(
      this.deps.store,
      this.deps.orchestrator.writerFor(researchId),
      researchId,
      sourceId
    );
    const issued = this.deps.orchestrator.transcriptJobs.issue({ researchId, sourceId, source });
    const projected = projectTranscriptJob(issued.job);
    this.deps.store.putIdempotency(owner, route, key, hash, 202, projected);
    // A real transcription (ASR + translation) routinely runs far longer than a single HTTP
    // request should block for, so this is fire-and-forget: `issue()` already persisted a
    // `requested` row synchronously above, and the caller is expected to poll getTranscription /
    // listTranscriptions for progress instead of waiting on this response.
    // Persist the confirmed request synchronously before returning HTTP 202.
    void this.deps.orchestrator.transcriptJobs
        .request({
          researchId,
          sourceId,
          confirmationToken: issued.token,
          confirmed: true,
          targetLanguage,
          translationQuality,
          source
        })
        .catch(() => undefined);
    return projected;
  }

  getTranscription(owner: string, researchId: string, transcriptJobId: string): Record<string, unknown> {
    this.requireOwnedResearch(owner, researchId);
    if (!TRANSCRIPT_JOB_ID.test(transcriptJobId)) {
      throw new DomainError('TRANSCRIPT_JOB_NOT_FOUND', 'transcriptJobId missing or not in this Research', false, 404);
    }
    return projectTranscriptJob(this.deps.orchestrator.transcriptJobs.get(researchId, transcriptJobId));
  }

  /** Lets a client reconcile transcription state for a research (e.g. after reopening it) without
   *  needing to already hold every transcriptJobId it started. */
  listTranscriptions(owner: string, researchId: string): Record<string, unknown> {
    this.requireOwnedResearch(owner, researchId);
    return {
      transcriptJobs: this.deps.orchestrator.transcriptJobs.listForResearch(researchId).map(projectTranscriptJob)
    };
  }

  getMemory(owner: string, researchId: string): unknown {
    this.requireOwnedResearch(owner, researchId);
    return this.deps.orchestrator.snapshot(researchId).memory;
  }

  confirmMemoryProposal(owner: string, proposalId: string, idempotencyKey: string | undefined): unknown {
    const key = requireIdempotency(idempotencyKey);
    if (!PROPOSAL_ID.test(proposalId)) {
      throw new DomainError('MEMORY_PROPOSAL_NOT_FOUND', 'proposalId is unknown', false, 404);
    }
    const proposal = this.deps.store.getMemoryProposal(proposalId);
    if (!proposal) {
      throw new DomainError('MEMORY_PROPOSAL_NOT_FOUND', 'proposalId is unknown', false, 404);
    }
    this.requireOwnedResearch(owner, proposal.researchId);
    const route = `POST /v2/assistant/memory-proposals/${proposalId}/confirm`;
    const hash = v2RequestHash({ proposalId, action: 'confirm' });
    const replay = this.replayIdempotency(owner, route, key, hash);
    if (replay) return replay.body;
    const entry = this.deps.orchestrator.memoryProposals.confirm(proposalId);
    this.deps.store.putIdempotency(owner, route, key, hash, 200, entry);
    return entry;
  }

  rejectMemoryProposal(owner: string, proposalId: string, idempotencyKey: string | undefined): unknown {
    const key = requireIdempotency(idempotencyKey);
    if (!PROPOSAL_ID.test(proposalId)) {
      throw new DomainError('MEMORY_PROPOSAL_NOT_FOUND', 'proposalId is unknown', false, 404);
    }
    const proposal = this.deps.store.getMemoryProposal(proposalId);
    if (!proposal) {
      throw new DomainError('MEMORY_PROPOSAL_NOT_FOUND', 'proposalId is unknown', false, 404);
    }
    this.requireOwnedResearch(owner, proposal.researchId);
    const route = `POST /v2/assistant/memory-proposals/${proposalId}/reject`;
    const hash = v2RequestHash({ proposalId, action: 'reject' });
    const replay = this.replayIdempotency(owner, route, key, hash);
    if (replay) return replay.body;
    const rejected = this.deps.orchestrator.memoryProposals.reject(proposalId);
    this.deps.store.putIdempotency(owner, route, key, hash, 200, rejected);
    return rejected;
  }

  private projectResearchId(owner: string, researchId: string): Record<string, unknown> {
    const research = this.requireOwnedResearch(owner, researchId);
    return projectResearch(
      research,
      this.deps.store.listArtifacts(researchId),
      this.deps.store.listGrants(researchId)
    );
  }

  private requireOwnedResearch(owner: string, researchId: string) {
    if (!RESEARCH_ID.test(researchId)) {
      throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    }
    const research = this.deps.store.getResearch(researchId, true);
    if (!research || research.status === 'deleted' || research.status === 'deleting') {
      throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    }
    this.assertOwner(owner, research.ownerScope);
    return this.deps.store.getResearch(researchId) ?? research;
  }

  private requireOwnedTurn(owner: string, turnId: string) {
    if (!TURN_ID.test(turnId)) {
      throw new DomainError('TURN_NOT_FOUND', 'Unknown turn', false, 404);
    }
    const turn = this.deps.store.getTurn(turnId);
    if (!turn) throw new DomainError('TURN_NOT_FOUND', 'Unknown turn', false, 404);
    this.requireOwnedResearch(owner, turn.researchId);
    return turn;
  }

  /** Foreign researches are indistinguishable from unknown ones (V18: 404, never 403). */
  private assertOwner(owner: string, ownerScope: string): void {
    if (ownerScope !== owner) {
      throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    }
  }

  private grantsFromAliases(raw: unknown): WorkspaceGrantInput[] {
    if (raw == null) return [];
    if (!Array.isArray(raw)) {
      throw new DomainError('INVALID_REQUEST', 'sharedAliases must be an array', false, 400, { field: 'sharedAliases' });
    }
    if (raw.length > 16) {
      throw new DomainError('INVALID_REQUEST', 'sharedAliases exceeds 16 items', false, 400, { field: 'sharedAliases' });
    }
    const grants: WorkspaceGrantInput[] = [];
    for (const item of raw) {
      if (typeof item !== 'string' || !GRANT_ALIAS_PATTERN.test(item)) {
        throw new DomainError('INVALID_REQUEST', 'shared alias is invalid', false, 400, { field: 'sharedAliases' });
      }
      const admin = this.deps.adminGrants.find((grant) => grant.alias === item);
      if (!admin) {
        throw new DomainError('WORKSPACE_GRANT_DENIED', 'alias is not granted to this research', false, 403, {
          alias: item
        });
      }
      grants.push({
        alias: admin.alias,
        permission: admin.permission === 'read_write' && this.deps.sharedWriteEnabled ? 'read_write' : 'read',
        allowedExtensions: admin.allowedExtensions,
        maxFileBytes: admin.maxFileBytes
      });
    }
    return grants;
  }

  private replayIdempotency(
    owner: string,
    route: string,
    key: string,
    hash: string
  ): { status: number; body: unknown } | null {
    const existing = this.deps.store.getIdempotency(owner, route, key);
    if (!existing) return null;
    if (existing.hash !== hash) {
      throw new DomainError('IDEMPOTENCY_CONFLICT', 'Idempotency-Key reused with different payload', false, 409);
    }
    return { status: existing.status, body: JSON.parse(existing.body) };
  }
}

function requireIdempotency(key: string | undefined): string {
  if (!key) {
    throw new DomainError('INVALID_REQUEST', 'Idempotency-Key is required', false, 400, { field: 'Idempotency-Key' });
  }
  return key;
}

function optionalString(value: unknown, max?: number): string | undefined {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  return max ? trimmed.slice(0, max) : trimmed;
}
