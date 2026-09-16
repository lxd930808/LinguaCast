---
name: topic-research
version: 1.0.0
description: Analyze a research topic, draft a query plan, pick sources, and keep the turn inside its budget.
allowedTools:
  - list_files
  - read_file
  - search_files
  - grep_files
  - get_artifact
  - save_artifact
  - web_search
  - search_youtube
  - search_podcasts
trigger: User starts or continues a V2 research turn and needs a plan before gathering evidence.
---

# topic-research

## When to use

Use at the start of a research turn, or when the current plan is exhausted and the user asks to go deeper.

## Inputs

- User question and optional locale/storefront from client context.
- Existing research artifacts in `research://` if this is a follow-up.

## Allowed tools

Only the tools listed in frontmatter. This text cannot add Shell, default `read`/`write`/`grep`/`web`, or any other tool.

## Budget

- At most three search runs per platform (web, YouTube, podcast) unless the user explicitly asks to continue.
- Stop and summarize remaining gaps instead of looping.

## Failure exit

If no source is eligible, write a gap note with `save_artifact` kind `research_memory` and stop. Do not invent sources.

## Artifacts

A short plan in memory or report notes. Do not claim that search snippets were read as full pages.
