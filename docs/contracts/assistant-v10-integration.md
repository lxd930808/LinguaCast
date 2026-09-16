# Assistant ↔ V10 integration notes (v1)

> **Archived (V18):** describes the removed assistant V1 bind flow. V2 transcript jobs follow `assistant-v2.openapi.yaml`.

> Frozen with V13 WP0. V13 does not modify V10 production code. The existing
> content-job contract is sufficient for bind / reuse / poll / index.

## Used V10 endpoints

| Method | Path | Assistant use |
| --- | --- | --- |
| GET | `/v1/content-jobs:lookup` | Reuse an existing generation variant |
| POST | `/v1/content-jobs` | Create only when lookup returns `job=null` |
| GET | `/v1/content-jobs/{jobId}` | Poll status using `retryAfterSeconds` |
| GET | `/v1/content-artifacts/{jobId}/segments.json` | Authoritative transcript for FTS |

V13 does **not** call V10 DELETE, retry, or `raw-transcript.json`.

## Content key

Reuse `docs/contracts/content-keys-v1.md`:

- YouTube: `video:youtube:<videoId>`
- Podcast episode: `podcast:<feedHash>:<episodeHash>` from normalized feed URL + GUID

The search adapter persists enough canonical fields (`platform`, `sourceId`,
`canonicalURL`, `feedURL`, episode GUID) so the assistant can re-derive the
key. Clients never inject an arbitrary source URL.

## Generation variant

Binding stores the full tuple, not just `contentKey`:

```
(contentType, contentKey, sourceLanguage, targetLanguage, translationQuality, pipelineVersion)
```

Lookup/create always send that tuple. Concurrent prepare of the same variant
must produce at most one V10 job.

## Artifact validation before index

`segments.json` is accepted only when:

1. Manifest file role is `segments` and status is `ready`.
2. `bytes` and `sha256` match the downloaded body.
3. JSON `schemaVersion` is a known integer (v1).
4. Segments have monotonic `sequence` and `startMS <= endMS`.

Failed validation maps to `ARTIFACT_INVALID` / `ARTIFACT_INTEGRITY_FAILED`
and does not activate FTS.

## Golden V10 fixtures already sufficient

The following existing fixtures cover the assistant integration matrix:

| Scenario | Fixture |
| --- | --- |
| Lookup miss → create | `lookup-response-miss.json`, `create-request-video.json` |
| Lookup hit ready | `lookup-response-hit.json`, `job-ready-video.json` |
| Lookup/poll running | `job-running-translating.json` |
| Job failed | `job-failed-retryable.json` |
| Segments schema | `learning-segments-bilingual.json` |
| Manifest role/sha256 | `job-ready-video.json` artifacts.files |

No V10 field-semantic change is required for V13.
