CREATE TABLE sessions (
  session_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  phase TEXT NOT NULL,
  output_language TEXT NOT NULL,
  storefront TEXT NOT NULL,
  target_language TEXT NOT NULL,
  translation_quality TEXT NOT NULL,
  active_turn_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE turns (
  turn_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  status TEXT NOT NULL,
  user_text TEXT NOT NULL,
  error_code TEXT,
  error_message TEXT,
  created_at TEXT NOT NULL,
  started_at TEXT,
  finished_at TEXT
);

CREATE TABLE messages (
  message_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
  turn_id TEXT NOT NULL REFERENCES turns(turn_id) ON DELETE CASCADE,
  role TEXT NOT NULL,
  markdown TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE events (
  event_id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
  turn_id TEXT NOT NULL REFERENCES turns(turn_id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  payload_json TEXT NOT NULL,
  occurred_at TEXT NOT NULL
);

CREATE UNIQUE INDEX events_turn_sequence ON events(turn_id, sequence);
CREATE INDEX events_turn_id ON events(turn_id, event_id);

CREATE TABLE search_runs (
  search_run_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
  turn_id TEXT NOT NULL REFERENCES turns(turn_id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  query TEXT NOT NULL,
  locale TEXT,
  limit_count INTEGER NOT NULL,
  cache_hit INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL,
  error_code TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE search_results (
  search_result_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
  search_run_id TEXT REFERENCES search_runs(search_run_id) ON DELETE SET NULL,
  platform TEXT NOT NULL,
  source_type TEXT NOT NULL,
  source_id TEXT NOT NULL,
  canonical_url TEXT NOT NULL,
  feed_url TEXT,
  title TEXT NOT NULL,
  publisher TEXT,
  published_at TEXT,
  duration_seconds INTEGER,
  description TEXT,
  thumbnail_url TEXT,
  availability TEXT,
  provider TEXT NOT NULL,
  fallback INTEGER NOT NULL DEFAULT 0,
  provenance_json TEXT NOT NULL,
  deep_research_availability TEXT NOT NULL,
  warnings_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE UNIQUE INDEX search_results_session_source ON search_results(session_id, platform, source_id);

CREATE TABLE reports (
  report_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
  turn_id TEXT NOT NULL REFERENCES turns(turn_id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  stage TEXT NOT NULL,
  markdown TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE report_sources (
  report_id TEXT NOT NULL REFERENCES reports(report_id) ON DELETE CASCADE,
  search_result_id TEXT NOT NULL REFERENCES search_results(search_result_id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  reason TEXT,
  PRIMARY KEY (report_id, search_result_id)
);

CREATE TABLE content_bindings (
  binding_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL UNIQUE REFERENCES sessions(session_id) ON DELETE CASCADE,
  search_result_id TEXT NOT NULL REFERENCES search_results(search_result_id),
  content_key TEXT NOT NULL,
  content_type TEXT NOT NULL,
  source_language TEXT NOT NULL,
  target_language TEXT NOT NULL,
  translation_quality TEXT NOT NULL,
  pipeline_version TEXT NOT NULL,
  v10_job_id TEXT,
  v10_status TEXT,
  stage TEXT,
  progress REAL NOT NULL DEFAULT 0,
  index_status TEXT NOT NULL,
  artifact_sha256 TEXT,
  error_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE transcript_documents (
  document_id TEXT PRIMARY KEY,
  content_key TEXT NOT NULL,
  artifact_sha256 TEXT NOT NULL,
  schema_version INTEGER NOT NULL,
  active INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  UNIQUE (content_key, artifact_sha256)
);

CREATE TABLE transcript_chunks (
  chunk_id TEXT PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES transcript_documents(document_id) ON DELETE CASCADE,
  binding_id TEXT REFERENCES content_bindings(binding_id) ON DELETE SET NULL,
  content_key TEXT NOT NULL,
  first_sequence INTEGER NOT NULL,
  last_sequence INTEGER NOT NULL,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  source_text TEXT NOT NULL,
  target_text TEXT NOT NULL,
  normalized_text TEXT NOT NULL
);

CREATE VIRTUAL TABLE transcript_chunks_fts USING fts5(
  source_text,
  target_text,
  normalized_text,
  content='transcript_chunks',
  content_rowid='rowid'
);

CREATE TRIGGER transcript_chunks_ai AFTER INSERT ON transcript_chunks BEGIN
  INSERT INTO transcript_chunks_fts(rowid, source_text, target_text, normalized_text)
  VALUES (new.rowid, new.source_text, new.target_text, new.normalized_text);
END;

CREATE TRIGGER transcript_chunks_ad AFTER DELETE ON transcript_chunks BEGIN
  INSERT INTO transcript_chunks_fts(transcript_chunks_fts, rowid, source_text, target_text, normalized_text)
  VALUES ('delete', old.rowid, old.source_text, old.target_text, old.normalized_text);
END;

CREATE TABLE citations (
  citation_id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL REFERENCES messages(message_id) ON DELETE CASCADE,
  content_key TEXT NOT NULL,
  chunk_id TEXT,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  quote TEXT NOT NULL,
  deep_link TEXT NOT NULL
);

CREATE TABLE idempotency_keys (
  owner_scope TEXT NOT NULL,
  key TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  response_json TEXT NOT NULL,
  status INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (owner_scope, key)
);

CREATE TABLE worker_leases (
  lease_id TEXT PRIMARY KEY,
  turn_id TEXT NOT NULL UNIQUE REFERENCES turns(turn_id) ON DELETE CASCADE,
  worker_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE TABLE search_cache (
  cache_key TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX sessions_updated ON sessions(updated_at DESC, session_id DESC);
CREATE INDEX turns_session ON turns(session_id, created_at);
CREATE INDEX messages_session ON messages(session_id, created_at);
