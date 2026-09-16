---
name: web-research
version: 1.0.0
description: Run controlled web search, fetch allowed pages, and persist search/page artifacts.
allowedTools:
  - web_search
  - fetch_web_page
  - get_artifact
  - save_artifact
  - list_files
  - read_file
  - grep_files
trigger: The plan needs public web evidence and ASSISTANT_WEB_ENABLED is on.
---

# web-research

## When to use

Use after a query plan exists and the user wants public web sources.

## Inputs

- Query string, optional locale, and previously saved search artifact IDs.

## Allowed tools

Only frontmatter tools. Never register GitHub clone, cookies, or arbitrary HTTP.

## Budget

- One configured search provider.
- Fetch only URLs from a search artifact or a user-message URL that passed policy.

## Failure exit

Empty or failed searches still produce a `web_search` artifact. Do not retry every provider.

## Artifacts

`web_search` and `web_page` artifacts. Search summaries are `search_metadata`, never primary content.
