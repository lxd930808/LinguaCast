import { isToolResultFailure, type AgentRuntime } from '../agent/runtime.js';
import { toolsVisibleToAgent, type V2ResearchPhase, type V2TurnKind } from '../agent/v2/tools.js';
import { ArtifactWriter } from '../artifacts/writer.js';
import type { V10ContentClient } from '../content/v10-client.js';
import { TranscriptJobs } from '../content/v2/transcript-jobs.js';
import type { V2ResearchRecord, V2TurnRecord, V2Store } from '../db/v2/store.js';
import { v2RequestHash } from '../db/v2/store.js';
import { nowIso } from '../domain/ids.js';
import { DomainError, describeUnknownError } from '../domain/types.js';
import { EvidenceService } from '../evidence/index.js';
import { GlobalMemory } from '../memory/global-memory.js';
import { MemoryProposals } from '../memory/proposals.js';
import { ResearchMemory } from '../memory/research-memory.js';
import { provisionalTitle, type SessionTitleGenerator } from './session-title.js';
import { loadSkillRegistry, type SkillRecord } from '../skills/registry.js';
import type { WebResearch } from '../web/service.js';
import { FileTools } from '../workspace/file-tools.js';
import { GrepAdapter } from '../workspace/grep-adapter.js';
import type { AdminGrant } from '../workspace/grants.js';
import type { WorkspaceGrantInput, WorkspaceManager } from '../workspace/manager.js';
import { V2EventLog } from './events.js';
import { gapMarkdown, saveValidatedReport } from './report.js';
import { composeV2SystemPrompt, primarySkill, skillsForMode } from './skills.js';
import {
  newLeaseId,
  newMessageId,
  newTurnId,
  type TurnMode
} from './state.js';
import {
  V2ToolDispatcher,
  type KnownSource,
  type TurnToolContext,
  type V2MediaSearch
} from './tool-dispatch.js';

export const V2_DEFAULT_TITLE = 'Untitled research';

export interface V2OrchestratorConfig {
  assistantWebEnabled: boolean;
  sharedWriteEnabled: boolean;
  rgPath: string;
  maxGrepMatches: number;
  maxGrepMs: number;
  globalMemoryRoot: string;
  sharedVersionRoot: string;
}

export interface CreateResearchInput {
  /** Account that owns the research; resolved by the API layer, never from configuration. */
  ownerScope: string;
  title?: string;
  outputLanguage?: string;
  storefront?: string;
  targetLanguage?: string;
  translationQuality?: 'fast' | 'quality';
  grants?: WorkspaceGrantInput[];
  idempotencyKey?: string;
}

export interface CreateTurnInput {
  mode: TurnMode;
  text: string;
  /** Pre-generated when quota was reserved for this turn before insertion. */
  turnId?: string;
  operationKey?: string | null;
  reservationId?: string | null;
  confirmationToken?: string | null;
  sources?: KnownSource[];
  idempotencyKey?: string;
}

export interface V2OrchestratorDeps {
  store: V2Store;
  workspace: WorkspaceManager;
  config: V2OrchestratorConfig;
  agent: AgentRuntime;
  v10: V10ContentClient;
  skills?: SkillRecord[];
  adminGrants?: AdminGrant[];
  mediaSearch?: V2MediaSearch | null;
  titleGenerator?: SessionTitleGenerator | null;
  webFor?: (researchId: string, writer: ArtifactWriter) => WebResearch | null;
}

export class V2ResearchOrchestrator {
  private readonly aborts = new Map<string, AbortController>();
  private readonly titleJobs = new Set<string>();
  private readonly writers = new Map<string, ArtifactWriter>();
  private readonly files = new Map<string, FileTools>();
  private readonly web = new Map<string, WebResearch>();
  private readonly skills: SkillRecord[];
  private readonly grep: GrepAdapter;
  private readonly memory: ResearchMemory;
  private readonly proposals: MemoryProposals;
  private readonly evidence: EvidenceService;
  private readonly transcripts: TranscriptJobs;
  private readonly global: GlobalMemory;

