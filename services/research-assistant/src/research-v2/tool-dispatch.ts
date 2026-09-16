import { assertV2ToolAllowed, clipToolResult } from '../agent/v2/guard.js';
import { toolsForTurn, type V2ResearchPhase, type V2ToolName, type V2TurnKind } from '../agent/v2/tools.js';
import { ARTIFACT_KINDS, type ArtifactKind } from '../artifacts/manifest.js';
import { ArtifactWriterSearchSink } from '../artifacts/search-sink.js';
import type { ArtifactWriter } from '../artifacts/writer.js';
import type { TranscriptJobs } from '../content/v2/transcript-jobs.js';
import type { TranscriptSource } from '../content/v2/transcript-installer.js';
import type { V2Store } from '../db/v2/store.js';
import { DomainError } from '../domain/types.js';
import { toolLimit, toolQuery, toolString } from '../tools/args.js';
import type { EvidenceService } from '../evidence/index.js';
import type { EvidencePack } from '../evidence/pack.js';
import type { MemoryProposals } from '../memory/proposals.js';
import type { ResearchMemory } from '../memory/research-memory.js';
import { nowIso } from '../domain/ids.js';
import {
  buildSearchRunDocument,
  type SearchRunStatus
} from '../search/artifact-sink.js';
import type { SearchPlan } from '../search/contracts.js';
import type { WebResearch } from '../web/service.js';
import type { FileTools } from '../workspace/file-tools.js';
import type { GrepAdapter } from '../workspace/grep-adapter.js';
import type { V2EventLog } from './events.js';
import { gapMarkdown, parseProposedCitations, saveValidatedReport } from './report.js';
import { newSourceId } from './state.js';

const PHASES: V2ResearchPhase[] = ['planning', 'gathering', 'synthesizing', 'reporting'];

const RECOVERABLE_TOOL_CODES = new Set([
  'TOOL_NOT_ALLOWED',
  'TRANSCRIPT_CONFIRMATION_REQUIRED',
  'WEB_DISABLED',
  'WEB_SEARCH_FAILED',
  'WEB_URL_BLOCKED',
  'WEB_URL_NOT_ALLOWED',
  'CITATION_VALIDATION_FAILED',
  'ARTIFACT_NOT_FOUND',
  'GREP_TIMEOUT',
  'GREP_ARGUMENT_REJECTED',
  'GREP_PATTERN_REJECTED',
  'SOURCE_NOT_FOUND',
  'WORKSPACE_GRANT_DENIED',
  'WORKSPACE_PATH_UNSAFE'
]);

export interface KnownSource extends TranscriptSource {
  artifactId: string;
}

export interface V2MediaHit {
  sourceId: string;
  title: string;
  canonicalURL: string;
  platform: 'youtube' | 'podcast';
  sourceType?: 'video' | 'podcast_show' | 'podcast_episode';
  provider?: string;
  publishedAt?: string | null;
  feedURL?: string | null;
  enclosureUrl?: string | null;
}

export interface V2MediaSearch {
  searchYouTube(query: string, limit: number, signal?: AbortSignal): Promise<{ hits: V2MediaHit[]; status?: SearchRunStatus }>;
  searchPodcasts(query: string, limit: number, signal?: AbortSignal): Promise<{ hits: V2MediaHit[]; status?: SearchRunStatus }>;
}

export interface TurnToolContext {
  researchId: string;
  turnId: string;
  kind: V2TurnKind;
  phase: V2ResearchPhase;
  confirmationToken: string | null;
  grantAliases: string[];
  signal: AbortSignal;
  evidencePack: EvidencePack | null;
  citationRepairUsed: boolean;
  reportSaved: boolean;
  sources: KnownSource[];
  searchBudget: { youtube: number; podcast: number; web: number };
}

export interface ToolDispatchDeps {
  store: V2Store;
  writer: ArtifactWriter;
  fileTools: FileTools;
  grep: GrepAdapter;
  events: V2EventLog;
  memory: ResearchMemory;
  proposals: MemoryProposals;
  evidence: EvidenceService;
  transcripts: TranscriptJobs;
  webFor: (researchId: string) => WebResearch | null;
  mediaSearch: V2MediaSearch | null;
}

