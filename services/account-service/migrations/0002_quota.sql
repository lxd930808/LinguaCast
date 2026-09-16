-- V18 WP04 daily quota: reservations and an append-only ledger.
-- (account_id, kind, operation_key) is the idempotency key of one logical
-- operation. The ledger is never cleared; inconsistencies are corrected by
-- appending 'adjust' rows.

CREATE TABLE quota_reservations (
  reservation_id  TEXT PRIMARY KEY,
  account_id      TEXT NOT NULL,
  kind            TEXT NOT NULL CHECK (kind IN ('media', 'assistant')),
  operation_key   TEXT NOT NULL,
  amount          INTEGER NOT NULL CHECK (amount > 0),
  period_key      TEXT NOT NULL,
  status          TEXT NOT NULL CHECK (status IN ('reserved', 'consumed', 'released')),
  reason          TEXT,
  service         TEXT NOT NULL,
  subject_ref     TEXT,
  created_at      INTEGER NOT NULL,
  settled_at      INTEGER,
  UNIQUE (account_id, kind, operation_key)
);
CREATE INDEX quota_reservations_period ON quota_reservations (account_id, kind, period_key, status);
CREATE INDEX quota_reservations_open ON quota_reservations (status, created_at);

CREATE TABLE quota_ledger (
  entry_id        INTEGER PRIMARY KEY AUTOINCREMENT,
  reservation_id  TEXT NOT NULL REFERENCES quota_reservations(reservation_id),
  account_id      TEXT NOT NULL,
  kind            TEXT NOT NULL,
  period_key      TEXT NOT NULL,
  action          TEXT NOT NULL CHECK (action IN ('reserve', 'consume', 'release', 'adjust')),
  amount          INTEGER NOT NULL,
  reason          TEXT,
  created_at      INTEGER NOT NULL
);
CREATE INDEX quota_ledger_period ON quota_ledger (account_id, kind, period_key);
