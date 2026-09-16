import { createHash } from 'node:crypto';
import type { IncomingMessage, ServerResponse } from 'node:http';

import type { ServiceConfig } from '../config.js';
import {
  podcastContentKey,
  videoContentKey
} from '../domain/content-key.js';
import {
  pollHintSeconds,
  type ContentSource,
  type JobRow,
  type ContentType,
  type TranslationQuality
} from '../domain/job-model.js';
import {
  IdempotencyConflictError,
  InvalidJobStateError,
  type CreateJobInput,
  type JobStore
} from '../jobs/job-store.js';
import { authenticate } from './auth.js';
import { ulid } from 'ulid';
import { QuotaError, type QuotaClient } from '../quota/quota-client.js';
import type { DurationProber } from '../quota/duration-probe.js';
import type { IdentityResolver } from '../auth/identity.js';
import {
  attachRequestContext,
  BodyTooLargeError,
  InvalidContentTypeError,
  parseUrl,
  readJsonBody,
  sendError,
  sendJson
} from './http-utils.js';

const JOB_RE = /^\/v1\/content-jobs\/([^/]+)$/;
const JOB_RETRY_RE = /^\/v1\/content-jobs\/([^/]+)\/retry$/;
const JOB_LOOKUP_PATH = '/v1/content-jobs:lookup';
const JOBS_PATH = '/v1/content-jobs';

export const SERVER_ARTIFACT_SCHEMA_VERSION = 1;

export interface JobRouteDeps {
  config: ServiceConfig;
  store: JobStore;
  identity?: IdentityResolver;
  /** V18 WP04: present when daily quota is enforced (account mode). */
  quota?: { client: QuotaClient; prober: DurationProber };
}

/** Returns true when the request was handled. */
export async function handleJobRoutes(
  req: IncomingMessage,
  res: ServerResponse,
  deps: JobRouteDeps
): Promise<boolean> {
  const url = parseUrl(req);
  const path = url.pathname;
  const isJobPath =
    path === JOBS_PATH || path === JOB_LOOKUP_PATH || JOB_RE.test(path) || JOB_RETRY_RE.test(path);
  if (!isJobPath) return false;

  const { traceId } = attachRequestContext(res);
  const caller = await authenticate(req, res, deps, traceId);
  if (!caller) return true;
  const owner = caller.identity.accountId;

  try {
    if (path === JOBS_PATH && req.method === 'POST') {
      await createJob(req, res, deps, owner, caller.operationKey);
      return true;
    }
    if (path === JOB_LOOKUP_PATH && req.method === 'GET') {
      lookupJob(url, res, deps, owner);
      return true;
    }
    const retryMatch = JOB_RETRY_RE.exec(path);
    if (retryMatch && req.method === 'POST') {
      await retryJob(retryMatch[1]!, res, deps, owner, traceId);
      return true;
    }
    const jobMatch = JOB_RE.exec(path);
    if (jobMatch && req.method === 'GET') {
      getJob(jobMatch[1]!, res, deps, owner, traceId);
      return true;
    }
    if (jobMatch && req.method === 'DELETE') {
      cancelJob(jobMatch[1]!, res, deps, owner, traceId);
      return true;
    }
    sendError(
      res,
      404,
      { code: 'JOB_NOT_FOUND', message: `No route for ${req.method} ${path}`, retryable: false },
      traceId
    );
    return true;
  } catch (error) {
    return handleRouteError(res, error, traceId);
  }
}

function handleRouteError(res: ServerResponse, error: unknown, traceId: string): true {
  if (error instanceof QuotaError) {
    sendError(
      res,
      error.status,
      {
        code: error.code,
        message: error.message,
        retryable: error.retryable,
        ...(error.retryAfterSeconds !== undefined ? { retryAfterSeconds: error.retryAfterSeconds } : {}),
        ...(error.params ? { params: error.params } : {})
      },
      traceId
    );
    return true;
  }
  if (error instanceof InvalidContentTypeError || error instanceof BodyTooLargeError) {
    sendError(
      res,
      error instanceof BodyTooLargeError ? 413 : 400,
      { code: 'INVALID_REQUEST', message: error.message, retryable: false },
      traceId
    );
    return true;
  }
  if (error instanceof RequestValidationError) {
    sendError(
      res,
      error.status,
      {
        code: error.code,
        message: error.message,
        retryable: false,
        params: error.field ? { field: error.field } : undefined
      },
      traceId
    );
    return true;
  }
  if (error instanceof IdempotencyConflictError) {
    sendError(
      res,
      409,
      { code: 'IDEMPOTENCY_CONFLICT', message: error.message, retryable: false },
      traceId
    );
    return true;
  }
  if (error instanceof InvalidJobStateError) {
    sendError(res, 409, { code: 'INVALID_JOB_STATE', message: error.message, retryable: false }, traceId);
    return true;
  }
  throw error;
}

