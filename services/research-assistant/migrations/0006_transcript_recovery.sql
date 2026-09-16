ALTER TABLE v2_transcript_jobs ADD COLUMN request_json TEXT;
ALTER TABLE v2_transcript_jobs ADD COLUMN progress_updated_at TEXT;
UPDATE v2_transcript_jobs SET progress_updated_at = updated_at;
