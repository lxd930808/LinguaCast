import { ulid } from 'ulid';
import type { DatabaseSync } from 'node:sqlite';

import type { ContentType } from './job-model.js';
import {
  MEDIA_KIND_VIDEO_MP4,
  type ContentMediaAsset,
  type ContentMediaKind,
  type ContentMediaState
} from './content-media.js';

export class ContentMediaStoreError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ContentMediaStoreError';
  }
}

interface RawMediaRow {
  id: number;
  media_id: string;
  content_id: number;
  kind: string;
  rendition_key: string;
  state: string;
  fingerprint: string;
  object_key: string | null;
  mime_type: string | null;
  bytes: number | null;
  sha256: string | null;
  duration_seconds: number | null;
  height: number | null;
  video_codec: string | null;
  audio_codec: string | null;
  accept_ranges: string | null;
  is_current: number;
  created_at: number;
  updated_at: number;
  last_accessed_at: number | null;
  retain_until: number | null;
  failure_code: string | null;
}

const SELECT = `SELECT id, media_id, content_id, kind, rendition_key, state, fingerprint,
  object_key, mime_type, bytes, sha256, duration_seconds, height, video_codec, audio_codec,
  accept_ranges, is_current, created_at, updated_at, last_accessed_at, retain_until, failure_code
  FROM content_media_asset`;

export interface CreatePromotingInput {
  ownerScope: string;
  contentType: ContentType;
  contentKey: string;
  kind?: ContentMediaKind;
  renditionKey: string;
  fingerprint: string;
  now?: number;
}

export interface MarkReadyInput {
  mediaId: string;
  objectKey: string;
  mimeType: string;
  bytes: number;
  sha256: string;
  durationSeconds: number;
  height: number;
  videoCodec: string;
  audioCodec: string;
  acceptRanges?: string;
  retainUntil: number;
  now?: number;
}

export class ContentMediaStore {
  constructor(private readonly db: DatabaseSync) {}

  contentIdForOwner(
    ownerScope: string,
    contentType: ContentType,
    contentKey: string
  ): number | null {
    const row = this.db
      .prepare(
        `SELECT id FROM content WHERE owner_scope = ? AND content_type = ? AND content_key = ?`
      )
      .get(ownerScope, contentType, contentKey) as { id: number } | undefined;
    return row?.id ?? null;
  }

  contentIdForJob(jobId: string): number | null {
    const row = this.db
      .prepare(
        `SELECT c.id AS content_id
         FROM content_job j
         JOIN generation_variant v ON v.id = j.variant_id
         JOIN content c ON c.id = v.content_id
         WHERE j.job_id = ?`
      )
      .get(jobId) as { content_id: number } | undefined;
    return row?.content_id ?? null;
  }

  getByMediaId(mediaId: string): ContentMediaAsset | null {
    const row = this.db.prepare(`${SELECT} WHERE media_id = ?`).get(mediaId) as RawMediaRow | undefined;
    return row ? this.toAsset(row) : null;
  }

  findByFingerprint(
    contentId: number,
    kind: ContentMediaKind,
    renditionKey: string,
    fingerprint: string
  ): ContentMediaAsset | null {
    const row = this.db
      .prepare(
        `${SELECT} WHERE content_id = ? AND kind = ? AND rendition_key = ? AND fingerprint = ?`
      )
      .get(contentId, kind, renditionKey, fingerprint) as RawMediaRow | undefined;
    return row ? this.toAsset(row) : null;
  }

  /**
   * Insert a promoting row, or return the existing unique fingerprint row.
   * Owner scope is recovered through the content table — never by contentKey alone.
   */
  createPromoting(input: CreatePromotingInput): ContentMediaAsset {
    const kind = input.kind ?? MEDIA_KIND_VIDEO_MP4;
    const now = input.now ?? Date.now();
    const contentId = this.contentIdForOwner(input.ownerScope, input.contentType, input.contentKey);
    if (contentId === null) {
      throw new ContentMediaStoreError('content not found for owner scope');
    }
    const mediaId = `cm_${ulid()}`;
    this.db
      .prepare(
        `INSERT INTO content_media_asset
           (media_id, content_id, kind, rendition_key, state, fingerprint, is_current,
            created_at, updated_at)
         VALUES (?, ?, ?, ?, 'promoting', ?, 0, ?, ?)
         ON CONFLICT (content_id, kind, rendition_key, fingerprint) DO NOTHING`
      )
      .run(mediaId, contentId, kind, input.renditionKey, input.fingerprint, now, now);
    const created = this.findByFingerprint(contentId, kind, input.renditionKey, input.fingerprint);
    if (!created) throw new ContentMediaStoreError('failed to persist promoting asset');
    return created;
  }

