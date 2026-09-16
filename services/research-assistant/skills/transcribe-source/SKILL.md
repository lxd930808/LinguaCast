---
name: transcribe-source
version: 1.0.0
description: After a user confirmation token exists, create or reuse a V10 job and install source-only transcripts.
allowedTools:
  - request_transcription
  - get_transcript_job
  - get_artifact
  - get_selected_source
trigger: The user confirmed transcription for a source that already belongs to this Research.
---

# transcribe-source

## When to use

Only after the client sent a confirmation token. The model must not invent or copy a confirmation token.

## Inputs

- `sourceId` in the current Research.
- Server-issued confirmation token from the route layer. Pi cannot construct it.

## Allowed tools

Only frontmatter tools. `request_transcription` fails with `TRANSCRIPT_CONFIRMATION_REQUIRED` without a valid token.

## Budget

Lookup first, then one create per generation variant. Do not call V10 delete.

## Failure exit

V10 errors stay on the TranscriptJob. Do not auto-retry create.

## Artifacts

Source-only `transcript` JSON/Markdown. Discard translation and target-language fields.
