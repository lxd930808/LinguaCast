# Assistant API Error Codes (assistant-error-codes-v1)

> Contract version: v1 (frozen with V13 WP0). Error codes are stable machine
> identifiers; clients localize by code and must tolerate unknown codes by
> treating them as non-retryable `INTERNAL_ERROR`-class failures.

Every HTTP error uses the envelope:

```json
{
  "error": {
    "code": "TRANSCRIPT_NOT_READY",
    "message": "Transcript is not ready",
    "retryable": true,
    "retryAfterSeconds": 5,
    "traceId": "tr_...",
    "params": {}
  }
}
```

| Field | Meaning |
| --- | --- |
| `code` | Stable machine code from the table below |
| `message` | English technical summary (diagnostic only, never the sole user hint) |
| `retryable` | Whether a client-initiated retry can succeed without new user input |
| `retryAfterSeconds` | Optional suggested delay before retry/poll |
| `traceId` | De-identified correlation ID |
| `params` | Optional stable localization parameters |

Clients must not branch on `message` text, only on `code` and `params`.

## HTTP-level codes

| Code | HTTP | retryable | Meaning |
| --- | --- | --- | --- |
| INVALID_REQUEST | 400 | false | Field validation failed; `params.field` names the field |
| UNAUTHORIZED | 401 | false | Missing or invalid assistant Bearer token |
| FORBIDDEN | 403 | false | Session/turn belongs to another owner scope |
| SESSION_NOT_FOUND | 404 | false | Unknown or deleted sessionId |
| TURN_NOT_FOUND | 404 | false | Unknown turnId |
| BINDING_NOT_FOUND | 404 | false | Unknown bindingId for this session |
| SEARCH_RESULT_NOT_FOUND | 404 | false | searchResultId not in this session |
| IDEMPOTENCY_CONFLICT | 409 | false | Idempotency-Key reused with a different payload |
| TURN_ALREADY_RUNNING | 409 | false | Session already has a queued/running turn |
| INVALID_SESSION_PHASE | 409 | false | Request is illegal in the current session phase |
| EVENT_CURSOR_EXPIRED | 409 | false | Last-Event-ID is older than the retained event window; take a REST snapshot |
| SOURCE_NOT_SELECTABLE | 409 | false | Result was not recommended by any report in this session |
| TRANSCRIPT_NOT_READY | 409 | true | QA submitted before index is ready |
| PIPELINE_VERSION_UNSUPPORTED | 422 | false | client schema newer than server support |
| SOURCE_RATE_LIMITED | 429 | true | Caller rate limit; honor `retryAfterSeconds` |
| QUEUE_BUSY | 503 | true | Worker/queue saturated or SQLite busy |
| STORAGE_FULL | 503 | true | Disk watermark hit; history remains readable |
| MODEL_NOT_CONFIGURED | 503 | false | Pi config has no usable model |
| INTERNAL_ERROR | 500 | false | Unclassified server error; see `traceId` |

## Turn-level / recoverable codes

These may appear on a failed turn, a binding snapshot, or a source-level warning.

| Code | retryable | Meaning |
| --- | --- | --- |
| TURN_INTERRUPTED | true | Process restart cancelled an in-flight model turn; retry creates a new turn |
| TURN_BUDGET_EXCEEDED | false | Search count, candidate count, model steps, tool time, or output chars exceeded |
| TURN_CANCELLED | false | User cancelled the turn |
| MODEL_PROVIDER_UNAVAILABLE | true | Pi primary and configured fallbacks all failed |
| TOOL_LIMIT_EXCEEDED | false | Per-turn search/tool call limit reached |
| YTDLP_TIMEOUT | true | yt-dlp exceeded 30s or output cap |
| YTDLP_INVALID_OUTPUT | true | yt-dlp JSON unusable after filtering |
| YOUTUBE_QUOTA_EXCEEDED | true | YouTube Data API quota exhausted |
| YOUTUBE_SEARCH_UNAVAILABLE | true | yt-dlp failed and no API key / API also failed |
| APPLE_SEARCH_UNAVAILABLE | true | Apple Search API failed |
| RSS_UNAVAILABLE | true | Feed fetch failed after SSRF-safe checks |
| SOURCE_URL_BLOCKED | false | RSS/source URL rejected by SSRF policy |
| CONTENT_NOT_SUPPORTED | false | Result cannot enter deep research (show-only, live, missing ID) |
| V10_UNAUTHORIZED | false | Assistant-to-V10 token rejected |
| V10_UNAVAILABLE | true | V10 timeout/5xx; binding retained |
| V10_JOB_FAILED | true | V10 job failed; assistant does not auto-retry |
| ARTIFACT_INVALID | false | segments.json failed role/schema/bytes/sha256 checks |
| ARTIFACT_INTEGRITY_FAILED | false | Downloaded artifact checksum mismatch |
| INDEX_BUILD_FAILED | true | FTS index build failed; previous index kept if any |
| TRANSCRIPT_EVIDENCE_NOT_FOUND | false | QA found no usable evidence in the current transcript |
| CITATION_VALIDATION_FAILED | true | Model citations failed verifier after one repair attempt |
| PODCASTINDEX_NOT_CONFIGURED | false | Podcast Index key/secret missing; Apple/RSS fallback may still run |
| PODCASTINDEX_AUTH_FAILED | true | Podcast Index rejected the signed request (401/403) |
| PODCASTINDEX_RATE_LIMITED | true | Podcast Index 429; honor `retryAfterSeconds` |
| PODCASTINDEX_INVALID_RESPONSE | true | Podcast Index body failed runtime validation |
| PODCASTINDEX_UNAVAILABLE | true | Podcast Index timeout or 5xx |
| YOUTUBE_FILTER_UNSUPPORTED | false | Requested official filter without an API key; results are best-effort |
| YOUTUBE_METADATA_PARTIAL | true | Discovery succeeded but details hydration was incomplete |
| SEARCH_FILTERED_EMPTY | false | Upstream returned candidates but none passed relevance/time filters |
| SEARCH_RUN_NOT_FOUND | false | searchRunId is unknown or not in this session |
| SEARCH_TOOL_CALL_LIMIT_EXCEEDED | false | This turn already used 3 searches for the source |
| PODCASTINDEX_NOT_CONFIGURED | false | Podcast Index key/secret missing; Apple/RSS fallback may still run |
| PODCASTINDEX_AUTH_FAILED | true | Podcast Index 401/403; credentials rejected |
| PODCASTINDEX_RATE_LIMITED | true | Podcast Index 429; honor `retryAfterSeconds` |
| PODCASTINDEX_INVALID_RESPONSE | true | Podcast Index body failed runtime validation |
| PODCASTINDEX_UNAVAILABLE | true | Podcast Index timeout/5xx |
| YOUTUBE_FILTER_UNSUPPORTED | false | Requested official filter without an API key; results are best-effort |
| YOUTUBE_METADATA_PARTIAL | true | Discovery succeeded but details hydration was incomplete |
| SEARCH_FILTERED_EMPTY | false | Upstream returned hits but none passed relevance/date/duration filters |
| SEARCH_RUN_NOT_FOUND | false | searchRunId is unknown or not in this session |
| SEARCH_TOOL_CALL_LIMIT_EXCEEDED | false | This turn already used 3 searches for the source |

## Rules

1. `retryable=true` means a client retry can succeed; it does not guarantee success.
2. Assistant never deletes or retries V10 jobs automatically. Re-prepare is an explicit user action that starts with lookup.
3. Deleting an assistant session never calls V10 DELETE.
4. Unknown codes are treated as non-retryable unless HTTP status is 429/503.
