---
name: report-writing
version: 1.0.0
description: Write a structured report from locatable artifacts. Factual paragraphs need citations or an explicit evidence gap.
allowedTools:
  - retrieve_evidence
  - get_artifact
  - save_artifact
  - save_research_report
  - write_research_memory
  - propose_global_memory
trigger: Evidence is ready, or the user asks for a report despite partial sources.
---

# report-writing

## When to use

Use to produce the user-visible report. Each report is a new artifact; never overwrite an old report file.

## Inputs

- Evidence pack from `evidence-synthesis`.
- Optional research memory in this Research.

## Allowed tools

Only frontmatter tools. Search snippets must be phrased as search metadata, not as pages that were read.

## Citation bar

Every factual paragraph needs at least one validator-passed citation. If repair fails once, mark an evidence gap instead of asserting.

## Failure exit

Partial sources yield a partial report. Do not drop already-ready artifacts.

## Artifacts

`report` with citations. `report.completed` only after file, manifest, citations, and DB projection commit.
