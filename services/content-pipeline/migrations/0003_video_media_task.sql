CREATE TABLE video_media_task (
  content_id INTEGER PRIMARY KEY REFERENCES content(id),
  job_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('queued','running','ready','failed')),
  attempts INTEGER NOT NULL DEFAULT 0,
  failure_code TEXT,
  updated_at INTEGER NOT NULL
);