function rank(phase: V2ResearchPhase): number {
  return PHASES.indexOf(phase);
}

export function promotePhase(kind: V2TurnKind, current: V2ResearchPhase, tool: string): V2ResearchPhase {
  if (kind === 'content_qa') return current;
  let next = current;
  if (tool === 'retrieve_evidence') next = 'synthesizing';
  else if (tool === 'save_research_report') next = 'reporting';
  else if (!toolsForTurn(kind, current).includes(tool as V2ToolName)) {
    for (const phase of PHASES) {
      if (rank(phase) > rank(current) && toolsForTurn(kind, phase).includes(tool as V2ToolName)) {
        next = phase;
        break;
      }
    }
  }
  return rank(next) < rank(current) ? current : next;
}

function stripForged(args: Record<string, unknown>): Record<string, unknown> {
  const copy = { ...args };
  delete copy.researchId;
  delete copy.turnId;
  delete copy.sessionId;
  delete copy.ownerId;
  delete copy.owner;
  delete copy.confirmationToken;
  delete copy.confirmed;
  return copy;
}

function toolError(error: unknown): { ok: false; error: { code: string; message: string } } {
  const code = error instanceof DomainError ? error.code : 'INTERNAL_ERROR';
  const message = error instanceof Error ? error.message : 'tool failed';
  return { ok: false, error: { code, message } };
}

function isRecoverable(error: unknown): boolean {
  return error instanceof DomainError && RECOVERABLE_TOOL_CODES.has(error.code);
}

function defaultPlan(platform: 'youtube' | 'podcast', query: string): SearchPlan {
  return {
    intent: 'topic',
    media: [platform],
    queries: [query],
    person: null,
    showOrChannel: null,
    language: 'en',
    region: 'US',
    publishedAfter: null,
    publishedBefore: null,
    duration: 'any',
    clean: false
  };
}

export class V2ToolDispatcher {
  constructor(private readonly deps: ToolDispatchDeps) {}

  async execute(ctx: TurnToolContext, name: string, rawArgs: Record<string, unknown>): Promise<unknown> {
    ctx.phase = promotePhase(ctx.kind, ctx.phase, name);
    try {
      assertV2ToolAllowed({
        tool: name,
        kind: ctx.kind,
        phase: ctx.phase,
        researchId: ctx.researchId,
        turnId: ctx.turnId,
        expectedResearchId: ctx.researchId,
        expectedTurnId: ctx.turnId,
        confirmationToken: name === 'request_transcription' ? ctx.confirmationToken ?? undefined : undefined,
        uri: typeof rawArgs.uri === 'string' ? rawArgs.uri : typeof rawArgs.root === 'string' ? rawArgs.root : undefined,
        grantAliases: ctx.grantAliases
      });
      const args = stripForged(rawArgs);
      const result = await this.dispatch(ctx, name as V2ToolName, args);
      return clipToolResult(result);
    } catch (error) {
      if (isRecoverable(error)) return clipToolResult(toolError(error));
      throw error;
    }
  }

