import type { MediaMode } from '../config.js';

export type JobStatus =
  | 'queued'
  | 'resolving'
  | 'fetching'
  | 'packaging'
  | 'ready'
  | 'failed';

export type JobErrorCode =
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

export interface JobPlaybackInfo {
  kind: MediaMode;
  url: string;
  audioUrl?: string;
  height: number | null;
  videoCodec: string | null;
  audioCodec: string | null;
  durationSeconds: number | null;
  itagVideo: number | null;
  itagAudio: number | null;
}

export interface MediaJob {
  jobId: string;
  videoId: string;
  mode: MediaMode;
  preferredHeight: number;
  status: JobStatus;
  progress: number;
  createdAt: number;
  updatedAt: number;
  expiresAt: number;
  errorCode?: JobErrorCode;
  errorMessage?: string;
  workDir: string;
  playback?: JobPlaybackInfo;
  /** R2 object keys to delete when the job is removed. */
  r2Keys?: string[];
  diagnostics: Record<string, unknown>;
}

export interface PrepareRequest {
  mode?: MediaMode;
  preferredHeight?: number;
}

export function mediaUrl(
  publicBaseUrl: string,
  jobId: string,
  fileName: string,
  accessToken?: string | null
): string {
  const base = `${publicBaseUrl.replace(/\/+$/, '')}/media/${encodeURIComponent(jobId)}/${encodeURIComponent(fileName)}`;
  if (!accessToken) return base;
  return `${base}?access_token=${encodeURIComponent(accessToken)}`;
}

export function playbackForCurrentService(
  playback: JobPlaybackInfo | undefined,
  publicBaseUrl: string,
  jobId: string,
  accessToken?: string | null
): JobPlaybackInfo | null {
  if (!playback) return null;
  // Absolute remote URLs (e.g. R2 presigned) must not be rewritten to /media.
  const isRemote = /^https?:\/\//i.test(playback.url) && !playback.url.includes('/media/');
  if (isRemote) {
    return { ...playback };
  }
  switch (playback.kind) {
    case 'mp4':
      return {
        ...playback,
        url: mediaUrl(publicBaseUrl, jobId, 'output.mp4', accessToken),
        audioUrl: playback.audioUrl?.startsWith('http') && !playback.audioUrl.includes('/media/')
          ? playback.audioUrl
          : mediaUrl(publicBaseUrl, jobId, 'audio.m4a', accessToken)
      };
    case 'hls':
      return {
        ...playback,
        url: mediaUrl(publicBaseUrl, jobId, 'master.m3u8', accessToken)
      };
    default:
      return { ...playback };
  }
}

export function isTerminalStatus(status: JobStatus): boolean {
  return status === 'ready' || status === 'failed';
}

export function jobDedupeKey(
  videoId: string,
  mode: MediaMode,
  preferredHeight: number
): string {
  return `${videoId}:${mode}:${preferredHeight}`;
}

const VIDEO_ID_RE = /^[A-Za-z0-9_-]{11}$/;

export function isValidVideoId(videoId: string): boolean {
  return VIDEO_ID_RE.test(videoId);
}
