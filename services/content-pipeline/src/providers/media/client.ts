// HTTP client for the local-youtube-media-service (media-api 0.2.0).
// Wire contract (frozen by tools/local-youtube-media-service):
//   POST   /v1/videos/{videoId}/prepare  → 202 { jobId, status, statusUrl }
//   GET    /v1/jobs/{jobId}              → 200 { ...MediaJob } | 404 | 410
//   DELETE /v1/jobs/{jobId}              → 200 { jobId, deleted: true } | 404
// Auth is a Bearer token; error bodies are { error, message }.
// The token is never logged and never sent anywhere but the configured
// base URL (loopback/host-gateway in production).

import {
  MediaServiceError,
  isTerminalMediaStatus,
  type MediaJobStatus,
  type MediaJobView,
  type MediaPrepareRequest,
  type MediaServiceClient,
  type PrepareMediaResult
} from './types.js';
import { ACCOUNT_CONTEXT_HEADER, signAccountContext } from '../../auth/account-context.js';

export interface MediaServiceClientOptions {
  baseUrl: string;
  token: string;
  /** HMAC key for the signed account context; without it no context header is sent (selfhost). */
  contextSigningKey?: string | null;
  /** Owner of the calls made through this client instance. */
  ownerScope?: string | null;
  /** Injectable for tests. */
  fetchImpl?: typeof fetch;
  requestTimeoutMs?: number;
}

const VALID_STATUSES: ReadonlySet<string> = new Set([
  'queued',
  'resolving',
  'fetching',
  'packaging',
  'ready',
  'failed'
]);

export class HttpMediaServiceClient implements MediaServiceClient {
  private readonly baseUrl: string;
  private readonly token: string;
  private readonly fetchImpl: typeof fetch;
  private readonly requestTimeoutMs: number;

  constructor(private readonly options: MediaServiceClientOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, '');
    this.token = options.token;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.requestTimeoutMs = options.requestTimeoutMs ?? 15_000;
  }

  forAccount(ownerScope: string): MediaServiceClient {
    return new HttpMediaServiceClient({ ...this.options, ownerScope });
  }

  private contextHeader(): Record<string, string> {
    const { contextSigningKey, ownerScope } = this.options;
    if (!contextSigningKey || !ownerScope) return {};
    const selfhost = ownerScope === 'selfhost';
    return {
      [ACCOUNT_CONTEXT_HEADER]: signAccountContext(
        { accountId: ownerScope, authMode: selfhost ? 'selfhost' : 'apple', sessionId: null, issuer: 'content-pipeline' },
        contextSigningKey
      )
    };
  }

  async prepare(request: MediaPrepareRequest, signal?: AbortSignal): Promise<PrepareMediaResult> {
    const body: Record<string, unknown> = {};
    if (request.mode) body.mode = request.mode;
    if (request.preferredHeight) body.preferredHeight = request.preferredHeight;

    const response = await this.request(
      'POST',
      `/v1/videos/${encodeURIComponent(request.videoId)}/prepare`,
      body,
      signal
    );
    // prepare returns 202 whether the job is new or deduped onto an active one.
    const jobId = expectString(response, 'jobId');
    const status = expectStatus(response, 'status');
    return { jobId, status };
  }

  async getJob(jobId: string, signal?: AbortSignal): Promise<MediaJobView> {
    const response = await this.request('GET', `/v1/jobs/${encodeURIComponent(jobId)}`, null, signal);
    return parseJobView(response, jobId);
  }

  async probeDuration(videoId: string, signal?: AbortSignal): Promise<number | null> {
    const response = await this.request('POST', `/v1/videos/${encodeURIComponent(videoId)}/probe`, {}, signal, 90_000);
    const value = response.durationSeconds;
    return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : null;
  }

  async cancel(jobId: string, signal?: AbortSignal): Promise<void> {
    try {
      await this.request('DELETE', `/v1/jobs/${encodeURIComponent(jobId)}`, null, signal);
    } catch (error) {
      // Evicted/already-deleted jobs are the goal state of a cancel.
      if (error instanceof MediaServiceError && error.kind === 'not_found') return;
      throw error;
    }
  }

  private async request(
    method: string,
    path: string,
    body: Record<string, unknown> | null,
    signal?: AbortSignal,
    timeoutMs?: number
  ): Promise<Record<string, unknown>> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(new Error('media-api request timed out')), timeoutMs ?? this.requestTimeoutMs);
    const onAbort = () => controller.abort(signal?.reason);
    signal?.addEventListener('abort', onAbort, { once: true });
    try {
      const res = await this.fetchImpl(`${this.baseUrl}${path}`, {
        method,
        headers: {
          authorization: `Bearer ${this.token}`,
          ...this.contextHeader(),
          ...(body ? { 'content-type': 'application/json' } : {})
        },
        body: body ? JSON.stringify(body) : null,
        signal: controller.signal
      });
      const text = await res.text();
      const json = text ? safeParseJson(text) : null;
      if (!res.ok) {
        throw toMediaServiceError(res.status, res.headers, json);
      }
      if (json === null || typeof json !== 'object' || Array.isArray(json)) {
        throw new MediaServiceError('unavailable', 'media-api returned a non-JSON success body', {
          status: res.status
        });
      }
      return json as Record<string, unknown>;
    } catch (error) {
      if (error instanceof MediaServiceError) throw error;
      // AbortError from our timeout or the caller's signal.
      if (signal?.aborted) throw error;
      throw new MediaServiceError('unavailable', 'media-api request failed', { cause: error });
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
    }
  }
}

function safeParseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function toMediaServiceError(
  status: number,
  headers: Headers,
  json: unknown
): MediaServiceError {
  const record = json && typeof json === 'object' && !Array.isArray(json)
    ? (json as Record<string, unknown>)
    : {};
  const upstreamCode = typeof record.error === 'string' ? record.error : undefined;
  const message = typeof record.message === 'string' ? record.message : `media-api HTTP ${status}`;
  const retryAfterSeconds = parseRetryAfter(headers.get('retry-after'));

  if (status === 401 || status === 403) {
    return new MediaServiceError('unauthorized', 'media-api rejected the configured token', {
      status,
      upstreamCode
    });
  }
  if (status === 404) {
    return new MediaServiceError('not_found', message, { status, upstreamCode });
  }
  if (status === 410 || upstreamCode === 'MEDIA_EXPIRED') {
    return new MediaServiceError('expired', message, { status, upstreamCode });
  }
  if (status === 507 || upstreamCode === 'DISK_FULL') {
    return new MediaServiceError('disk_full', message, { status, upstreamCode });
  }
  if (status === 429 || upstreamCode === 'BUSY') {
    return new MediaServiceError('busy', message, { status, upstreamCode, retryAfterSeconds });
  }
  if (status >= 400 && status < 500) {
    return new MediaServiceError('invalid_request', message, { status, upstreamCode });
  }
  return new MediaServiceError('unavailable', message, {
    status,
    upstreamCode,
    retryAfterSeconds
  });
}

function parseRetryAfter(header: string | null): number | undefined {
  if (!header) return undefined;
  const seconds = Number(header);
  return Number.isFinite(seconds) && seconds >= 0 ? seconds : undefined;
}

function expectString(json: Record<string, unknown>, key: string): string {
  const value = json[key];
  if (typeof value !== 'string' || value.length === 0) {
    throw new MediaServiceError('unavailable', `media-api response missing ${key}`);
  }
  return value;
}

function expectStatus(json: Record<string, unknown>, key: string): MediaJobStatus {
  const value = json[key];
  if (typeof value !== 'string' || !VALID_STATUSES.has(value)) {
    throw new MediaServiceError('unavailable', `media-api response has invalid ${key}`);
  }
  return value as MediaJobStatus;
}

