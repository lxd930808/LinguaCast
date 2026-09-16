# V10 Content Job Error Codes (content-job-error-codes-v1)

> Contract version: v1 (frozen with WP0). Error codes are stable machine
> identifiers; clients localize by code and must tolerate unknown codes by
> treating them as non-retryable INTERNAL_ERROR-class failures.

Every error — whether an HTTP-level `ErrorEnvelope` or a job-level
`ContentJobError` — carries:

| Field | Meaning |
| --- | --- |
| `code` | Stable machine code from the table below |
| `message` | English technical summary (diagnostic only, never the sole user hint) |
| `retryable` | Whether a client-initiated retry can succeed |
| `retryAfterSeconds` | Optional suggested delay before retry/poll |
| `failedStage` | Optional stage in which the job failed |
| `traceId` | De-identified correlation ID for support/diagnostics |
| `params` | Optional stable localization parameters |

## HTTP-level codes

| Code | HTTP | retryable | Meaning |
| --- | --- | --- | --- |
| INVALID_REQUEST | 400 | false | Field validation failed; `params.field` names the field |
| UNAUTHORIZED | 401 | false | Missing/invalid Bearer token |
| FORBIDDEN | 403 | false | Job belongs to another owner scope |
| JOB_NOT_FOUND | 404 | false | Unknown jobId (or expired beyond lookup retention) |
| ARTIFACT_NOT_FOUND | 404 | false | Unknown artifact name for this job |
| IDEMPOTENCY_CONFLICT | 409 | false | Idempotency-Key reused with different payload |
| INVALID_JOB_STATE | 409 | false | Retry/cancel/playback-url not allowed in current state |
| PIPELINE_VERSION_UNSUPPORTED | 422 | false | clientArtifactSchemaVersion newer than server, or vice versa |
| SOURCE_RATE_LIMITED | 429 | true | Caller rate limit; honor `retryAfterSeconds` |
| QUEUE_BUSY | 503 | true | Worker/queue saturated |
| STORAGE_FULL | 503 | true | Disk below 5 GiB watermark or temp quota exceeded |
| MEDIA_NOT_FOUND | 404 | false | No ready video media asset for this contentKey (or an older server that does not implement `/v1/content-media`). Clients MUST treat this as a silent playback fallback, never a user-facing error. |
| MEDIA_NOT_READY | 409 | true | Video asset is still promoting, or an active content job is expected to produce it. Honor `retryAfterSeconds`. |
| MEDIA_INTEGRITY_FAILED | 409 | false | Registered video object is missing or failed HEAD/Range/digest verification. Clients fall back to the existing playback chain. |
| STORAGE_BUDGET_EXCEEDED | 503 | true | Video-media capacity budget reached; new promotions are refused. Audio and subtitle pipelines continue. Playback of already-ready assets is unaffected. |
| INTERNAL_ERROR | 500 | false | Unclassified server error; see `traceId` |

## Job-level codes (failed jobs)

| Code | retryable | Typical failedStage | Meaning |
| --- | --- | --- | --- |
| SOURCE_UNAVAILABLE | false | validating_source | Content removed, URL dead, episode/video gone |
| SOURCE_RESTRICTED | false | validating_source | Region/age/login/platform verification restriction |
| SOURCE_RATE_LIMITED | true | fetching_audio | Source platform throttling; `retryAfterSeconds` set |
| AUDIO_DOWNLOAD_FAILED | true | fetching_audio | Network/transport failure while downloading |
| MEDIA_TOO_LARGE | false | fetching_audio | Exceeds configured byte cap (`params.maxBytes`) |
| MEDIA_TOO_LONG | false | fetching_audio | Exceeds configured duration cap (`params.maxDurationSeconds`) |
| UNSUPPORTED_AUDIO | false | preparing_audio | Corrupt media or transcode impossible |
| ASR_SUBMISSION_UNCERTAIN | false | transcribing | Billed ASR creation outcome unknown; requires explicit rebuild policy, never auto-resubmit |
| ASR_FAILED | true | transcribing | ASR provider reported definitive failure |
| TRANSLATION_FAILED | true | translating | Translation failed or structural validation failed |
| ARTIFACT_PUBLISH_FAILED | true | packaging | Products generated but atomic publish failed |
| STORAGE_FULL | true | * | Disk watermark hit mid-job |
| QUEUE_BUSY | true | * | Job could not obtain a worker lease in time |
| PIPELINE_VERSION_UNSUPPORTED | false | * | Stored checkpoint/schema no longer supported |
| INTERNAL_ERROR | true | * | Unclassified; investigate via `traceId` |
| STORAGE_BUDGET_EXCEEDED | true | fetching_audio | Video promotion refused because the ready-asset byte budget is exceeded. Subtitle/audio work continues; the media asset is not marked ready. |

## Content media lookup (V12)

`POST /v1/content-media/video-playback-url` uses the HTTP-level codes above.
`preferredHeight` is a client preference only and never causes the server to
encode a new rendition.

| Client observation | Required client behaviour |
| --- | --- |
| 200 ready asset | Use the signed MP4; do not call YouTubeKit / InnerTube / SABR / media-api prepare |
| 404 `MEDIA_NOT_FOUND` | Silent fallback to the existing playback chain |
| 404 with no V12 envelope (old server) | Same silent fallback; treat as "V12 unsupported" |
| 409 `MEDIA_NOT_READY` | Bounded wait or fallback; do not block the player on a black screen |
| 409 `MEDIA_INTEGRITY_FAILED` | Fallback; do not retry promotion from the client |
| 401 / 403 | Existing auth handling; if the current source is already cloud, refresh the signature at most once |

## Rules

1. `retryable=true` means a client retry (via POST .../retry) can succeed
   without new user input; it does not guarantee success.
2. Retry reuses valid stage checkpoints. ASR resubmission only happens when
   no confirmed external task ID exists in the checkpoint.
3. `ASR_SUBMISSION_UNCERTAIN` is never auto-retried by the server; an
   operator resolves it by inspecting the provider console and either
   recording the external task ID or explicitly rebuilding the job.
4. Clients must not branch on `message` text, only on `code` and `params`.