  constructor(private readonly deps: V2OrchestratorDeps) {
    this.skills = deps.skills ?? loadSkillRegistry();
    this.grep = new GrepAdapter(deps.config.rgPath, deps.config.maxGrepMatches, deps.config.maxGrepMs);
    this.global = new GlobalMemory(deps.store, deps.config.globalMemoryRoot);
    this.proposals = new MemoryProposals(deps.store, this.global);
    this.memory = new ResearchMemory({
      store: deps.store,
      writerFor: (researchId) => this.writerFor(researchId)
    });
    this.evidence = new EvidenceService({
      store: deps.store,
      writerFor: (researchId) => this.writerFor(researchId),
      fileToolsFor: (researchId) => this.fileToolsFor(researchId)
    });
    this.transcripts = new TranscriptJobs({
      store: deps.store,
      v10: deps.v10,
      writerFor: (researchId) => this.writerFor(researchId)
    });
  }

  get globalMemory(): GlobalMemory {
    return this.global;
  }

  /** True while this process still executes the turn (account purge waits for it). */
  isTurnExecuting(turnId: string): boolean {
    return this.aborts.has(turnId);
  }

  get memoryProposals(): MemoryProposals {
    return this.proposals;
  }

  get transcriptJobs(): TranscriptJobs {
    return this.transcripts;
  }

  createResearch(input: CreateResearchInput): V2ResearchRecord {
    const title = (input.title ?? V2_DEFAULT_TITLE).trim().slice(0, 80) || V2_DEFAULT_TITLE;
    const payload = {
      title,
      outputLanguage: input.outputLanguage ?? 'zh-Hans',
      storefront: (input.storefront ?? 'US').slice(0, 2).toUpperCase(),
      targetLanguage: input.targetLanguage ?? input.outputLanguage ?? 'zh-Hans',
      translationQuality: input.translationQuality === 'fast' ? 'fast' : 'quality'
    };
    const hash = v2RequestHash(payload);
    if (input.idempotencyKey) {
      const existing = this.deps.store.getIdempotency(
        input.ownerScope,
        'POST /v2/assistant/researches',
        input.idempotencyKey
      );
      if (existing) {
        if (existing.hash !== hash) {
          throw new DomainError('IDEMPOTENCY_CONFLICT', 'Idempotency-Key reused with different payload', false, 409);
        }
        const body = JSON.parse(existing.body) as { researchId: string };
        const row = this.deps.store.getResearch(body.researchId);
        if (row) return row;
      }
    }
    const handle = this.deps.workspace.create({
      ownerScope: input.ownerScope,
      title: payload.title,
      outputLanguage: payload.outputLanguage,
      storefront: payload.storefront,
      targetLanguage: payload.targetLanguage,
      translationQuality: payload.translationQuality,
      grants: input.grants
    });
    const research = this.deps.store.getResearch(handle.researchId);
    if (!research) {
      throw new DomainError('WORKSPACE_CREATE_FAILED', 'research row missing after workspace create', true, 503);
    }
    if (input.idempotencyKey) {
      this.deps.store.putIdempotency(
        input.ownerScope,
        'POST /v2/assistant/researches',
        input.idempotencyKey,
        hash,
        201,
        { researchId: research.researchId }
      );
    }
    return research;
  }

