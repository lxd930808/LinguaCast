-- V18 WP02 account service schema. Migrations are versioned and upgrade-only;
-- never edit an applied migration, add the next version instead.

CREATE TABLE accounts (
  account_id  TEXT PRIMARY KEY,
  auth_mode   TEXT NOT NULL CHECK (auth_mode IN ('apple', 'selfhost')),
  status      TEXT NOT NULL CHECK (status IN ('active', 'disabled', 'deleting', 'deleted')),
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

-- Apple `sub` is the only lookup key; email/name are never stored.
CREATE TABLE apple_identities (
  apple_sub          TEXT PRIMARY KEY,
  account_id         TEXT NOT NULL UNIQUE REFERENCES accounts(account_id),
  client_id          TEXT NOT NULL,
  refresh_token_enc  TEXT,
  created_at         INTEGER NOT NULL,
  updated_at         INTEGER NOT NULL
);

CREATE TABLE auth_challenges (
  challenge_id  TEXT PRIMARY KEY,
  nonce_hash    TEXT NOT NULL,
  platform      TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  expires_at    INTEGER NOT NULL,
  consumed_at   INTEGER
);
CREATE INDEX auth_challenges_expiry ON auth_challenges (expires_at);

CREATE TABLE sessions (
  session_id         TEXT PRIMARY KEY,
  account_id         TEXT NOT NULL REFERENCES accounts(account_id),
  platform           TEXT NOT NULL,
  device_name        TEXT,
  created_at         INTEGER NOT NULL,
  expires_at         INTEGER NOT NULL,
  last_refreshed_at  INTEGER,
  revoked_at         INTEGER,
  revoke_reason      TEXT
);
CREATE INDEX sessions_account ON sessions (account_id);

-- Only SHA-256 digests of opaque credentials are stored.
CREATE TABLE access_tokens (
  token_hash  TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL REFERENCES sessions(session_id),
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL
);
CREATE INDEX access_tokens_session ON access_tokens (session_id);
CREATE INDEX access_tokens_expiry ON access_tokens (expires_at);

CREATE TABLE refresh_tokens (
  token_id         TEXT PRIMARY KEY,
  token_hash       TEXT NOT NULL UNIQUE,
  session_id       TEXT NOT NULL REFERENCES sessions(session_id),
  parent_token_id  TEXT,
  status           TEXT NOT NULL CHECK (status IN ('active', 'rotated', 'superseded', 'revoked')),
  created_at       INTEGER NOT NULL,
  rotated_at       INTEGER
);
CREATE INDEX refresh_tokens_session ON refresh_tokens (session_id);
CREATE INDEX refresh_tokens_parent ON refresh_tokens (parent_token_id);

-- Deletion rows stay as tombstones (no personal data) so backup restores can
-- replay deletions. No foreign key: the tombstone must outlive account rows.
CREATE TABLE account_deletions (
  deletion_id              TEXT PRIMARY KEY,
  account_id               TEXT NOT NULL UNIQUE,
  status                   TEXT NOT NULL CHECK (status IN ('pending', 'in_progress', 'completed')),
  steps_json               TEXT NOT NULL,
  apple_client_id          TEXT,
  apple_refresh_token_enc  TEXT,
  attempts                 INTEGER NOT NULL DEFAULT 0,
  next_attempt_at          INTEGER NOT NULL,
  last_error_code          TEXT,
  requested_at             INTEGER NOT NULL,
  completed_at             INTEGER
);
CREATE INDEX account_deletions_due ON account_deletions (status, next_attempt_at);
