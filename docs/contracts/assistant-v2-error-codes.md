# Assistant API Error Codes (assistant-error-codes-v2)

> Contract version: v2 (frozen with V15 WP1). V1 codes in `assistant-error-codes.md`
> remain valid on `/v1/assistant*`. This file is the machine-code list for
> `/v2/assistant*`. Clients localize by `code` and must tolerate unknown codes
> by treating them as non-retryable `INTERNAL_ERROR`-class failures unless HTTP
> status is 429 or 503.

Every HTTP error uses the same envelope as V1:

```json
{
  "error": {
    "code": "WORKSPACE_PATH_UNSAFE",
    "message": "Virtual path is not allowed",
    "retryable": false,
    "retryAfterSeconds": 5,
    "traceId": "tr_...",
    "params": {}
  }
}
```

| Field | Meaning |
| --- | --- |
| `code` | Stable machine code from the tables below |
| `message` | English technical summary (diagnostic only) |
| `retryable` | Client-initiated retry can succeed without new user input |
| `retryAfterSeconds` | Optional suggested delay |
| `traceId` | De-identified correlation ID |
| `params` | Optional stable localization parameters (never real paths) |

Clients must not branch on `message` text.

## HTTP-level codes

Shared with V1 where the meaning is identical. New V2-only codes are marked.

| Code | HTTP | retryable | Meaning |
| --- | --- | --- | --- |
| INVALID_REQUEST | 400 | false | Field validation failed; `params.field` names the field |
| UNAUTHORIZED | 401 | false | Missing or invalid assistant Bearer token |
| FORBIDDEN | 403 | false | Research/turn belongs to another owner scope |
| RESEARCH_NOT_FOUND | 404 | false | Unknown, deleting, or deleted researchId **(V2)** |
| TURN_NOT_FOUND | 404 | false | Unknown turnId |
| ARTIFACT_NOT_FOUND | 404 | false | artifactId missing or not in this Research **(V2)** |
| SOURCE_NOT_FOUND | 404 | false | sourceId missing or not in this Research **(V2)** |
| TRANSCRIPT_JOB_NOT_FOUND | 404 | false | transcriptJobId missing or not in this Research **(V2)** |
| MEMORY_PROPOSAL_NOT_FOUND | 404 | false | proposalId missing **(V2)** |
| IDEMPOTENCY_CONFLICT | 409 | false | Idempotency-Key reused with a different payload |
| TURN_ALREADY_RUNNING | 409 | false | Research already has a queued/running turn |
| INVALID_RESEARCH_STATUS | 409 | false | Request illegal in the current Research status **(V2)** |
| EVENT_CURSOR_EXPIRED | 409 | false | Last-Event-ID older than the retained window; GET snapshot |
| PIPELINE_VERSION_UNSUPPORTED | 422 | false | client schema newer than server support |
| SOURCE_RATE_LIMITED | 429 | true | Caller rate limit |
| QUEUE_BUSY | 503 | true | Worker/queue saturated or SQLite busy |
| STORAGE_FULL | 503 | true | Disk watermark; history remains readable |
| MODEL_NOT_CONFIGURED | 503 | false | Pi config has no usable model |
| ASSISTANT_V2_DISABLED | 503 | false | Legacy: only pre-V18 deployments with `ASSISTANT_V2_ENABLED=0`, or a service started without the V2 stack **(V2)** |
| INTERNAL_ERROR | 500 | false | Unclassified server error |

## Workspace, path, and grant

| Code | HTTP | retryable | Meaning |
| --- | --- | --- | --- |
| WORKSPACE_CREATE_FAILED | 503 | true | Atomic workspace create did not commit; retry is safe |
| WORKSPACE_NOT_READY | 409 | true | Research exists but workspace is still creating/recovering |
| WORKSPACE_DEGRADED | 409 | true | Workspace readable but recovery/quota issues exist |
| WORKSPACE_CORRUPT | 409 | false | Manifest/hash untrusted; wait for operator recovery |
| WORKSPACE_PATH_UNSAFE | 400 | false | Virtual path failed syntax, containment, symlink, or type checks |
| WORKSPACE_FILE_TYPE_REJECTED | 400 | false | Device, FIFO, socket, executable, or disallowed extension |
| WORKSPACE_GRANT_DENIED | 403 | false | Alias not granted to this Research |
| WORKSPACE_GRANT_READ_ONLY | 403 | false | Alias is read-only; write refused |
| WORKSPACE_GRANT_UNAVAILABLE | 409 | true | Granted alias root is missing or unmounted |
| WORKSPACE_QUOTA_EXCEEDED | 503 | true | Soft/hard disk watermark for this write class |
| SHARED_WRITE_DISABLED | 403 | false | `ASSISTANT_SHARED_WRITE_ENABLED=0` |

`params` for path errors may include `uri` (virtual) and `reason`. Never a real path.

## grep

