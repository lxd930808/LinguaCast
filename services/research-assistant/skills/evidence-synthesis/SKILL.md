---
name: evidence-synthesis
version: 1.0.0
description: Retrieve cross-source evidence, keep conflicts, name gaps, and emit citation packs.
allowedTools:
  - retrieve_evidence
  - get_artifact
  - grep_files
  - search_files
  - list_files
  - read_file
trigger: Enough artifacts exist to answer, or the model must explain why evidence is missing.
---

# evidence-synthesis

## When to use

Use before writing a report or a content-QA answer.

## Inputs

- Current Research ID only. Never retrieve other researches.
- Confirmed global preferences may appear as preference, not as facts.

## Allowed tools

Only frontmatter tools.

## Evidence ranking

primary_content → transcript → platform metadata → search_metadata → research_note. Preferences are not facts.

## Conflicts and gaps

Keep conflicting sources side by side. If no locatable artifact exists, return a structured gap; do not merge into one silent conclusion.

## Artifacts

Citation objects must include artifact ID, hash/version, passage ID, and evidence level.
