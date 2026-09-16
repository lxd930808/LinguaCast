// Media service provider abstraction (WP7 Phase A). The content pipeline
// treats the local-youtube-media-service (media-api 0.2.0) as an upstream
// provider: it owns YouTube resolution/download; we only consume the
// resulting audioUrl and immediately copy the audio into our own storage —
// media jobs expire after ~45 minutes, so the URL is never a durable ref.
//
// Non-interference rules (plan WP7):
//  - HTTP API only; never reads the media-api data volume, never joins its
//    Docker network, never restarts its container.
//  - At most one media job is prepared at a time (enforced by the single
//    content worker; see SingleFlightMediaGate for the hard guarantee).
//  - Terminal statuses (ready/failed) and 410 expired are always respected.

/** media-api 0.2.0 job lifecycle. */
export type MediaJobStatus =
  | 'queued'
  | 'resolving'
  | 'fetching'
  | 'packaging'
  | 'ready'
  | 'failed';

export type MediaJobErrorCode =
  | 'VIDEO_UNAVAILABLE'
  | 'SABR_REQUEST_FAILED'
  | 'SABR_PARSE_FAILED'
  | 'SABR_ATTESTATION_REQUIRED'
  | 'MEDIA_DOWNLOAD_FAILED'
  | 'UNSUPPORTED_CODEC'
  | 'FFMPEG_FAILED'
  | 'MEDIA_EXPIRED'
  | 'INVALID_VIDEO_ID'
  | 'DISK_FULL'
  | 'BUSY'
  | 'INTERNAL_ERROR';

export interface MediaPlaybackInfo {
  kind: 'mp4' | 'hls';
  url: string;
  audioUrl?: string;
  height: number | null;
  durationSeconds: number | null;
  videoCodec: string | null;
  audioCodec: string | null;
  itagVideo: number | null;
  itagAudio: number | null;
}

/** Normalized view of GET /v1/jobs/{jobId}. Diagnostics are not consumed. */
export interface MediaJobView {
  jobId: string;
  videoId: string;
  status: MediaJobStatus;
  progress: number;
  /** Epoch ms; the audioUrl must be copied well before this. */
  expiresAt: number;
  errorCode: MediaJobErrorCode | null;
  errorMessage: string | null;
  playback: MediaPlaybackInfo | null;
}

export interface PrepareMediaResult {
  jobId: string;
  status: MediaJobStatus;
}

export interface MediaPrepareRequest {
  videoId: string;
  /** Phase A uses the existing mp4 pipeline; it already yields audioUrl. */
  mode?: 'mp4' | 'hls';
  preferredHeight?: number;
}

export interface MediaServiceClient {
  prepare(request: MediaPrepareRequest, signal?: AbortSignal): Promise<PrepareMediaResult>;
  getJob(jobId: string, signal?: AbortSignal): Promise<MediaJobView>;
  /** Best-effort cleanup; 404 is treated as success. */
  cancel(jobId: string, signal?: AbortSignal): Promise<void>;
  /** Client whose calls carry the signed context of the job's owning account (V18). */
  forAccount?(ownerScope: string): MediaServiceClient;
  /** Video duration from media-service metadata, without downloading (V18 quota probe). */
  probeDuration?(videoId: string, signal?: AbortSignal): Promise<number | null>;
}

export function isTerminalMediaStatus(status: MediaJobStatus): boolean {
  return status === 'ready' || status === 'failed';
}

export type MediaClientErrorKind =
  /** Auth rejected — deployment misconfiguration, never retryable. */
  | 'unauthorized'
  /** Unknown jobId on GET (evicted between prepare and poll). */
  | 'not_found'
  /** 410 — media expired before we copied it. */
  | 'expired'
  /** 507 DISK_FULL on prepare. */
  | 'disk_full'
  /** 429 / BUSY — respect retryAfterSeconds. */
  | 'busy'
  /** 4xx request problems (INVALID_VIDEO_ID, INVALID_JSON). */
  | 'invalid_request'
  /** Upstream 5xx or network failure — retryable. */
  | 'unavailable';

export class MediaServiceError extends Error {
  constructor(
    readonly kind: MediaClientErrorKind,
    message: string,
    readonly options: {
      status?: number;
      /** Upstream error code (media job errorCode or HTTP error field). */
      upstreamCode?: string;
      retryAfterSeconds?: number;
      cause?: unknown;
    } = {}
  ) {
    super(message, { cause: options.cause });
    this.name = 'MediaServiceError';
  }
}
