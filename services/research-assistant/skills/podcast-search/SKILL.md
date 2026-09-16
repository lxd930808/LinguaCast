---
name: podcast-search
version: 1.0.0
description: Search podcast shows and episodes, parse RSS under SSRF rules, and save normalized run artifacts.
allowedTools:
  - search_podcasts
  - get_podcast_episodes
  - get_artifact
  - save_artifact
  - read_search_run
trigger: The topic involves audio shows, RSS feeds, or Apple/Podcast Index results.
---

# podcast-search

## When to use

Use when the user asks about podcasts or when the plan includes audio sources.

## Inputs

- Query, storefront, and optional show IDs already in this Research.

## Allowed tools

Only frontmatter tools. Do not fetch arbitrary URLs with `fetch_web_page` from this skill.

## Budget

Reuse the existing V14 per-source search cap. One run artifact per call.

## Failure exit

Provider failure is a failed run artifact, not a blocked turn.

## Artifacts

`podcast_search` with evidence level `search_metadata`.