  createTurn(researchId: string, input: CreateTurnInput): V2TurnRecord {
    const research = this.requireResearch(researchId);
    if (research.status !== 'ready' && research.status !== 'degraded') {
      throw new DomainError('INVALID_RESEARCH_STATUS', 'research cannot accept a turn', false, 409);
    }
    const text = input.text.trim();
    if (!text) throw new DomainError('INVALID_REQUEST', 'text is required', false, 400, { field: 'text' });
    if (input.mode !== 'research' && input.mode !== 'content_qa') {
      throw new DomainError('INVALID_REQUEST', 'mode must be research or content_qa', false, 400, { field: 'mode' });
    }
    const hash = v2RequestHash({ researchId, mode: input.mode, text });
    const route = `POST /v2/assistant/researches/${researchId}/turns`;
    if (input.idempotencyKey) {
      const existing = this.deps.store.getIdempotency(research.ownerScope, route, input.idempotencyKey);
      if (existing) {
        if (existing.hash !== hash) {
          throw new DomainError('IDEMPOTENCY_CONFLICT', 'Idempotency-Key reused with different payload', false, 409);
        }
        const body = JSON.parse(existing.body) as { turnId: string };
        const turn = this.deps.store.getTurn(body.turnId);
        if (turn) return turn;
      }
    }
    if (this.deps.store.activeTurn(researchId)) {
      throw new DomainError('TURN_ALREADY_RUNNING', 'A turn is already running', false, 409);
    }
    const skills = skillsForMode(this.skills, input.mode);
    const primary = primarySkill(skills, input.mode);
    const now = nowIso();
    const turnId = input.turnId ?? newTurnId();
    const turn = this.deps.store.insertTurn({
      turnId,
      researchId,
      mode: input.mode,
      status: 'queued',
      userText: text,
      skillName: primary?.name ?? null,
      skillVersion: primary?.version ?? null,
      skillSha256: primary?.sha256 ?? null,
      errorCode: null,
      errorMessage: null,
      createdAt: now,
      startedAt: null,
      finishedAt: null,
      operationKey: input.operationKey ?? null,
      reservationId: input.reservationId ?? null
    });
    this.deps.store.insertMessage({
      messageId: newMessageId(),
      researchId,
      turnId,
      role: 'user',
      markdown: text,
      createdAt: now
    });
    this.deps.store.setActiveTurn(researchId, turnId);
    if (input.idempotencyKey) {
      this.deps.store.putIdempotency(research.ownerScope, route, input.idempotencyKey, hash, 202, { turnId });
    }
    this.turnSources.set(turnId, input.sources ?? []);
    this.turnTokens.set(turnId, input.confirmationToken ?? null);
    return turn;
  }

  async runTurn(turnId: string): Promise<V2TurnRecord> {
    const turn = this.deps.store.getTurn(turnId);
    if (!turn) throw new DomainError('TURN_NOT_FOUND', 'Unknown turn', false, 404);
    if (turn.status !== 'queued' && turn.status !== 'running') return turn;
    if (turn.status === 'queued') {
      this.deps.store.setTurnStatus(turnId, 'queued', 'running');
    }
    this.deps.store.claimTurnLease(turnId, 'v2-orchestrator', 60_000, newLeaseId());
    const events = new V2EventLog(this.deps.store, turn.researchId, turnId);
    events.emit('turn.started', { mode: turn.mode });
    const turnCount = (
      this.deps.store.getDb().prepare(`SELECT COUNT(*) AS n FROM v2_turns WHERE research_id = ?`).get(turn.researchId) as {
        n: number;
      }
    ).n;
    if (turnCount === 1) {
      events.emit('workspace.created', { workspaceStatus: 'ready' });
      this.startAutoTitle(turn, events);
    }
    const controller = new AbortController();
    this.aborts.set(turnId, controller);
    const ctx = this.newContext(turn, controller.signal);
    try {
      await this.loop(turn, ctx, events);
      if (this.cancelled(turnId) || controller.signal.aborted) {
        return this.deps.store.getTurn(turnId)!;
      }
      if (!ctx.reportSaved) {
        this.writeGapReport(turn, ctx, events);
      }
      this.deps.store.setTurnStatus(turnId, 'running', 'completed');
      this.deps.store.setActiveTurn(turn.researchId, null);
      events.emit('turn.completed', { status: 'completed' });
    } catch (error) {
      if (this.cancelled(turnId)) return this.deps.store.getTurn(turnId)!;
      const code = error instanceof DomainError ? error.code : 'INTERNAL_ERROR';
      this.deps.store.setTurnStatus(turnId, 'running', 'failed', {
        errorCode: code,
        errorMessage: describeUnknownError(error)
      });
      this.deps.store.setActiveTurn(turn.researchId, null);
      events.emit('turn.failed', {
        code,
        retryable: error instanceof DomainError ? error.retryable : false
      });
    } finally {
      this.aborts.delete(turnId);
      this.deps.store.releaseTurnLease(turnId, 'v2-orchestrator');
    }
    return this.deps.store.getTurn(turnId)!;
  }