  private async dispatch(ctx: TurnToolContext, name: V2ToolName, args: Record<string, unknown>): Promise<unknown> {
    switch (name) {
      case 'list_files':
        return this.deps.fileTools.listFiles(toolString(args, 'uri') || 'research://');
      case 'read_file':
        return this.deps.fileTools.readFile(toolString(args, 'uri'));
      case 'write_file':
        return this.deps.fileTools.writeFile(toolString(args, 'uri'), toolString(args, 'contents'));
      case 'search_files':
        return this.deps.fileTools.searchFiles(toolString(args, 'uri') || 'research://', toolQuery(args));
      case 'grep_files':
        return this.deps.grep.grep(
          this.deps.fileTools,
          {
            root: toolString(args, 'root') || 'research://',
            pattern: toolQuery(args, 'pattern'),
            mode: args.mode === 'regex' ? 'regex' : 'literal',
            glob: typeof args.glob === 'string' ? args.glob : undefined,
            caseSensitive: args.caseSensitive === true
          },
          ctx.signal
        );
      case 'get_artifact':
        return this.deps.writer.get(toolString(args, 'artifactId'));
      case 'save_artifact':
        return this.saveArtifact(args);
      case 'web_search':
        return this.webSearch(ctx, args);
      case 'fetch_web_page':
        return this.fetchPage(ctx, args);
      case 'search_youtube':
        return this.mediaSearch(ctx, 'youtube', args);
      case 'search_podcasts':
        return this.mediaSearch(ctx, 'podcast', args);
      case 'get_youtube_video_details':
      case 'get_podcast_episodes':
        return this.sourceFromCatalog(ctx, toolString(args, 'sourceId') || toolString(args, 'videoId') || toolString(args, 'id'));
      case 'read_search_run':
        return this.deps.writer.get(toolString(args, 'artifactId') || toolString(args, 'searchRunId'));
      case 'write_research_memory':
        return this.writeMemory(ctx, args);
      case 'propose_global_memory':
        return this.proposeMemory(ctx, args);
      case 'retrieve_evidence':
        return this.retrieve(ctx, args);
      case 'request_transcription':
        return this.requestTranscript(ctx, args);
      case 'get_transcript_job':
        return this.deps.transcripts.get(ctx.researchId, toolString(args, 'transcriptJobId'));
      case 'get_selected_source':
        return { sources: ctx.sources };
      case 'save_research_report':
        return this.saveReport(ctx, args);
      default: {
        const _never: never = name;
        throw new DomainError('TOOL_NOT_ALLOWED', `unsupported v2 tool ${_never}`, false, 403);
      }
    }
  }

  private saveArtifact(args: Record<string, unknown>) {
    const kind = toolString(args, 'kind') as ArtifactKind;
    if (!ARTIFACT_KINDS.includes(kind)) {
      throw new DomainError('INVALID_REQUEST', 'artifact kind is invalid', false, 400, { field: 'kind' });
    }
    const evidenceLevel =
      kind === 'web_page'
        ? 'primary_content'
        : kind === 'transcript'
          ? 'transcript'
          : kind === 'report' || kind === 'research_memory'
            ? 'research_note'
            : 'search_metadata';
    return this.deps.writer.save({
      kind,
      contents: toolString(args, 'contents'),
      producer: 'save_artifact',
      evidenceLevel,
      sourceURL: typeof args.sourceURL === 'string' ? args.sourceURL : null,
      contentKey: typeof args.contentKey === 'string' ? args.contentKey : null
    });
  }

  private async webSearch(ctx: TurnToolContext, args: Record<string, unknown>) {
    const web = this.deps.webFor(ctx.researchId);
    const query = toolQuery(args);
    ctx.searchBudget.web += 1;
    this.deps.events.emit('web.search_started', { query });
    if (!web) {
      throw new DomainError('WEB_DISABLED', 'web search and fetch are disabled', false, 503);
    }
    try {
      const result = await web.search({
        researchId: ctx.researchId,
        turnId: ctx.turnId,
        query,
        locale: typeof args.locale === 'string' ? args.locale : undefined,
        limit: toolLimit(args, 5)
      });
      this.deps.events.emit('web.search_completed', {
        artifactId: result.artifactId,
        status: result.run.status,
        resultCount: result.run.results.length
      });
      this.deps.events.emit('source.saved', { artifactId: result.artifactId, kind: 'web_search' });
      return { artifactId: result.artifactId, status: result.run.status, results: result.run.results };
    } catch (error) {
      const latest = this.deps.store.listArtifacts(ctx.researchId, 'web_search', 'ready')[0];
      this.deps.events.emit('web.search_failed', {
        artifactId: latest?.artifactId,
        code: error instanceof DomainError ? error.code : 'WEB_SEARCH_FAILED'
      });
      throw error;
    }
  }

