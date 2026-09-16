-- V18 WP04 quota integration. Upgrade-only; earlier files are frozen.
-- Jobs remember the logical operation and the account-service reservation that
-- pays for them. Intents cover the window between reserving and inserting the
-- job; the outbox makes settlement durable across crashes (written in the same
-- transaction as the job's terminal status, delivered asynchronously).

ALTER TABLE content_job ADD COLUMN operation_key TEXT;
ALTER TABLE content_job ADD COLUMN reservation_id TEXT;
ALTER TABLE content_job ADD COLUMN quota_seconds INTEGER;

CREATE INDEX content_job_owner_status ON content_job (owner_scope, status, created_at);

CREATE TABLE quota_intents (
  operation_key  TEXT PRIMARY KEY,
  owner_scope    TEXT NOT NULL,
  job_id         TEXT NOT NULL,
  amount         INTEGER NOT NULL,
  created_at     INTEGER NOT NULL
);

CREATE TABLE quota_settlement_outbox (
  reservation_id  TEXT PRIMARY KEY,
  outcome         TEXT NOT NULL CHECK (outcome IN ('consumed', 'released')),
  reason          TEXT NOT NULL,
  job_id          TEXT,
  attempts        INTEGER NOT NULL DEFAULT 0,
  last_error      TEXT,
  created_at      INTEGER NOT NULL,
  delivered_at    INTEGER
);
CREATE INDEX quota_outbox_pending ON quota_settlement_outbox (delivered_at, created_at);
