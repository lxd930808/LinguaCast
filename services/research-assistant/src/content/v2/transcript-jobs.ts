import { ulid } from 'ulid';

import type { ArtifactWriter } from '../../artifacts/writer.js';
import type { V10CallContext, V10ContentClient, V10Job } from '../v10-client.js';
import { podcastContentKey, videoContentKey } from '../content-key.js';
import type { V2Store, V2TranscriptJobRecord } from '../../db/v2/store.js';
import { nowIso } from '../../domain/ids.js';
import { DomainError } from '../../domain/types.js';
import { newTranscriptJobId, type TranscriptJobStatus } from '../../research-v2/state.js';
import { assertConfirmationToken, issueConfirmationToken } from './confirmation.js';
import { TranscriptInstaller, type TranscriptSource } from './transcript-installer.js';

export interface TranscriptJobWire {
  transcriptJobId: string;
  researchId: string;
  sourceId: string;
  contentKey: string;
  v10JobId: string | null;
  status: TranscriptJobStatus;
  installStatus: string;
  progress: number;
  artifactId: string | null;
  error: {
    code: string;
    message: string;
    retryable: boolean;
    traceId: string;
  } | null;
  updatedAt: string;
}

export interface IssueTranscriptInput {
  researchId: string;
  sourceId: string;
  source: TranscriptSource;
}

export interface RequestTranscriptInput {
  researchId: string;
  sourceId: string;
  confirmationToken: string;
  confirmed: true;
  targetLanguage: string;
  translationQuality: 'fast' | 'quality';
  source: TranscriptSource;
  signal?: AbortSignal;
}

const SOURCE_ID_PATTERN = /^so_[0-9A-HJKMNP-TV-Z]{26}$/;

export class TranscriptJobs {
  private readonly installer: TranscriptInstaller;
  private readonly active = new Map<string, Promise<TranscriptJobWire>>();
  private recoveryTimer: ReturnType<typeof setInterval> | undefined;
  private recovering = false;
  private stopping = false;

  startRecovery(sourceFor: (job: V2TranscriptJobRecord) => TranscriptSource): void {
    if (this.recoveryTimer) return;
    this.stopping = false;
    const tick = () => { void this.reconcile(sourceFor).catch(() => undefined); };
    this.recoveryTimer = setInterval(tick, 15_000);
    this.recoveryTimer.unref();
    tick();
  }

  async stopRecovery(): Promise<void> {
    this.stopping = true;
    clearInterval(this.recoveryTimer);
    this.recoveryTimer = undefined;
    await Promise.allSettled(this.active.values());
  }

  async reconcile(sourceFor: (job: V2TranscriptJobRecord) => TranscriptSource): Promise<void> {
    if (this.recovering) return;
    this.recovering = true;
    try {
      for (const job of this.options.store.recoverableTranscriptJobs()) {
        if (this.stopping) break;
        if (this.active.has(job.transcriptJobId)) continue;
        try {
          const saved = this.savedRequest(job.transcriptJobId);
          await this.resume(job.researchId, job.transcriptJobId, saved?.source ?? sourceFor(job));
        } catch {
          // A failed lookup must not prevent recovery of the remaining jobs.
        }
      }
    } finally { this.recovering = false; }
  }

  private savedRequest(id: string): Pick<RequestTranscriptInput, 'source' | 'targetLanguage' | 'translationQuality'> | null {
    return this.options.store.transcriptRequest(id) as Pick<RequestTranscriptInput, 'source' | 'targetLanguage' | 'translationQuality'> | null;
  }

  private advanceOnce(job: V2TranscriptJobRecord, source: TranscriptSource, input: RequestTranscriptInput): Promise<TranscriptJobWire> {
    const existing = this.active.get(job.transcriptJobId);
    if (existing) return existing;
    const work = this.advance(job, source, input).finally(() => this.active.delete(job.transcriptJobId));
    this.active.set(job.transcriptJobId, work);
    return work;
  }

  constructor(
    private readonly options: {
      store: V2Store;
      v10: V10ContentClient;
      writerFor: (researchId: string) => ArtifactWriter | null;
      pipelineVersion?: string;
      sleep?: (ms: number, signal?: AbortSignal) => Promise<void>;
      maxPollMs?: number;
    }
  ) {
    this.installer = new TranscriptInstaller(options.store, options.v10);
  }