  cancelTurn(turnId: string): V2TurnRecord {
    const turn = this.deps.store.getTurn(turnId);
    if (!turn) throw new DomainError('TURN_NOT_FOUND', 'Unknown turn', false, 404);
    if (turn.status === 'queued' || turn.status === 'running') {
      this.aborts.get(turnId)?.abort();
      this.deps.store.setTurnStatus(turnId, turn.status, 'cancelled');
      this.deps.store.setActiveTurn(turn.researchId, null);
      new V2EventLog(this.deps.store, turn.researchId, turnId).emit('turn.cancelled', { code: 'TURN_CANCELLED' });
    }
    return this.deps.store.getTurn(turnId)!;
  }

  retryTurn(turnId: string): V2TurnRecord {
    const turn = this.deps.store.getTurn(turnId);
    if (!turn) throw new DomainError('TURN_NOT_FOUND', 'Unknown turn', false, 404);
    if (turn.status !== 'interrupted') {
      throw new DomainError('INVALID_RESEARCH_STATUS', 'only interrupted turns can be retried', false, 409);
    }
    if (this.deps.store.activeTurn(turn.researchId)) {
      throw new DomainError('TURN_ALREADY_RUNNING', 'A turn is already running', false, 409);
    }
    this.deps.store.setTurnStatus(turnId, 'interrupted', 'queued');
    this.deps.store.setActiveTurn(turn.researchId, turnId);
    return this.deps.store.getTurn(turnId)!;
  }

  interruptTurn(turnId: string): V2TurnRecord {
    const turn = this.deps.store.getTurn(turnId);
    if (!turn) throw new DomainError('TURN_NOT_FOUND', 'Unknown turn', false, 404);
    if (turn.status === 'running') {
      this.aborts.get(turnId)?.abort();
      this.deps.store.setTurnStatus(turnId, 'running', 'interrupted');
      this.deps.store.setActiveTurn(turn.researchId, null);
    }
    return this.deps.store.getTurn(turnId)!;
  }

  deleteResearch(researchId: string): void {
    const research = this.deps.store.getResearch(researchId, true);
    if (!research || research.status === 'deleted') return;
    const running = this.deps.store.activeTurn(researchId);
    if (running) this.cancelTurn(running.turnId);
    this.writers.delete(researchId);
    this.files.delete(researchId);
    this.web.delete(researchId);
    this.deps.workspace.delete(researchId);
  }

  snapshot(researchId: string): {
    research: V2ResearchRecord;
    messages: ReturnType<V2Store['listMessages']>;
    artifacts: Array<{
      artifactId: string;
      kind: string;
      status: string;
      sha256: string;
      evidenceLevel: string;
      bytes: number;
    }>;
    citations: ReturnType<V2Store['listCitations']>;
    memory: ReturnType<ResearchMemory['snapshot']>;
    activeTurn: V2TurnRecord | null;
  } {
    const research = this.requireResearch(researchId);
    return {
      research,
      messages: this.deps.store.listMessages(researchId),
      artifacts: this.deps.store.listArtifacts(researchId).map((row) => ({
        artifactId: row.artifactId,
        kind: row.kind,
        status: row.status,
        sha256: row.sha256,
        evidenceLevel: row.evidenceLevel,
        bytes: row.bytes
      })),
      citations: this.deps.store.listCitations(researchId),
      memory: this.memory.snapshot(researchId),
      activeTurn: this.deps.store.activeTurn(researchId)
    };
  }

  writerFor(researchId: string): ArtifactWriter {
    const cached = this.writers.get(researchId);
    if (cached) return cached;
    const writer = new ArtifactWriter(this.deps.store, researchId, this.deps.workspace.internalPath(researchId));
    this.writers.set(researchId, writer);
    return writer;
  }