class RequestValidationError extends Error {
  constructor(
    readonly code: 'INVALID_REQUEST' | 'PIPELINE_VERSION_UNSUPPORTED',
    message: string,
    readonly field?: string,
    readonly status = 400
  ) {
    super(message);
    this.name = 'RequestValidationError';
  }
}

function asString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new RequestValidationError('INVALID_REQUEST', `${field} must be a non-empty string`, field);
  }
  return value;
}

function parseSource(value: unknown): ContentSource {
  if (value === null || typeof value !== 'object') {
    throw new RequestValidationError('INVALID_REQUEST', 'source must be an object', 'source');
  }
  const source = value as Record<string, unknown>;
  const platform = asString(source.platform, 'source.platform');
  if (platform !== 'rss' && platform !== 'youtube') {
    throw new RequestValidationError(
      'INVALID_REQUEST',
      'source.platform must be rss or youtube',
      'source.platform'
    );
  }
  const parsed: ContentSource = {
    platform,
    sourceId: asString(source.sourceId, 'source.sourceId'),
    url: asString(source.url, 'source.url')
  };
  if (source.feedUrl !== undefined) parsed.feedUrl = asString(source.feedUrl, 'source.feedUrl');
  if (source.title !== undefined) parsed.title = asString(source.title, 'source.title');
  return parsed;
}

function requestFingerprint(body: Record<string, unknown>): string {
  return createHash('sha256').update(JSON.stringify(body), 'utf8').digest('hex');
}

async function createJob(
  req: IncomingMessage,
  res: ServerResponse,
  deps: JobRouteDeps,
  owner: string,
  operationKeyHint: string | null
): Promise<void> {
  const body = (await readJsonBody(req, deps.config.maxBodyBytes)) as Record<string, unknown>;

  const contentType = asString(body.contentType, 'contentType') as ContentType;
  if (contentType !== 'podcast_episode' && contentType !== 'video') {
    throw new RequestValidationError(
      'INVALID_REQUEST',
      'contentType must be podcast_episode or video',
      'contentType'
    );
  }
  const contentKey = asString(body.contentKey, 'contentKey');
  const source = parseSource(body.source);
  const sourceLanguage = asString(body.sourceLanguage, 'sourceLanguage');
  const targetLanguage = asString(body.targetLanguage, 'targetLanguage');
  const translationQuality = asString(body.translationQuality, 'translationQuality') as TranslationQuality;
  if (translationQuality !== 'fast' && translationQuality !== 'quality') {
    throw new RequestValidationError(
      'INVALID_REQUEST',
      'translationQuality must be fast or quality',
      'translationQuality'
    );
  }
  const clientVersion = body.clientArtifactSchemaVersion;
  if (typeof clientVersion !== 'number' || !Number.isInteger(clientVersion) || clientVersion < 1) {
    throw new RequestValidationError(
      'INVALID_REQUEST',
      'clientArtifactSchemaVersion must be a positive integer',
      'clientArtifactSchemaVersion'
    );
  }
  if (clientVersion > SERVER_ARTIFACT_SCHEMA_VERSION) {
    throw new RequestValidationError(
      'PIPELINE_VERSION_UNSUPPORTED',
      `clientArtifactSchemaVersion ${clientVersion} is newer than supported version ${SERVER_ARTIFACT_SCHEMA_VERSION}`,
      'clientArtifactSchemaVersion',
      422
    );
  }

  // Re-derive the content key from the source fields (content-keys-v1.md §5).
  const expectedKey =
    contentType === 'podcast_episode'
      ? podcastContentKey(source.feedUrl ?? source.url, source.sourceId)
      : videoContentKey(source.platform, source.sourceId);
  if (expectedKey !== contentKey) {
    throw new RequestValidationError(
      'INVALID_REQUEST',
      'contentKey does not match the re-derived key for the given source',
      'contentKey'
    );
  }

  const idempotencyHeader = req.headers['idempotency-key'];
  const input: CreateJobInput = {
    ownerScope: owner,
    contentType,
    contentKey,
    source,
    sourceLanguage,
    targetLanguage,
    translationQuality,
    pipelineVersion: deps.config.pipelineVersion,
    clientArtifactSchemaVersion: clientVersion,
    idempotencyKey: typeof idempotencyHeader === 'string' ? idempotencyHeader : null,
    requestFingerprint: requestFingerprint(body)
  };
  if (!deps.quota) {
    const { job, reused } = deps.store.createJob(input);
    sendJson(res, reused ? 200 : 202, { ...toJobResponse(job), reused });
    return;
  }
  await createJobWithQuota(res, deps, deps.quota, { ...input, reuseReady: true }, operationKeyHint);
}