  issue(input: IssueTranscriptInput): { token: string; job: TranscriptJobWire } {
    const research = this.requireResearch(input.researchId);
    const source = this.assertEligibleSource(research.researchId, input.sourceId, input.source);
    const contentKey = contentKeyFor(source);
    const existing = this.options.store.findTranscriptJobBySource(research.researchId, input.sourceId, contentKey);
    const issued = issueConfirmationToken();
    if (existing) {
      this.options.store.patchTranscriptJob(existing.transcriptJobId, { confirmationTokenHash: issued.hash });
      return { token: issued.token, job: this.project(this.reload(research.researchId, existing.transcriptJobId)) };
    }
    const now = nowIso();
    const record = this.options.store.insertTranscriptJob({
      transcriptJobId: newTranscriptJobId(),
      researchId: research.researchId,
      sourceId: input.sourceId,
      contentKey,
      v10JobId: null,
      status: 'requested',
      installStatus: 'requested',
      progress: 0,
      artifactId: null,
      error: null,
      confirmationTokenHash: issued.hash,
      createdAt: now,
      updatedAt: now
    });
    return { token: issued.token, job: this.project(record) };
  }

  get(researchId: string, transcriptJobId: string): TranscriptJobWire {
    this.requireResearch(researchId);
    const job = this.options.store.getTranscriptJob(researchId, transcriptJobId);
    if (!job) {
      throw new DomainError('TRANSCRIPT_JOB_NOT_FOUND', 'transcript job is missing', false, 404);
    }
    return this.project(job);
  }

  /** All transcript jobs ever issued for a research, oldest first. Lets a client reconcile job
   *  state (e.g. after reopening a research) without needing to already know a transcriptJobId. */
  listForResearch(researchId: string): TranscriptJobWire[] {
    this.requireResearch(researchId);
    return this.options.store.listTranscriptJobs(researchId).map((job) => this.project(job));
  }

  async request(input: RequestTranscriptInput): Promise<TranscriptJobWire> {
    if (input.confirmed !== true) {
      throw new DomainError('TRANSCRIPT_CONFIRMATION_REQUIRED', 'missing or invalid user confirmation token', false, 400);
    }
    const research = this.requireResearch(input.researchId);
    const source = this.assertEligibleSource(research.researchId, input.sourceId, input.source);
    const contentKey = contentKeyFor(source);
    const job = this.options.store.findTranscriptJobBySource(research.researchId, input.sourceId, contentKey);
    if (!job) {
      throw new DomainError('TRANSCRIPT_CONFIRMATION_REQUIRED', 'missing or invalid user confirmation token', false, 400);
    }
    assertConfirmationToken(input.confirmationToken, job.confirmationTokenHash);
    if (job.status === 'ready') {
      return this.project(job);
    }
    if (!this.savedRequest(job.transcriptJobId)) {
      this.options.store.saveTranscriptRequest(job.transcriptJobId, {
        source, targetLanguage: input.targetLanguage, translationQuality: input.translationQuality
      });
    }
    return this.advanceOnce(job, source, input);
  }

  async resume(researchId: string, transcriptJobId: string, source: TranscriptSource, signal?: AbortSignal): Promise<TranscriptJobWire> {
    const job = this.options.store.getTranscriptJob(researchId, transcriptJobId);
    if (!job) {
      throw new DomainError('TRANSCRIPT_JOB_NOT_FOUND', 'transcript job is missing', false, 404);
    }
    if (job.status === 'ready' || job.status === 'failed_terminal') {
      return this.project(job);
    }
    if (job.status === 'requested' && !this.savedRequest(job.transcriptJobId)) {
      throw new DomainError('TRANSCRIPT_CONFIRMATION_REQUIRED', 'missing or invalid user confirmation token', false, 400);
    }
    const saved = this.savedRequest(job.transcriptJobId);
    return this.advanceOnce(job, source, {
      researchId,
      sourceId: job.sourceId,
      confirmationToken: '',
      confirmed: true,
      targetLanguage: saved?.targetLanguage ?? 'zh-Hans',
      translationQuality: saved?.translationQuality ?? 'quality',
      source,
      signal
    });
  }

