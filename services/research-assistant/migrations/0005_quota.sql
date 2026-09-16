-- V18 WP04 assistant turn quota. Upgrade-only; earlier files are frozen.
-- Each submitted turn reserves one assistant unit under assistant-turn:<turnId>.
-- Intents cover reserve→insert; the outbox makes settlement durable.

ALTER TABLE v2_turns ADD COLUMN operation_key TEXT;
ALTER TABLE v2_turns ADD COLUMN reservation_id TEXT;

CREATE INDEX v2_turns_status_created ON v2_turns (status, created_at);

CREATE TABLE quota_intents (
  operation_key  TEXT PRIMARY KEY,
  owner_scope    TEXT NOT NULL,
  turn_id        TEXT NOT NULL,
  amount         INTEGER NOT NULL,
  created_at     INTEGER NOT NULL
);

CREATE TABLE quota_settlement_outbox (
  reservation_id  TEXT PRIMARY KEY,
  outcome         TEXT NOT NULL CHECK (outcome IN ('consumed', 'released')),
  reason          TEXT NOT NULL,
  turn_id         TEXT,
  attempts        INTEGER NOT NULL DEFAULT 0,
  last_error      TEXT,
  created_at      INTEGER NOT NULL,
  delivered_at    INTEGER
);
CREATE INDEX quota_outbox_pending ON quota_settlement_outbox (delivered_at, created_at);
