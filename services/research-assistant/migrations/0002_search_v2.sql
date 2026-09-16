-- Additive V14 search-run persistence. Do not edit 0001_init.sql.
-- Feature-flag rollback must not run a down migration.

ALTER TABLE search_runs ADD COLUMN intent TEXT;
ALTER TABLE search_runs ADD COLUMN query_plan_json TEXT;
ALTER TABLE search_runs ADD COLUMN language TEXT;
ALTER TABLE search_runs ADD COLUMN filters_json TEXT;
ALTER TABLE search_runs ADD COLUMN raw_count INTEGER;
ALTER TABLE search_runs ADD COLUMN accepted_count INTEGER;
ALTER TABLE search_runs ADD COLUMN latency_ms INTEGER;
ALTER TABLE search_runs ADD COLUMN retry_after_seconds INTEGER;
ALTER TABLE search_runs ADD COLUMN retrieved_at TEXT;
ALTER TABLE search_runs ADD COLUMN parent_run_id TEXT REFERENCES search_runs(search_run_id) ON DELETE SET NULL;
ALTER TABLE search_runs ADD COLUMN correlation_id TEXT;

ALTER TABLE search_results ADD COLUMN rank INTEGER;
ALTER TABLE search_results ADD COLUMN relevance_score REAL;
ALTER TABLE search_results ADD COLUMN match_reason TEXT;
ALTER TABLE search_results ADD COLUMN channel_id TEXT;
ALTER TABLE search_results ADD COLUMN view_count INTEGER;
ALTER TABLE search_results ADD COLUMN like_count INTEGER;
ALTER TABLE search_results ADD COLUMN podcast_index_feed_id INTEGER;
ALTER TABLE search_results ADD COLUMN podcast_index_episode_id INTEGER;
ALTER TABLE search_results ADD COLUMN itunes_id TEXT;
ALTER TABLE search_results ADD COLUMN guid TEXT;
ALTER TABLE search_results ADD COLUMN language TEXT;
ALTER TABLE search_results ADD COLUMN explicit INTEGER;
ALTER TABLE search_results ADD COLUMN enclosure_url TEXT;
ALTER TABLE search_results ADD COLUMN enclosure_type TEXT;
ALTER TABLE search_results ADD COLUMN field_provenance_json TEXT;
ALTER TABLE search_results ADD COLUMN retrieved_at TEXT;
ALTER TABLE search_results ADD COLUMN qualified INTEGER;
ALTER TABLE search_results ADD COLUMN stable_id TEXT;

CREATE TABLE search_run_results (
  search_run_id TEXT NOT NULL REFERENCES search_runs(search_run_id) ON DELETE CASCADE,
  search_result_id TEXT NOT NULL REFERENCES search_results(search_result_id) ON DELETE CASCADE,
  rank INTEGER NOT NULL,
  relevance_score REAL,
  match_reason TEXT,
  provider_rank INTEGER,
  qualified INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (search_run_id, search_result_id)
);

CREATE UNIQUE INDEX search_run_results_run_rank ON search_run_results(search_run_id, rank);
CREATE INDEX search_run_results_result ON search_run_results(search_result_id);
CREATE INDEX search_runs_session_created ON search_runs(session_id, created_at DESC, search_run_id DESC);
CREATE INDEX search_results_stable ON search_results(session_id, stable_id);