  private async advance(
    job: V2TranscriptJobRecord,
    source: TranscriptSource,
    input: RequestTranscriptInput
  ): Promise<TranscriptJobWire> {
    try {
      if (job.status === 'requested' || job.status === 'failed_retryable') {
        this.transition(job.transcriptJobId, job.status, 'waiting_service');
        job = this.reload(job.researchId, job.transcriptJobId);
      }
      let v10Job = await this.lookupOrCreate(job, source, input);
      this.options.store.patchTranscriptJob(job.transcriptJobId, {
        v10JobId: v10Job.jobId,
        progress: clampProgress(v10Job.progress)
      });
      if (job.status === 'waiting_service') {
        this.transition(job.transcriptJobId, 'waiting_service', 'running');
        job = this.reload(job.researchId, job.transcriptJobId);
      } else if (job.status === 'requested') {
        this.transition(job.transcriptJobId, 'requested', 'running');
        job = this.reload(job.researchId, job.transcriptJobId);
      }
      v10Job = await this.pollUntilSettled(v10Job, job.transcriptJobId, input.signal, this.v10Context(job));
      if (v10Job.status === 'queued' || v10Job.status === 'running') {
        return this.project(this.reload(job.researchId, job.transcriptJobId));
      }
      if (v10Job.status !== 'ready') {
        const terminal = v10Job.error?.retryable === false || v10Job.status === 'cancelled' || v10Job.status === 'expired';
        this.fail(job, terminal ? 'failed_terminal' : 'failed_retryable', {
          code: v10Job.error?.code ?? 'V10_JOB_FAILED',
          message: v10Job.error?.message ?? 'V10 job failed',
          retryable: !terminal
        });
        return this.project(this.reload(job.researchId, job.transcriptJobId));
      }
      if (job.status === 'running') {
        this.transition(job.transcriptJobId, 'running', 'installing');
        job = this.reload(job.researchId, job.transcriptJobId);
      }
      const writer = this.writer(job.researchId);
      const installed = await this.installer.install({
        researchId: job.researchId,
        writer,
        job: v10Job,
        contentKey: job.contentKey,
        source,
        sourceLanguage: 'en'
      });
      this.options.store.patchTranscriptJob(job.transcriptJobId, {
        v10JobId: v10Job.jobId,
        artifactId: installed.artifact.artifactId,
        progress: 1,
        error: null,
        installStatus: 'ready'
      });
      if (job.status === 'installing') {
        this.transition(job.transcriptJobId, 'installing', 'ready');
      }
      return this.project(this.reload(job.researchId, job.transcriptJobId));
    } catch (error) {
      const mapped = mapV10Error(error);
      if (mapped.code === 'V10_UNAVAILABLE' && mapped.retryable) {
        this.options.store.patchTranscriptJob(job.transcriptJobId, {
          installStatus: 'retrying',
          error: { ...mapped, message: '连接暂时中断，正在重试', traceId: `tr_${ulid()}` }
        });
        return this.project(this.reload(job.researchId, job.transcriptJobId));
      }
      this.fail(job, mapped.retryable ? 'failed_retryable' : 'failed_terminal', mapped);
      if (error instanceof DomainError) throw error;
      throw new DomainError(mapped.code, mapped.message, mapped.retryable, mapped.retryable ? 503 : 409);
    }
  }

  private async lookupOrCreate(
    job: V2TranscriptJobRecord,
    source: TranscriptSource,
    input: RequestTranscriptInput
  ): Promise<V10Job> {
    const context = this.v10Context(job);
    if (job.v10JobId) {
      return this.options.v10.get(job.v10JobId, context);
    }
    const contentType = source.platform === 'youtube' ? 'video' : 'podcast_episode';
    let found = await this.options.v10.lookup({
      contentType,
      contentKey: job.contentKey,
      targetLanguage: input.targetLanguage,
      translationQuality: input.translationQuality
    }, context);
    if (!found || found.status === 'failed' || found.status === 'cancelled' || found.status === 'expired') {
      found = await this.options.v10.create({
        contentType,
        contentKey: job.contentKey,
        source: v10SourcePayload(source),
        sourceLanguage: 'en',
        targetLanguage: input.targetLanguage,
        translationQuality: input.translationQuality,
        idempotencyKey: `assistant:${job.contentKey}:${input.targetLanguage}:${input.translationQuality}`
      }, context);
    }
    return found;
  }

  /** Content calls act for the research owner; the transcript job is the logical operation. */
  private v10Context(job: V2TranscriptJobRecord): V10CallContext {
    const research = this.options.store.getResearch(job.researchId, true);
    if (!research) throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    return { ownerScope: research.ownerScope, operationKey: `assistant-transcript:${job.transcriptJobId}` };
  }

