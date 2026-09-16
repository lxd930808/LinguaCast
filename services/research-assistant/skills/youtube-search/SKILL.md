---
name: youtube-search
version: 1.0.0
description: Search and hydrate YouTube video metadata, then save a provenance-preserving run artifact.
allowedTools:
  - search_youtube
  - get_youtube_video_details
  - get_artifact
  - save_artifact
  - read_search_run
trigger: The topic involves YouTube videos or the plan includes video sources.
---

# youtube-search

## When to use

Use for YouTube discovery. Do not download media or run a second ASR pipeline.

## Inputs

- Query and optional video IDs already in this Research.

## Allowed tools

Only frontmatter tools.

## Budget

Reuse the V14 YouTube search cap. Persist every success, empty, and failure run.

## Failure exit

yt-dlp/API failure becomes a failed run artifact. Continue with other sources.

## Artifacts

`youtube_search` with evidence level `search_metadata`.