  private readonly turnSources = new Map<string, KnownSource[]>();
  private readonly turnTokens = new Map<string, string | null>();

  private fileToolsFor(researchId: string): FileTools {
    const cached = this.files.get(researchId);
    if (cached) return cached;
    const tools = new FileTools({
      store: this.deps.store,
      researchId,
      workspaceDir: this.deps.workspace.internalPath(researchId),
      adminGrants: this.deps.adminGrants ?? [],
      sharedWriteEnabled: this.deps.config.sharedWriteEnabled,
      sharedVersionRoot: this.deps.config.sharedVersionRoot
    });
    this.files.set(researchId, tools);
    return tools;
  }

  private webFor(researchId: string): WebResearch | null {
    if (!this.deps.config.assistantWebEnabled) return null;
    const cached = this.web.get(researchId);
    if (cached) return cached;
    const created = this.deps.webFor?.(researchId, this.writerFor(researchId)) ?? null;
    if (created) this.web.set(researchId, created);
    return created;
  }

  private newContext(turn: V2TurnRecord, signal: AbortSignal): TurnToolContext {
    return {
      researchId: turn.researchId,
      turnId: turn.turnId,
      kind: turn.mode,
      phase: turn.mode === 'content_qa' ? 'gathering' : 'planning',
      confirmationToken: this.turnTokens.get(turn.turnId) ?? null,
      grantAliases: this.deps.store.listGrants(turn.researchId).map((grant) => grant.alias),
      signal,
      evidencePack: null,
      citationRepairUsed: false,
      reportSaved: false,
      sources: [...(this.turnSources.get(turn.turnId) ?? [])],
      searchBudget: { youtube: 0, podcast: 0, web: 0 }
    };
  }

  private async loop(turn: V2TurnRecord, ctx: TurnToolContext, events: V2EventLog): Promise<void> {
    const dispatcher = new V2ToolDispatcher({
      store: this.deps.store,
      writer: this.writerFor(turn.researchId),
      fileTools: this.fileToolsFor(turn.researchId),
      grep: this.grep,
      events,
      memory: this.memory,
      proposals: this.proposals,
      evidence: this.evidence,
      transcripts: this.transcripts,
      webFor: (researchId) => this.webFor(researchId),
      mediaSearch: this.deps.mediaSearch ?? null
    });
    const skills = skillsForMode(this.skills, turn.mode);
    const tools = toolsVisibleToAgent(turn.mode).filter((name) => {
      if (this.deps.config.assistantWebEnabled) return true;
      return name !== 'web_search' && name !== 'fetch_web_page';
    });
    const thinkingStartedAt = new Map<string, number>();
    for await (const event of this.deps.agent.run({
      kind: turn.mode === 'content_qa' ? 'qa' : 'research',
      systemPrompt: composeV2SystemPrompt(skills, turn.mode),
      userText: turn.userText,
      history: this.deps.store
        .listMessages(turn.researchId)
        .filter((message) => message.turnId !== turn.turnId)
        .map((message) => ({
          role: message.role === 'assistant' ? 'assistant' : 'user',
          markdown: message.markdown,
          createdAt: message.createdAt
        })),
      tools,
      signal: ctx.signal,
      executeTool: (call) => dispatcher.execute(ctx, call.name, call.args)
    })) {
      if (this.cancelled(turn.turnId) || ctx.signal.aborted) return;
      if (event.type === 'text_delta' && event.text) {
        events.emit('report.delta', { text: event.text });
      }
      if (event.type === 'thinking' && event.thinking) {
        const thinking = event.thinking;
        if (thinking.stage === 'start') {
          thinkingStartedAt.set(thinking.blockId, Date.now());
          events.emit('thinking.started', { blockId: thinking.blockId });
        } else if (thinking.stage === 'delta' && thinking.text) {
          events.emit('thinking.delta', { blockId: thinking.blockId, text: thinking.text });
        } else if (thinking.stage === 'redacted') {
          events.emit('thinking.completed', { blockId: thinking.blockId, redacted: true });
        } else if (thinking.stage === 'end') {
          const startedAt = thinkingStartedAt.get(thinking.blockId);
          events.emit('thinking.completed', {
            blockId: thinking.blockId,
            durationMs:
              thinking.durationMs ?? (startedAt == null ? undefined : Math.max(0, Date.now() - startedAt)),
            ...(thinking.redacted ? { redacted: true } : {})
          });
        }
      }
      if (event.type === 'tool_call') {
        const query =
          typeof event.args?.query === 'string' && event.args.query.trim()
            ? { query: event.args.query.slice(0, 200) }
            : {};
        events.emit('tool.started', { callId: event.callId ?? '', tool: event.tool ?? '', ...query });
      }
      if (event.type === 'tool_result') {
        const ok = !event.error && !isToolResultFailure(event.result);
        events.emit('tool.completed', { callId: event.callId ?? '', tool: event.tool ?? '', ok });
      }
      if (event.type === 'error') {
        throw new DomainError('MODEL_PROVIDER_UNAVAILABLE', event.error ?? 'model failed', true, 503);
      }
    }
  }