function durationUnknown(): QuotaError {
  return new QuotaError(422, 'MEDIA_DURATION_UNKNOWN', 'media duration could not be determined', false);
}

async function probeAmount(deps: JobRouteDeps, prober: DurationProber, input: Pick<CreateJobInput, 'contentType' | 'source'>): Promise<number> {
  const seconds = await prober.probe({ contentType: input.contentType, source: input.source });
  if (seconds === null) throw durationUnknown();
  if (seconds > deps.config.maxMediaDurationSeconds) {
    throw new QuotaError(422, 'MEDIA_TOO_LONG', 'media exceeds the maximum processing duration', false, {
      maxDurationSeconds: deps.config.maxMediaDurationSeconds
    });
  }
  return Math.max(1, Math.ceil(seconds));
}

/**
 * Quota flow (account-v1-integration §3.3): reuse is free; otherwise probe the
 * duration, reserve for the logical operation, then insert the queued job.
 * An intent row covers the gap between reserving and inserting.
 */
async function createJobWithQuota(
  res: ServerResponse,
  deps: JobRouteDeps,
  quota: NonNullable<JobRouteDeps['quota']>,
  input: CreateJobInput,
  operationKeyHint: string | null
): Promise<void> {
  const reusable = deps.store.peekReusable(input);
  if (reusable) {
    sendJson(res, 200, { ...toJobResponse(reusable), reused: true });
    return;
  }
  const amount = await probeAmount(deps, quota.prober, input);
  const jobId = `cj_${ulid()}`;
  let operationKey = operationKeyHint ?? `content-job:${jobId}`;
  deps.store.recordIntent(operationKey, input.ownerScope, jobId, amount);
  let reservation;
  try {
    reservation = await quota.client.reserve({ accountId: input.ownerScope, operationKey, amount, subjectRef: jobId });
    if (reservation.status !== 'reserved') {
      // The logical operation was already settled (an earlier attempt finished or failed): start a new attempt.
      deps.store.deleteIntent(operationKey);
      operationKey = `${operationKey}#${jobId}`;
      deps.store.recordIntent(operationKey, input.ownerScope, jobId, amount);
      reservation = await quota.client.reserve({ accountId: input.ownerScope, operationKey, amount, subjectRef: jobId });
    }
  } catch (error) {
    deps.store.deleteIntent(operationKey);
    throw error;
  }
  let created;
  try {
    created = deps.store.createJob({
      ...input,
      jobId,
      operationKey,
      reservationId: reservation.reservationId,
      quotaSeconds: amount
    });
  } catch (error) {
    deps.store.enqueueSettlement(reservation.reservationId, 'released', 'rejected_before_start', null);
    deps.store.deleteIntent(operationKey);
    throw error;
  }
  deps.store.deleteIntent(operationKey);
  if (created.reused) {
    deps.store.enqueueSettlement(reservation.reservationId, 'released', 'reused_artifact', created.job.jobId);
  }
  sendJson(res, created.reused ? 200 : 202, { ...toJobResponse(created.job), reused: created.reused });
}

