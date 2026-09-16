-- V12 content-level video media assets. Upgrade-only; 0001_init.sql is frozen.
-- Video playback identity is content_id (owner-scoped via the content table),
-- not job ID, subtitle language, or translation quality.

CREATE TABLE content_media_asset (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  media_id          TEXT NOT NULL UNIQUE,
  content_id        INTEGER NOT NULL REFERENCES content(id),
  kind              TEXT NOT NULL,              -- video_mp4
  rendition_key     TEXT NOT NULL,
  state             TEXT NOT NULL,              -- promoting | ready | invalid | deleting
  fingerprint       TEXT NOT NULL,
  object_key        TEXT,
  mime_type         TEXT,
  bytes             INTEGER,
  sha256            TEXT,
  duration_seconds  REAL,
  height            INTEGER,
  video_codec       TEXT,
  audio_codec       TEXT,
  accept_ranges     TEXT,
  is_current        INTEGER NOT NULL DEFAULT 0,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL,
  last_accessed_at  INTEGER,
  retain_until      INTEGER,
  failure_code      TEXT,
  UNIQUE (content_id, kind, rendition_key, fingerprint)
);

CREATE INDEX content_media_asset_current
  ON content_media_asset (content_id, kind, is_current);

CREATE INDEX content_media_asset_cleanup
  ON content_media_asset (state, retain_until);
