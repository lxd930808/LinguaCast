-- Additive V15 workspace persistence. Do not edit 0001_init.sql or 0002_search_v2.sql.
-- Feature-flag rollback must not run a down migration. V1 tables are untouched.

CREATE TABLE v2_researches (
  research_id TEXT PRIMARY KEY,
  owner_scope TEXT NOT NULL,
  title TEXT NOT NULL,
  status TEXT NOT NULL,
  workspace_status TEXT NOT NULL,
  output_language TEXT NOT NULL,
  storefront TEXT NOT NULL,
  target_language TEXT NOT NULL,
  translation_quality TEXT NOT NULL,
  active_turn_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE v2_workspaces (
  research_id TEXT PRIMARY KEY REFERENCES v2_researches(research_id),
  directory_id TEXT NOT NULL UNIQUE,
  manifest_version INTEGER NOT NULL DEFAULT 1,
  manifest_sha256 TEXT,
  integrity_status TEXT NOT NULL,
  last_recovered_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE v2_turns (
  turn_id TEXT PRIMARY KEY,
  research_id TEXT NOT NULL REFERENCES v2_researches(research_id),
  mode TEXT NOT NULL,
  status TEXT NOT NULL,
  user_text TEXT NOT NULL,
  skill_name TEXT,
  skill_version TEXT,
  skill_sha256 TEXT,
  error_code TEXT,
  error_message TEXT,
  created_at TEXT NOT NULL,
  started_at TEXT,
  finished_at TEXT
);

CREATE TABLE v2_messages (
  message_id TEXT PRIMARY KEY,
  research_id TEXT NOT NULL REFERENCES v2_researches(research_id),
  turn_id TEXT NOT NULL REFERENCES v2_turns(turn_id),
  role TEXT NOT NULL,
  markdown TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE v2_events (
  event_id INTEGER PRIMARY KEY AUTOINCREMENT,
  research_id TEXT NOT NULL REFERENCES v2_researches(research_id),
  turn_id TEXT NOT NULL REFERENCES v2_turns(turn_id),
  type TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  payload_json TEXT NOT NULL,
  occurred_at TEXT NOT NULL
);

CREATE UNIQUE INDEX v2_events_turn_sequence ON v2_events(turn_id, sequence);
CREATE INDEX v2_events_turn_id ON v2_events(turn_id, event_id);

CREATE TABLE v2_artifacts (
  artifact_id TEXT PRIMARY KEY,
  research_id TEXT NOT NULL REFERENCES v2_researches(research_id),
  kind TEXT NOT NULL,
  status TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  media_type TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  sha256 TEXT NOT NULL,
  producer TEXT NOT NULL,
  evidence_level TEXT NOT NULL,
  source_reference_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX v2_artifacts_research ON v2_artifacts(research_id, created_at);
CREATE UNIQUE INDEX v2_artifacts_research_id_status ON v2_artifacts(research_id, artifact_id);

CREATE TABLE v2_workspace_grants (
  research_id TEXT NOT NULL REFERENCES v2_researches(research_id),
  alias TEXT NOT NULL,
  permission TEXT NOT NULL,
  allowed_extensions_json TEXT NOT NULL,
  max_file_bytes INTEGER NOT NULL,
  status TEXT NOT NULL,
  granted_at TEXT NOT NULL,
  PRIMARY KEY (research_id, alias)
);

CREATE TABLE v2_transcript_jobs (
  transcript_job_id TEXT PRIMARY KEY,
  research_id TEXT NOT NULL REFERENCES v2_researches(research_id),
  source_id TEXT NOT NULL,
  content_key TEXT NOT NULL,
  v10_job_id TEXT,
  status TEXT NOT NULL,
  install_status TEXT NOT NULL,
  progress REAL NOT NULL DEFAULT 0,
  artifact_id TEXT REFERENCES v2_artifacts(artifact_id),
  error_json TEXT,
  confirmation_token_hash TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX v2_transcript_jobs_research_source_variant
  ON v2_transcript_jobs(research_id, source_id, content_key);

CREATE TABLE v2_citations (
  citation_id TEXT PRIMARY KEY,
  research_id TEXT NOT NULL REFERENCES v2_researches(research_id),
  message_id TEXT REFERENCES v2_messages(message_id) ON DELETE CASCADE,
  artifact_id TEXT NOT NULL REFERENCES v2_artifacts(artifact_id),
  evidence_level TEXT NOT NULL,
  label TEXT NOT NULL,
  passage_id TEXT,
  start_ms INTEGER,
  end_ms INTEGER,
  source_url TEXT,
  content_key TEXT,
  quote TEXT NOT NULL,
  sha256 TEXT NOT NULL
);

CREATE TABLE v2_memory_entries (
  memory_entry_id TEXT PRIMARY KEY,
  research_id TEXT REFERENCES v2_researches(research_id),
  source_research_id TEXT,
  scope TEXT NOT NULL,
  type TEXT NOT NULL,
  content TEXT NOT NULL,
  status TEXT NOT NULL,
  source_artifact_id TEXT,
  hypothesis INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  confirmed_at TEXT
);

CREATE TABLE v2_memory_proposals (
  proposal_id TEXT PRIMARY KEY,
  research_id TEXT NOT NULL REFERENCES v2_researches(research_id),
  content TEXT NOT NULL,
  reason TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  confirmed_at TEXT,
  rejected_at TEXT,
  memory_entry_id TEXT REFERENCES v2_memory_entries(memory_entry_id)
);

CREATE TABLE v2_idempotency_keys (
  owner_scope TEXT NOT NULL,
  route_scope TEXT NOT NULL,
  key TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  response_json TEXT NOT NULL,
  status INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (owner_scope, route_scope, key)
);

CREATE TABLE v2_worker_leases (
  lease_id TEXT PRIMARY KEY,
  turn_id TEXT NOT NULL UNIQUE REFERENCES v2_turns(turn_id),
  worker_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE TABLE v2_workspace_operations (
  operation_id TEXT PRIMARY KEY,
  research_id TEXT NOT NULL REFERENCES v2_researches(research_id),
  artifact_id TEXT,
  temp_name TEXT NOT NULL,
  target_relative_path TEXT NOT NULL,
  expected_sha256 TEXT,
  stage TEXT NOT NULL,
  error_code TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE v2_passages (
  passage_id TEXT PRIMARY KEY,
  research_id TEXT NOT NULL REFERENCES v2_researches(research_id),
  artifact_id TEXT NOT NULL REFERENCES v2_artifacts(artifact_id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  text TEXT NOT NULL,
  start_ms INTEGER,
  end_ms INTEGER,
  created_at TEXT NOT NULL
);

CREATE VIRTUAL TABLE v2_passages_fts USING fts5(
  text,
  content='v2_passages',
  content_rowid='rowid'
);

CREATE TRIGGER v2_passages_ai AFTER INSERT ON v2_passages BEGIN
  INSERT INTO v2_passages_fts(rowid, text) VALUES (new.rowid, new.text);
END;

CREATE TRIGGER v2_passages_ad AFTER DELETE ON v2_passages BEGIN
  INSERT INTO v2_passages_fts(v2_passages_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
END;

CREATE TRIGGER v2_passages_au AFTER UPDATE ON v2_passages BEGIN
  INSERT INTO v2_passages_fts(v2_passages_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
  INSERT INTO v2_passages_fts(rowid, text) VALUES (new.rowid, new.text);
END;

CREATE INDEX v2_researches_owner_updated ON v2_researches(owner_scope, updated_at DESC, research_id DESC);
CREATE INDEX v2_turns_research ON v2_turns(research_id, created_at);
CREATE INDEX v2_messages_research ON v2_messages(research_id, created_at);
CREATE INDEX v2_operations_stage ON v2_workspace_operations(stage, updated_at);
CREATE INDEX v2_memory_entries_scope ON v2_memory_entries(scope, status);
CREATE INDEX v2_leases_expiry ON v2_worker_leases(expires_at);