function lookupJob(url: URL, res: ServerResponse, deps: JobRouteDeps, owner: string): void {
  const contentType = url.searchParams.get('contentType') as ContentType | null;
  const contentKey = url.searchParams.get('contentKey');
  const targetLanguage = url.searchParams.get('targetLanguage');
  const translationQuality = url.searchParams.get('translationQuality') as TranslationQuality | null;
  if (
    (contentType !== 'podcast_episode' && contentType !== 'video') ||
    !contentKey ||
    !targetLanguage ||
    (translationQuality !== 'fast' && translationQuality !== 'quality')
  ) {
    throw new RequestValidationError(
      'INVALID_REQUEST',
      'lookup requires contentType, contentKey, targetLanguage and translationQuality'
    );
  }
  const job = deps.store.lookupJob(
    owner,
    contentType,
    contentKey,
    targetLanguage,
    translationQuality,
    url.searchParams.get('sourceLanguage')
  );
  sendJson(res, 200, { job: job ? toJobResponse(job) : null });
}

function getJob(jobId: string, res: ServerResponse, deps: JobRouteDeps, owner: string, traceId: string): void {
  const job = deps.store.getJobForOwner(jobId, owner);
  if (!job) {
    sendError(res, 404, { code: 'JOB_NOT_FOUND', message: `Unknown jobId: ${jobId}`, retryable: false }, traceId);
    return;
  }
  sendJson(res, 200, toJobResponse(job));
}

function sendJobNotFound(res: ServerResponse, jobId: string, traceId: string): void {
  sendError(res, 404, { code: 'JOB_NOT_FOUND', message: `Unknown jobId: ${jobId}`, retryable: false }, traceId);
}

async function retryJob(jobId: string, res: ServerResponse, deps: JobRouteDeps, owner: string, traceId: string): Promise<void> {
  const current = deps.store.getJobForOwner(jobId, owner);
  if (!current) return sendJobNotFound(res, jobId, traceId);
  if (deps.quota && current.status === 'failed' && current.error?.retryable) {
    // The failed attempt's reservation was released; a retry is paid for again.
    const amount = current.quotaSeconds ?? (await probeAmount(deps, deps.quota.prober, current));
    const operationKey = `${current.operationKey ?? `content-job:${jobId}`}#retry${current.attemptCount}`;
    const reservation = await deps.quota.client.reserve({ accountId: owner, operationKey, amount, subjectRef: jobId });
    try {
      sendJson(res, 202, toJobResponse(deps.store.retryJobWithReservation(jobId, operationKey, reservation.reservationId, amount)));
    } catch (error) {
      deps.store.enqueueSettlement(reservation.reservationId, 'released', 'rejected_before_start', jobId);
      throw error;
    }
    return;
  }
  const job = deps.store.retryJobForOwner(jobId, owner);
  if (!job) return sendJobNotFound(res, jobId, traceId);
  sendJson(res, 202, toJobResponse(job));
}

function cancelJob(jobId: string, res: ServerResponse, deps: JobRouteDeps, owner: string, traceId: string): void {
  const job = deps.store.cancelJobForOwner(jobId, owner);
  if (!job) return sendJobNotFound(res, jobId, traceId);
  sendJson(res, 200, toJobResponse(job));
}

export function toJobResponse(job: JobRow): Record<string, unknown> {
  return {
    jobId: job.jobId,
    contentType: job.contentType,
    contentKey: job.contentKey,
    source: job.source,
    sourceLanguage: job.sourceLanguage,
    targetLanguage: job.targetLanguage,
    translationQuality: job.translationQuality,
    pipelineVersion: job.pipelineVersion,
    status: job.status,
    ...(job.stage ? { stage: job.stage } : {}),
    progress: job.progress,
    ...(job.stageProgress !== null ? { stageProgress: job.stageProgress } : {}),
    audioReady: job.audioReady,
    subtitlesReady: job.subtitlesReady,
    createdAt: new Date(job.createdAt).toISOString(),
    updatedAt: new Date(job.updatedAt).toISOString(),
    retryAfterSeconds: pollHintSeconds(job.status, job.stage),
    error: job.error,
    artifacts: job.artifacts
  };
}