  private async fetchPage(ctx: TurnToolContext, args: Record<string, unknown>) {
    const web = this.deps.webFor(ctx.researchId);
    if (!web) {
      throw new DomainError('WEB_DISABLED', 'web search and fetch are disabled', false, 503);
    }
    const result = await web.fetchPage({ researchId: ctx.researchId, url: toolString(args, 'url') });
    this.deps.events.emit('web.page_saved', { artifactId: result.artifactId, evidenceLevel: 'primary_content' });
    this.deps.events.emit('source.saved', { artifactId: result.artifactId, kind: 'web_page' });
    return result;
  }

  private async mediaSearch(ctx: TurnToolContext, platform: 'youtube' | 'podcast', args: Record<string, unknown>) {
    const query = toolQuery(args);
    const limit = toolLimit(args);
    if (platform === 'youtube') ctx.searchBudget.youtube += 1;
    else ctx.searchBudget.podcast += 1;
    const startedAt = nowIso();
    const startedMs = Date.now();
    let hits: V2MediaHit[] = [];
    let status: SearchRunStatus = 'failure';
    const search = this.deps.mediaSearch;
    if (search) {
      try {
        const result =
          platform === 'youtube'
            ? await search.searchYouTube(query, limit, ctx.signal)
            : await search.searchPodcasts(query, limit, ctx.signal);
        hits = result.hits;
        status = result.status ?? (hits.length ? 'success' : 'empty');
      } catch {
        hits = [];
        status = 'failure';
      }
    }
    const mapped = hits.map((hit) => {
      const source: KnownSource = {
        sourceId: newSourceId(),
        platform,
        nativeSourceId: hit.sourceId,
        canonicalURL: hit.canonicalURL,
        title: hit.title,
        artifactId: '',
        feedURL: hit.feedURL ?? null,
        enclosureUrl: hit.enclosureUrl ?? null
      };
      return source;
    });
    const document = buildSearchRunDocument({
      context: { researchId: ctx.researchId, turnId: ctx.turnId },
      platform,
      plan: defaultPlan(platform, query),
      hits: hits.map((hit) => ({
        platform,
        sourceType: hit.sourceType ?? (platform === 'youtube' ? 'video' : 'podcast_episode'),
        sourceId: hit.sourceId,
        canonicalURL: hit.canonicalURL,
        title: hit.title,
        provider: hit.provider ?? platform,
        publishedAt: hit.publishedAt ?? null,
        feedURL: hit.feedURL ?? null,
        enclosureUrl: hit.enclosureUrl ?? null,
        provenance: {},
        deepResearchAvailability: 'available' as const,
        warnings: []
      })),
      providerStatus: [
        {
          provider: platform,
          status: status === 'success' || status === 'empty' ? status : 'unavailable',
          acceptedCount: hits.length
        }
      ],
      warnings: [],
      startedAt,
      startedMs
    });
    document.status = status;
    document.results = document.results.map((row, index) => ({
      ...row,
      assistantSourceId: mapped[index]?.sourceId,
      nativeSourceId: mapped[index]?.nativeSourceId ?? row.sourceId
    }));
    const sink = new ArtifactWriterSearchSink(() => this.deps.writer);
    const persisted = sink.persist(document);
    const artifactId = persisted?.artifactId ?? null;
    if (artifactId) {
      this.deps.events.emit('source.saved', {
        artifactId,
        kind: platform === 'youtube' ? 'youtube_search' : 'podcast_search'
      });
    }
    for (const source of mapped) {
      source.artifactId = artifactId ?? '';
      ctx.sources.push(source);
    }
    return {
      artifactId,
      status,
      results: mapped.map((source) => ({
        sourceId: source.sourceId,
        nativeSourceId: source.nativeSourceId,
        title: source.title,
        canonicalURL: source.canonicalURL,
        platform,
        artifactId
      })),
      count: mapped.length
    };
  }

  private sourceFromCatalog(ctx: TurnToolContext, sourceId: string) {
    const source = ctx.sources.find((item) => item.sourceId === sourceId || item.nativeSourceId === sourceId);
    if (!source) {
      throw new DomainError('SOURCE_NOT_FOUND', 'source is not in this research turn', false, 404);
    }
    return source;
  }