  /** Publish a verified object as the current ready asset. At most one current ready per content+kind. */
  markReady(input: MarkReadyInput): ContentMediaAsset {
    const now = input.now ?? Date.now();
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const current = this.db
        .prepare(`${SELECT} WHERE media_id = ?`)
        .get(input.mediaId) as RawMediaRow | undefined;
      if (!current) throw new ContentMediaStoreError(`unknown media ${input.mediaId}`);
      this.db
        .prepare(
          `UPDATE content_media_asset SET is_current = 0, updated_at = ?
           WHERE content_id = ? AND kind = ? AND is_current = 1 AND media_id != ?`
        )
        .run(now, current.content_id, current.kind, input.mediaId);
      this.db
        .prepare(
          `UPDATE content_media_asset
             SET state = 'ready', object_key = ?, mime_type = ?, bytes = ?, sha256 = ?,
                 duration_seconds = ?, height = ?, video_codec = ?, audio_codec = ?,
                 accept_ranges = ?, is_current = 1, retain_until = ?, last_accessed_at = ?,
                 failure_code = NULL, updated_at = ?
           WHERE media_id = ?`
        )
        .run(
          input.objectKey,
          input.mimeType,
          input.bytes,
          input.sha256,
          input.durationSeconds,
          input.height,
          input.videoCodec,
          input.audioCodec,
          input.acceptRanges ?? 'bytes',
          input.retainUntil,
          now,
          now,
          input.mediaId
        );
      this.db.exec('COMMIT');
    } catch (error) {
      try {
        this.db.exec('ROLLBACK');
      } catch {
        // already closed
      }
      throw error;
    }
    const ready = this.getByMediaId(input.mediaId);
    if (!ready) throw new ContentMediaStoreError('failed to mark media ready');
    return ready;
  }

  markInvalid(mediaId: string, failureCode: string, now = Date.now()): ContentMediaAsset | null {
    this.db
      .prepare(
        `UPDATE content_media_asset
           SET state = 'invalid', is_current = 0, failure_code = ?, updated_at = ?
         WHERE media_id = ?`
      )
      .run(failureCode, now, mediaId);
    return this.getByMediaId(mediaId);
  }

  currentReadyForContent(
    ownerScope: string,
    contentType: ContentType,
    contentKey: string,
    kind: ContentMediaKind = MEDIA_KIND_VIDEO_MP4
  ): ContentMediaAsset | null {
    const row = this.db
      .prepare(
        `SELECT a.id, a.media_id, a.content_id, a.kind, a.rendition_key, a.state, a.fingerprint,
                a.object_key, a.mime_type, a.bytes, a.sha256, a.duration_seconds, a.height,
                a.video_codec, a.audio_codec, a.accept_ranges, a.is_current, a.created_at,
                a.updated_at, a.last_accessed_at, a.retain_until, a.failure_code
         FROM content_media_asset a
         JOIN content c ON c.id = a.content_id
         WHERE c.owner_scope = ? AND c.content_type = ? AND c.content_key = ?
           AND a.kind = ? AND a.state = 'ready' AND a.is_current = 1`
      )
      .get(ownerScope, contentType, contentKey, kind) as RawMediaRow | undefined;
    return row ? this.toAsset(row) : null;
  }

  promotingForContent(
    ownerScope: string,
    contentType: ContentType,
    contentKey: string,
    kind: ContentMediaKind = MEDIA_KIND_VIDEO_MP4
  ): ContentMediaAsset | null {
    const row = this.db
      .prepare(
        `SELECT a.id, a.media_id, a.content_id, a.kind, a.rendition_key, a.state, a.fingerprint,
                a.object_key, a.mime_type, a.bytes, a.sha256, a.duration_seconds, a.height,
                a.video_codec, a.audio_codec, a.accept_ranges, a.is_current, a.created_at,
                a.updated_at, a.last_accessed_at, a.retain_until, a.failure_code
         FROM content_media_asset a
         JOIN content c ON c.id = a.content_id
         WHERE c.owner_scope = ? AND c.content_type = ? AND c.content_key = ?
           AND a.kind = ? AND a.state = 'promoting'
         ORDER BY a.created_at DESC LIMIT 1`
      )
      .get(ownerScope, contentType, contentKey, kind) as RawMediaRow | undefined;
    return row ? this.toAsset(row) : null;
  }

  hasActiveJobForContent(
    ownerScope: string,
    contentType: ContentType,
    contentKey: string
  ): boolean {
    const row = this.db
      .prepare(
        `SELECT COUNT(*) AS n
         FROM content_job j
         JOIN generation_variant v ON v.id = j.variant_id
         JOIN content c ON c.id = v.content_id
         WHERE c.owner_scope = ? AND c.content_type = ? AND c.content_key = ?
           AND j.status IN ('queued', 'running')`
      )
      .get(ownerScope, contentType, contentKey) as { n: number };
    return Number(row.n) > 0;
  }

  hasActiveJobForContentId(contentId: number): boolean {
    const row = this.db
      .prepare(
        `SELECT COUNT(*) AS n
         FROM content_job j
         JOIN generation_variant v ON v.id = j.variant_id
         WHERE v.content_id = ? AND j.status IN ('queued', 'running')`
      )
      .get(contentId) as { n: number };
    return Number(row.n) > 0;
  }

  touchAccess(mediaId: string, retainUntil: number, now = Date.now()): void {
    this.db
      .prepare(
        `UPDATE content_media_asset
           SET last_accessed_at = ?, retain_until = ?, updated_at = ?
         WHERE media_id = ? AND state = 'ready'`
      )
      .run(now, retainUntil, now, mediaId);
  }

  expiredBatch(now: number, limit: number): ContentMediaAsset[] {
    const rows = this.db
      .prepare(
        `${SELECT}
         WHERE retain_until IS NOT NULL AND retain_until <= ? AND state IN ('ready', 'invalid')
         ORDER BY retain_until ASC LIMIT ?`
      )
      .all(now, limit) as unknown as RawMediaRow[];
    return rows.map((row) => this.toAsset(row));
  }

  markDeleting(mediaId: string, now = Date.now()): void {
    this.db
      .prepare(
        `UPDATE content_media_asset SET state = 'deleting', is_current = 0, updated_at = ? WHERE media_id = ?`
      )
      .run(now, mediaId);
  }

  deleteRecord(mediaId: string): void {
    this.db.prepare('DELETE FROM content_media_asset WHERE media_id = ?').run(mediaId);
  }

  readyBytesTotal(kind: ContentMediaKind = MEDIA_KIND_VIDEO_MP4): number {
    const row = this.db
      .prepare(
        `SELECT COALESCE(SUM(bytes), 0) AS n FROM content_media_asset WHERE state = 'ready' AND kind = ?`
      )
      .get(kind) as { n: number };
    return Number(row.n);
  }

  listByState(state: ContentMediaState, limit = 50): ContentMediaAsset[] {
    const rows = this.db
      .prepare(`${SELECT} WHERE state = ? ORDER BY updated_at ASC LIMIT ?`)
      .all(state, limit) as unknown as RawMediaRow[];
    return rows.map((row) => this.toAsset(row));
  }

  private toAsset(row: RawMediaRow): ContentMediaAsset {
    return {
      id: row.id,
      mediaId: row.media_id,
      contentId: row.content_id,
      kind: row.kind as ContentMediaKind,
      renditionKey: row.rendition_key,
      state: row.state as ContentMediaState,
      fingerprint: row.fingerprint,
      objectKey: row.object_key,
      mimeType: row.mime_type,
      bytes: row.bytes,
      sha256: row.sha256,
      durationSeconds: row.duration_seconds,
      height: row.height,
      videoCodec: row.video_codec,
      audioCodec: row.audio_codec,
      acceptRanges: row.accept_ranges,
      isCurrent: row.is_current === 1,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
      lastAccessedAt: row.last_accessed_at,
      retainUntil: row.retain_until,
      failureCode: row.failure_code
    };
  }
}