  private async pollUntilSettled(
    job: V10Job,
    transcriptJobId: string,
    signal: AbortSignal | undefined,
    context: V10CallContext
  ): Promise<V10Job> {
    let current = job;
    const started = Date.now();
    const maxMs = this.options.maxPollMs ?? 0;
    while (current.status === 'queued' || current.status === 'running') {
      const previous = this.options.store.transcriptProgressUpdatedAt(transcriptJobId);
      // Progress is tracked independently of routine polling timestamps.
      this.options.store.patchTranscriptJob(transcriptJobId, { progress: clampProgress(current.progress) });
      const progressAt = this.options.store.transcriptProgressUpdatedAt(transcriptJobId) ?? previous;
      const stalled = progressAt !== null && Date.now() - Date.parse(progressAt) >= 30 * 60_000;
      this.options.store.patchTranscriptJob(transcriptJobId, {
        installStatus: stalled ? 'stalled' : current.stage ?? current.status,
        error: stalled ? { code: 'TRANSCRIPT_STALLED', message: '处理进度较长时间未更新，仍在跟踪，可点击重试检查原任务', retryable: true, traceId: `tr_${ulid()}` } : null
      });
      if (Date.now() - started >= maxMs) return current;
      await (this.options.sleep ?? defaultSleep)((current.retryAfterSeconds ?? 0) * 1000, signal);
      current = await this.options.v10.get(current.jobId, context);
    }
    return current;
  }

  private assertEligibleSource(researchId: string, sourceId: string, source: TranscriptSource): TranscriptSource {
    if (!SOURCE_ID_PATTERN.test(sourceId) || source.sourceId !== sourceId) {
      throw new DomainError('SOURCE_NOT_FOUND', 'sourceId is missing or not in this research', false, 404);
    }
    if (source.platform === 'youtube') {
      if (!source.nativeSourceId.trim() || !source.canonicalURL.trim()) {
        throw new DomainError('TRANSCRIPT_SOURCE_NOT_ELIGIBLE', 'source cannot enter V10', false, 409);
      }
    } else if (!source.feedURL || !source.enclosureUrl || !source.nativeSourceId.trim()) {
      throw new DomainError('TRANSCRIPT_SOURCE_NOT_ELIGIBLE', 'source cannot enter V10', false, 409);
    }
    if (!sourceBelongsToResearch(this.options.store, this.writer(researchId), researchId, source)) {
      throw new DomainError('SOURCE_NOT_FOUND', 'sourceId is missing or not in this research', false, 404);
    }
    return source;
  }

  private requireResearch(researchId: string) {
    const research = this.options.store.getResearch(researchId);
    if (!research || research.status === 'deleted' || research.status === 'deleting') {
      throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    }
    if (research.status === 'creating') {
      throw new DomainError('WORKSPACE_NOT_READY', 'workspace is still creating', true, 409);
    }
    return research;
  }

  private writer(researchId: string): ArtifactWriter {
    const writer = this.options.writerFor(researchId);
    if (!writer) {
      throw new DomainError('RESEARCH_NOT_FOUND', 'research workspace is not available', false, 404);
    }
    return writer;
  }

  private transition(transcriptJobId: string, from: TranscriptJobStatus, to: TranscriptJobStatus): void {
    this.options.store.setTranscriptJobStatus(transcriptJobId, from, to);
  }

  private fail(
    job: V2TranscriptJobRecord,
    to: 'failed_retryable' | 'failed_terminal',
    error: { code: string; message: string; retryable: boolean }
  ): void {
    const current = this.options.store.getTranscriptJob(job.researchId, job.transcriptJobId);
    if (!current) return;
    this.options.store.patchTranscriptJob(current.transcriptJobId, {
      error: { ...error, traceId: `tr_${ulid()}` }
    });
    if (current.status === to || current.status === 'ready' || current.status === 'failed_terminal') return;
    try {
      this.options.store.setTranscriptJobStatus(current.transcriptJobId, current.status, to);
    } catch {
      // leave the latest status if a concurrent worker already moved it
    }
  }

  private reload(researchId: string, transcriptJobId: string): V2TranscriptJobRecord {
    const job = this.options.store.getTranscriptJob(researchId, transcriptJobId);
    if (!job) {
      throw new DomainError('TRANSCRIPT_JOB_NOT_FOUND', 'transcript job is missing', false, 404);
    }
    return job;
  }