function parseJobView(json: Record<string, unknown>, requestedJobId: string): MediaJobView {
  const jobId = expectString(json, 'jobId');
  if (jobId !== requestedJobId) {
    // Defensive: never act on a job we did not ask about.
    throw new MediaServiceError('unavailable', 'media-api returned a mismatched jobId');
  }
  const status = expectStatus(json, 'status');
  const playbackRaw = json.playback;
  const playback =
    playbackRaw && typeof playbackRaw === 'object' && !Array.isArray(playbackRaw)
      ? (playbackRaw as Record<string, unknown>)
      : null;

  return {
    jobId,
    videoId: typeof json.videoId === 'string' ? json.videoId : '',
    status,
    progress: typeof json.progress === 'number' ? json.progress : 0,
    expiresAt: typeof json.expiresAt === 'number' ? json.expiresAt : 0,
    errorCode: typeof json.errorCode === 'string' ? (json.errorCode as MediaJobView['errorCode']) : null,
    errorMessage: typeof json.errorMessage === 'string' ? json.errorMessage : null,
    playback: playback
      ? {
          kind: playback.kind === 'hls' ? 'hls' : 'mp4',
          url: typeof playback.url === 'string' ? playback.url : '',
          audioUrl: typeof playback.audioUrl === 'string' ? playback.audioUrl : undefined,
          height: typeof playback.height === 'number' ? playback.height : null,
          durationSeconds:
            typeof playback.durationSeconds === 'number' ? playback.durationSeconds : null,
          videoCodec: typeof playback.videoCodec === 'string' ? playback.videoCodec : null,
          audioCodec: typeof playback.audioCodec === 'string' ? playback.audioCodec : null,
          itagVideo: typeof playback.itagVideo === 'number' ? playback.itagVideo : null,
          itagAudio: typeof playback.itagAudio === 'number' ? playback.itagAudio : null
        }
      : null
  };
}

/**
 * Hard guarantee of "at most one media-api job at a time" (WP7 rule 5).
 * The content worker already serializes jobs; this gate protects against a
 * second caller (tests, future admin endpoints) preparing concurrently.
 * A prepare that arrives while another media job is in flight fails fast
 * with kind 'busy' instead of queueing silently.
 */
export class SingleFlightMediaGate implements MediaServiceClient {
  private inFlight = false;

  constructor(private readonly inner: MediaServiceClient) {}

  /** Account-scoped view that shares this gate's single-flight state. */
  forAccount(ownerScope: string): MediaServiceClient {
    const scoped = this.inner.forAccount ? this.inner.forAccount(ownerScope) : this.inner;
    return {
      prepare: (request, signal) => this.gatedPrepare(scoped, request, signal),
      getJob: (jobId, signal) => this.gatedGetJob(scoped, jobId, signal),
      cancel: (jobId, signal) => this.gatedCancel(scoped, jobId, signal),
      probeDuration: (videoId, signal) => (scoped.probeDuration ? scoped.probeDuration(videoId, signal) : Promise.resolve(null))
    };
  }

  prepare(request: MediaPrepareRequest, signal?: AbortSignal): Promise<PrepareMediaResult> {
    return this.gatedPrepare(this.inner, request, signal);
  }

  getJob(jobId: string, signal?: AbortSignal): Promise<MediaJobView> {
    return this.gatedGetJob(this.inner, jobId, signal);
  }

  cancel(jobId: string, signal?: AbortSignal): Promise<void> {
    return this.gatedCancel(this.inner, jobId, signal);
  }

  /** Metadata probes do not start media work and are not single-flighted. */
  probeDuration(videoId: string, signal?: AbortSignal): Promise<number | null> {
    return this.inner.probeDuration ? this.inner.probeDuration(videoId, signal) : Promise.resolve(null);
  }

  private async gatedPrepare(
    inner: MediaServiceClient,
    request: MediaPrepareRequest,
    signal?: AbortSignal
  ): Promise<PrepareMediaResult> {
    if (this.inFlight) {
      throw new MediaServiceError('busy', 'another media job is already in flight', {
        retryAfterSeconds: 30
      });
    }
    this.inFlight = true;
    try {
      return await inner.prepare(request, signal);
    } catch (error) {
      this.inFlight = false;
      throw error;
    }
  }

  private async gatedGetJob(inner: MediaServiceClient, jobId: string, signal?: AbortSignal): Promise<MediaJobView> {
    const view = await inner.getJob(jobId, signal);
    if (this.inFlight && isTerminalMediaStatus(view.status)) {
      this.inFlight = false;
    }
    return view;
  }

  private async gatedCancel(inner: MediaServiceClient, jobId: string, signal?: AbortSignal): Promise<void> {
    await inner.cancel(jobId, signal);
    this.inFlight = false;
  }
}