  private writeMemory(ctx: TurnToolContext, args: Record<string, unknown>) {
    const entry = this.deps.memory.upsert(ctx.researchId, {
      type: toolString(args, 'type', 40) || 'finding',
      content: toolString(args, 'content'),
      sourceArtifactId: typeof args.sourceArtifactId === 'string' ? args.sourceArtifactId : null,
      hypothesis: args.hypothesis === true
    });
    const ready = this.deps.store.listArtifacts(ctx.researchId, 'research_memory', 'ready')[0];
    this.deps.events.emit('memory.updated', {
      artifactId: ready?.artifactId,
      entryCount: this.deps.store.listMemoryEntries(ctx.researchId).length
    });
    return entry;
  }

  private proposeMemory(ctx: TurnToolContext, args: Record<string, unknown>) {
    const proposal = this.deps.proposals.propose({
      researchId: ctx.researchId,
      content: toolString(args, 'content'),
      reason: toolString(args, 'reason', 500) || 'model proposal'
    });
    this.deps.events.emit('memory.proposed', { proposalId: proposal.proposalId, status: proposal.status });
    return proposal;
  }

  private async retrieve(ctx: TurnToolContext, args: Record<string, unknown>) {
    const pack = await this.deps.evidence.retrieve({
      researchId: ctx.researchId,
      query: toolQuery(args),
      limit: typeof args.limit === 'number' ? args.limit : 12
    });
    ctx.evidencePack = pack;
    return pack;
  }

  private async requestTranscript(ctx: TurnToolContext, args: Record<string, unknown>) {
    const sourceId = toolString(args, 'sourceId');
    const source = this.sourceFromCatalog(ctx, sourceId);
    if (!ctx.confirmationToken) {
      throw new DomainError('TRANSCRIPT_CONFIRMATION_REQUIRED', 'missing user confirmation token', false, 400);
    }
    const job = await this.deps.transcripts.request({
      researchId: ctx.researchId,
      sourceId: source.sourceId,
      confirmationToken: ctx.confirmationToken,
      confirmed: true,
      targetLanguage: 'zh-Hans',
      translationQuality: 'quality',
      source,
      signal: ctx.signal
    });
    this.deps.events.emit('transcript.job_updated', {
      transcriptJobId: job.transcriptJobId,
      status: job.status,
      progress: job.progress
    });
    if (job.artifactId) {
      this.deps.events.emit('transcript.saved', {
        artifactId: job.artifactId,
        transcriptJobId: job.transcriptJobId
      });
    }
    return job;
  }

  private saveReport(ctx: TurnToolContext, args: Record<string, unknown>) {
    const markdown = toolString(args, 'markdown') || toolString(args, 'summary');
    const title = toolString(args, 'title', 80) || 'Research report';
    const proposed = parseProposedCitations(args.citations);
    const pack = ctx.evidencePack;
    try {
      const saved = saveValidatedReport(this.deps.store, this.deps.writer, {
        researchId: ctx.researchId,
        turnId: ctx.turnId,
        title,
        markdown,
        citations: proposed,
        allowEmptyCitations: false
      });
      ctx.reportSaved = true;
      this.deps.events.emit('report.completed', {
        artifactId: saved.artifact.artifactId,
        citationCount: saved.citations.length
      });
      return {
        artifactId: saved.artifact.artifactId,
        citationCount: saved.citations.length,
        evidenceGap: false
      };
    } catch (error) {
      if (!(error instanceof DomainError) || error.code !== 'CITATION_VALIDATION_FAILED') throw error;
      if (!ctx.citationRepairUsed) {
        ctx.citationRepairUsed = true;
        throw error;
      }
      const gap = gapMarkdown(pack?.query ?? title, pack, markdown);
      const saved = saveValidatedReport(this.deps.store, this.deps.writer, {
        researchId: ctx.researchId,
        turnId: ctx.turnId,
        title,
        markdown: gap,
        citations: [],
        allowEmptyCitations: true
      });
      ctx.reportSaved = true;
      this.deps.events.emit('report.completed', {
        artifactId: saved.artifact.artifactId,
        citationCount: 0
      });
      return {
        artifactId: saved.artifact.artifactId,
        citationCount: 0,
        evidenceGap: true
      };
    }
  }
}