  private project(job: V2TranscriptJobRecord): TranscriptJobWire {
    const error = job.error as TranscriptJobWire['error'] | null;
    return {
      transcriptJobId: job.transcriptJobId,
      researchId: job.researchId,
      sourceId: job.sourceId,
      contentKey: job.contentKey,
      v10JobId: job.v10JobId,
      status: job.status,
      installStatus: job.installStatus,
      progress: job.progress,
      artifactId: job.artifactId,
      error: error && typeof error === 'object' ? error : null,
      updatedAt: job.updatedAt
    };
  }
}

export function contentKeyFor(source: TranscriptSource): string {
  if (source.platform === 'youtube') {
    return videoContentKey('youtube', source.nativeSourceId);
  }
  return podcastContentKey(source.feedURL as string, source.nativeSourceId);
}

export function sourceBelongsToResearch(
  store: V2Store,
  writer: ArtifactWriter,
  researchId: string,
  source: TranscriptSource
): boolean {
  const kinds = source.platform === 'youtube' ? ['youtube_search'] : ['podcast_search'];
  for (const kind of kinds) {
    for (const artifact of store.listArtifacts(researchId, kind, 'ready')) {
      let body: string;
      try {
        body = writer.get(artifact.artifactId).text;
      } catch {
        continue;
      }
      if (searchArtifactMentions(body, source)) return true;
    }
  }
  return false;
}

function searchArtifactMentions(body: string, source: TranscriptSource): boolean {
  try {
    const doc = JSON.parse(body) as { results?: Array<{ sourceId?: string; canonicalURL?: string }> };
    return (doc.results ?? []).some(
      (row) => row.sourceId === source.nativeSourceId || row.canonicalURL === source.canonicalURL
    );
  } catch {
    return body.includes(source.nativeSourceId) || body.includes(source.canonicalURL);
  }
}

function v10SourcePayload(source: TranscriptSource): Record<string, unknown> {
  if (source.platform === 'youtube') {
    return {
      platform: 'youtube',
      sourceId: source.nativeSourceId,
      url: source.canonicalURL,
      title: source.title
    };
  }
  return {
    platform: 'rss',
    sourceId: source.nativeSourceId,
    url: source.enclosureUrl,
    feedUrl: source.feedURL,
    title: source.title
  };
}

function clampProgress(value: number | undefined): number {
  if (value == null || !Number.isFinite(value)) return 0;
  return Math.min(1, Math.max(0, value));
}

function mapV10Error(error: unknown): { code: string; message: string; retryable: boolean } {
  if (error instanceof DomainError) {
    return { code: error.code, message: error.message, retryable: error.retryable };
  }
  const record = error as { code?: string; status?: number; message?: string; retryable?: boolean };
  if (record.code === 'V10_UNAUTHORIZED' || record.status === 401) {
    return { code: 'V10_UNAUTHORIZED', message: 'assistant-to-V10 token rejected', retryable: false };
  }
  if (record.retryable === false || (record.status != null && record.status >= 400 && record.status < 500 && record.status !== 408 && record.status !== 429)) {
    return { code: record.code ?? 'V10_REQUEST_REJECTED', message: record.message || 'content request rejected', retryable: false };
  }
  if (record.code === 'V10_UNAVAILABLE' || (record.status != null && record.status >= 500)) {
    return { code: 'V10_UNAVAILABLE', message: 'V10 timeout or server error', retryable: true };
  }
  return { code: 'V10_UNAVAILABLE', message: record.message || 'content prepare failed', retryable: true };
}

async function defaultSleep(ms: number, signal?: AbortSignal): Promise<void> {
  if (ms <= 0) return;
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(resolve, ms);
    const onAbort = () => {
      clearTimeout(timer);
      reject(new DomainError('TURN_CANCELLED', 'transcription poll cancelled', false, 409));
    };
    if (signal?.aborted) {
      onAbort();
      return;
    }
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}

export { issueConfirmationToken, hashConfirmationToken } from './confirmation.js';
export { TranscriptInstaller, type TranscriptSource, transcriptRelativeDir } from './transcript-installer.js';
export {
  decodeAndStripSourceOnly,
  encodeSourceOnlyJson,
  encodeSourceOnlyMarkdown,
  containsTranslationLeak
} from './source-only.js';