  /**
   * Give a freshly created research a real title on its first turn: an instant provisional
   * title from the user's text, then a best-effort LLM title a few seconds later. Both only
   * overwrite the default/provisional title, never one the user set. The title event is emitted
   * on this turn's log so the SSE stream delivers it live; the DB row also carries it for the
   * list/snapshot.
   */
  private startAutoTitle(turn: V2TurnRecord, events: V2EventLog): void {
    const research = this.deps.store.getResearch(turn.researchId);
    if (!research || !this.canAutoTitle(research.title, turn.userText)) return;
    const provisional = provisionalTitle(turn.userText);
    const allowed = [V2_DEFAULT_TITLE, provisional];
    if (research.title !== provisional) {
      if (this.deps.store.updateResearchTitleIf(turn.researchId, provisional, [research.title])) {
        events.emit('research.title_updated', { title: provisional });
      }
    }
    const generator = this.deps.titleGenerator;
    if (!generator || this.titleJobs.has(turn.researchId)) return;
    this.titleJobs.add(turn.researchId);
    void (async () => {
      try {
        const llmTitle = await generator({ userText: turn.userText, outputLanguage: research.outputLanguage });
        if (!llmTitle) return;
        const current = this.deps.store.getResearch(turn.researchId);
        if (!current || !allowed.includes(current.title) || current.title === llmTitle) return;
        if (this.deps.store.updateResearchTitleIf(turn.researchId, llmTitle, allowed)) {
          events.emit('research.title_updated', { title: llmTitle });
        }
      } catch {
        // Title generation is best-effort; keep the provisional title.
      } finally {
        this.titleJobs.delete(turn.researchId);
      }
    })();
  }

  private canAutoTitle(currentTitle: string, userText: string): boolean {
    return currentTitle === V2_DEFAULT_TITLE || currentTitle === provisionalTitle(userText);
  }

  private writeGapReport(turn: V2TurnRecord, ctx: TurnToolContext, events: V2EventLog): void {
    const markdown = gapMarkdown(turn.userText, ctx.evidencePack);
    const saved = saveValidatedReport(this.deps.store, this.writerFor(turn.researchId), {
      researchId: turn.researchId,
      turnId: turn.turnId,
      title: 'Research report',
      markdown,
      citations: [],
      allowEmptyCitations: true
    });
    ctx.reportSaved = true;
    events.emit('report.completed', {
      artifactId: saved.artifact.artifactId,
      citationCount: 0
    });
  }

  private cancelled(turnId: string): boolean {
    return this.deps.store.getTurn(turnId)?.status === 'cancelled';
  }

  private requireResearch(researchId: string): V2ResearchRecord {
    const research = this.deps.store.getResearch(researchId);
    if (!research) throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    return research;
  }
}

export type { V2TurnKind, V2ResearchPhase };
