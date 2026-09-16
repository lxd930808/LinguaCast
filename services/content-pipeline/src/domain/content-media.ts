/**
 * Content-level video media asset model (V12).
 * Wire identity is contentKey; mediaId is an opaque diagnostic id.
 */

export type ContentMediaKind = 'video_mp4';
export type ContentMediaState = 'promoting' | 'ready' | 'invalid' | 'deleting';

export const MEDIA_KIND_VIDEO_MP4: ContentMediaKind = 'video_mp4';

export interface ContentMediaAsset {
  id: number;
  mediaId: string;
  contentId: number;
  kind: ContentMediaKind;
  renditionKey: string;
  state: ContentMediaState;
  fingerprint: string;
  objectKey: string | null;
  mimeType: string | null;
  bytes: number | null;
  sha256: string | null;
  durationSeconds: number | null;
  height: number | null;
  videoCodec: string | null;
  audioCodec: string | null;
  acceptRanges: string | null;
  isCurrent: boolean;
  createdAt: number;
  updatedAt: number;
  lastAccessedAt: number | null;
  retainUntil: number | null;
  failureCode: string | null;
}

export function videoRenditionKey(height: number, videoCodec: string, audioCodec: string): string {
  const safe = (value: string) => value.toLowerCase().replace(/[^a-z0-9]+/g, '') || 'unknown';
  return `mp4-${Math.round(height)}-${safe(videoCodec)}-${safe(audioCodec)}`;
}

/** Duration mismatch: 500ms or 0.5% of the longer duration, whichever is larger. */
export function durationMismatchExceedsThreshold(videoSeconds: number, audioSeconds: number): boolean {
  const delta = Math.abs(videoSeconds - audioSeconds);
  const longer = Math.max(videoSeconds, audioSeconds);
  const threshold = Math.max(0.5, longer * 0.005);
  return delta > threshold;
}
