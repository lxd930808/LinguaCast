-- WP2 initial schema. Migrations are versioned and upgrade-only; the runner
-- records each applied version in schema_migration. Never edit an applied
-- migration — add a new file with the next version instead.

CREATE TABLE content (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_scope   TEXT NOT NULL,
  content_type  TEXT NOT NULL,
  content_key   TEXT NOT NULL,
  platform      TEXT NOT NULL,
  source_id     TEXT NOT NULL,
  source_url    TEXT NOT NULL,
  feed_url      TEXT,
  title         TEXT,
  created_at    INTEGER NOT NULL,
  UNIQUE (owner_scope, content_type, content_key)
);

-- Shared source artifacts (prepared audio, raw transcripts). Referenced by
-- variants; deletion requires reference protection (WP3).
CREATE TABLE source_artifact (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  content_id       INTEGER NOT NULL REFERENCES content(id),
  kind             TEXT NOT NULL,              -- audio | raw_transcript | source_segments
  fingerprint      TEXT NOT NULL,
  object_key       TEXT,
  mime_type        TEXT,
  bytes            INTEGER,
  duration_seconds REAL,
  sha256           TEXT,
  transcoded       INTEGER NOT NULL DEFAULT 0,
  created_at       INTEGER NOT NULL,
  UNIQUE (content_id, kind, fingerprint)
);

CREATE TABLE generation_variant (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  content_id          INTEGER NOT NULL REFERENCES content(id),
  source_language     TEXT NOT NULL,
  target_language     TEXT NOT NULL,
  translation_quality TEXT NOT NULL,
  pipeline_version    TEXT NOT NULL,
  dedupe_key          TEXT NOT NULL UNIQUE,
  created_at          INTEGER NOT NULL
);

CREATE TABLE content_job (
  id                           INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id                       TEXT NOT NULL UNIQUE,
  variant_id                   INTEGER NOT NULL REFERENCES generation_variant(id),
  owner_scope                  TEXT NOT NULL,
  idempotency_key              TEXT,
  request_fingerprint          TEXT,
  client_artifact_schema_version INTEGER NOT NULL DEFAULT 1,
  status                       TEXT NOT NULL,
  stage                        TEXT,
  progress                     REAL NOT NULL DEFAULT 0,
  stage_progress               REAL,
  audio_ready                  INTEGER NOT NULL DEFAULT 0,
  subtitles_ready              INTEGER NOT NULL DEFAULT 0,
  error_json                   TEXT,
  artifacts_json               TEXT,
  attempt_count                INTEGER NOT NULL DEFAULT 0,
  lease_owner                  TEXT,
  lease_expires_at             INTEGER,
  created_at                   INTEGER NOT NULL,
  updated_at                   INTEGER NOT NULL
);

-- At most one ACTIVE (non-terminal) job per generation variant. Terminal jobs
-- stay for history; a new submission after failure/expiry inserts a fresh row.
CREATE UNIQUE INDEX content_job_active_variant
  ON content_job (variant_id)
  WHERE status IN ('queued', 'running');

CREATE INDEX content_job_status_lease ON content_job (status, lease_expires_at);
CREATE INDEX content_job_idempotency ON content_job (owner_scope, idempotency_key);

CREATE TABLE stage_checkpoint (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id            TEXT NOT NULL REFERENCES content_job(job_id),
  stage             TEXT NOT NULL,
  input_fingerprint TEXT,
  output_json       TEXT,
  schema_version    INTEGER NOT NULL DEFAULT 1,
  checksum          TEXT,
  reusable          INTEGER NOT NULL DEFAULT 1,
  completed_at      INTEGER NOT NULL,
  UNIQUE (job_id, stage)
);

CREATE TABLE artifact_manifest (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id        TEXT NOT NULL REFERENCES content_job(job_id),
  manifest_json TEXT NOT NULL,
  published_at  INTEGER NOT NULL
);

-- schema_migration is owned by the migration runner itself.