| Code | HTTP | retryable | Meaning |
| --- | --- | --- | --- |
| GREP_ARGUMENT_REJECTED | 400 | false | Unsupported mode, glob, flag, or pattern shape |
| GREP_PATTERN_REJECTED | 400 | false | Regex rejected by the linear-time engine |
| GREP_TIMEOUT | 504 | true | Hard timeout; process group terminated |
| GREP_TRUNCATED | 200 | false | Result returned but match/output budget hit (`truncated=true`) |

grep is a Tool, not a public REST route. These codes appear in tool results and may be projected on a failed turn.

## Web

| Code | HTTP | retryable | Meaning |
| --- | --- | --- | --- |
| WEB_DISABLED | 503 | false | `ASSISTANT_WEB_ENABLED=0` |
| WEB_URL_BLOCKED | 400 | false | Scheme, host, DNS, redirect, or private address rejected |
| WEB_URL_NOT_ALLOWED | 400 | false | URL is not a saved search result or a policy-passed user URL |
| WEB_CONTENT_UNSUPPORTED | 422 | false | MIME/type not in the allow-list |
| WEB_CONTENT_TOO_LARGE | 413 | false | Compressed or extracted body exceeded cap |
| WEB_SEARCH_FAILED | 503 | true | Configured provider failed; failure artifact is saved |
| WEB_FETCH_FAILED | 503 | true | Page fetch failed after policy checks |

## Artifact

| Code | HTTP | retryable | Meaning |
| --- | --- | --- | --- |
| ARTIFACT_NOT_READY | 409 | true | Artifact still pending |
| ARTIFACT_CORRUPT | 409 | false | Hash/schema mismatch; removed from evidence |
| ARTIFACT_BODY_TRUNCATED | 200 | false | REST body returned with `truncated=true` |
| ARTIFACT_WRITE_FAILED | 503 | true | pending → file → manifest → ready did not commit |

Artifact REST never accepts path, URI, alias, or filename. Those inputs are `INVALID_REQUEST`.

## Memory

| Code | HTTP | retryable | Meaning |
| --- | --- | --- | --- |
| MEMORY_SCOPE_DENIED | 403 | false | Cross-research memory access |
| MEMORY_PROPOSAL_NOT_CONFIRMED | 409 | false | Pending/rejected/expired/forgotten preference cannot be recalled |
| MEMORY_PROPOSAL_EXPIRED | 409 | false | Confirm/reject after expiry |
| MEMORY_PROPOSAL_ALREADY_RESOLVED | 200 | false | Idempotent confirm/reject of a terminal proposal (success envelope) |

## Transcript / V10

| Code | HTTP | retryable | Meaning |
| --- | --- | --- | --- |
| TRANSCRIPT_CONFIRMATION_REQUIRED | 400 | false | Missing or invalid user confirmation token |
| TRANSCRIPT_SOURCE_NOT_ELIGIBLE | 409 | false | Source cannot enter V10 (live, missing ID, not in this Research) |
| V10_UNAUTHORIZED | 502 | false | Assistant-to-V10 token rejected |
| V10_UNAVAILABLE | 503 | true | V10 timeout/5xx; job retained |
| V10_JOB_FAILED | 409 | true | V10 job failed; assistant does not auto-retry |
| ARTIFACT_INVALID | 422 | false | segments.json failed role/schema/bytes/sha256 checks |
| ARTIFACT_INTEGRITY_FAILED | 422 | false | Downloaded V10 artifact checksum mismatch |

## Turn / model

| Code | retryable | Meaning |
| --- | --- | --- |
| TURN_INTERRUPTED | true | Process restart; retry creates a new turn |
| TURN_BUDGET_EXCEEDED | false | Search, fetch, grep, model steps, or output budget exceeded |
| TURN_CANCELLED | false | User cancelled the turn |
| MODEL_PROVIDER_UNAVAILABLE | true | Pi primary and fallbacks failed |
| TOOL_NOT_ALLOWED | false | Tool name not in the current Turn/phase whitelist |
| TOOL_LIMIT_EXCEEDED | false | Per-turn tool call limit reached |
| CITATION_VALIDATION_FAILED | true | Model citations failed verifier after one repair attempt |
| EVIDENCE_NOT_FOUND | false | No locatable artifact evidence for the claim |

## Legacy

| Code | HTTP | retryable | Meaning |
| --- | --- | --- | --- |
| LEGACY_SESSION_READ_ONLY | 409 | false | Legacy: pre-V18 `ASSISTANT_V1_MUTATIONS_ENABLED=0`; V18 removed the V1 routes |

## Rules

1. `retryable=true` does not guarantee success.
2. Assistant never deletes or retries V10 jobs automatically. Re-prepare starts with lookup after a new user confirmation.
3. Deleting a V2 Research never calls V10 DELETE and never deletes shared files or confirmed global preferences.
4. Unknown codes are non-retryable unless HTTP status is 429/503.
5. Tool and log payloads must not include real paths, argv, Cookie, provider keys, or full web/transcript bodies.
