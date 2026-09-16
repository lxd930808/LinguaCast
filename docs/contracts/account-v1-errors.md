# V18 Account & Quota Error Codes (account-v1-errors)

> Contract version: v1 (proposed; frozen by V18 WP01). Codes are stable machine
> identifiers shared by the account service and, from WP03/WP04 on, by every
> business service (content pipeline, research assistant, media service).
> Clients localize by `code` and treat unknown codes as non-retryable
> `INTERNAL_ERROR`-class failures.

All errors use the envelope already used by the content and assistant
services:

```json
{ "error": { "code": "QUOTA_EXCEEDED", "message": "…", "retryable": false,
             "retryAfterSeconds": 3600, "params": { "kind": "media" },
             "traceId": "tr_…" } }
```

`message` is an English diagnostic; it never contains tokens, Apple identity
claims, email addresses or request bodies.

## 1. Categories the client must present differently

| Category | Codes | Client behavior |
| --- | --- | --- |
| Not authenticated | `AUTH_REQUIRED`, `ACCESS_TOKEN_EXPIRED`, `SESSION_REVOKED`, `REFRESH_TOKEN_INVALID`, `REFRESH_TOKEN_REUSED`, legacy `UNAUTHORIZED` | `ACCESS_TOKEN_EXPIRED`: one single-flight refresh, then replay once. Everything else: clear session, show sign-in. Never shown as "server unavailable". |
| No permission | `FORBIDDEN`, `ACCOUNT_DISABLED`, `ACCOUNT_DELETING` | Show account state; no retry. |
| Quota | `QUOTA_EXCEEDED`, `QUOTA_REQUEST_TOO_LARGE` | Show remaining amount and `params.resetAt`; do not start work. |
| Unknown duration | `MEDIA_DURATION_UNKNOWN` | Explain the source cannot be measured; no automatic retry. |
| Service unavailable | `SERVICE_UNAVAILABLE`, `ACCOUNT_SERVICE_UNAVAILABLE`, `APPLE_KEYS_UNAVAILABLE` | Offer retry; never fall back to on-device processing. |
| Idempotency conflict | `IDEMPOTENCY_CONFLICT`, `RESERVATION_ALREADY_SETTLED` | Programming or race error; surface as generic failure with `traceId`. |

Queueing is **not** an error: a task that waits for a concurrency slot is
accepted (`202`) and reports a `queued` status with an optional
`queuePosition`.

## 2. HTTP-level codes

| Code | HTTP | retryable | Emitted by | Meaning |
| --- | --- | --- | --- | --- |
| INVALID_REQUEST | 400 | false | all | Field validation failed; `params.field` names the field |
| AUTH_REQUIRED | 401 | false | all public routes | No bearer credential, unknown credential, or wrong credential type |
| UNAUTHORIZED | 401 | false | legacy business routes | Pre-V18 alias of `AUTH_REQUIRED`; kept for old clients, not emitted by the account service |
| ACCESS_TOKEN_EXPIRED | 401 | true | all public routes | Access token past `accessTokenExpiresAt`; refresh and replay once |
| SESSION_REVOKED | 401 | false | all public routes | Logout, refresh reuse, account deletion or operator revocation |
| REFRESH_TOKEN_INVALID | 401 | false | `/v1/auth/refresh` | Unknown, malformed or expired refresh token, or session past `sessionExpiresAt` |
| REFRESH_TOKEN_REUSED | 401 | false | `/v1/auth/refresh` | Rotated refresh token presented outside the grace window; the session family is revoked |
| CHALLENGE_INVALID | 400 | false | `/v1/auth/apple/exchange` | Unknown challenge ID or platform mismatch |
| CHALLENGE_EXPIRED | 400 | false | `/v1/auth/apple/exchange` | Challenge older than its TTL; start a new challenge |
| CHALLENGE_CONSUMED | 400 | false | `/v1/auth/apple/exchange` | Challenge already used (single-use, including failed attempts) |
| APPLE_TOKEN_INVALID | 401 | false | `/v1/auth/apple/exchange` | Signature, `iss`, `aud`, `exp`/`iat`, `nonce` or `nonce_supported` check failed; `params.check` names the failed check (never the claim value) |
| APPLE_CODE_REJECTED | 401 | false | `/v1/auth/apple/exchange` | Apple token endpoint rejected `authorizationCode` (`invalid_grant`) |
| APPLE_KEYS_UNAVAILABLE | 503 | true | `/v1/auth/apple/exchange` | JWKS or token endpoint unreachable; verification is never skipped |
| AUTH_MODE_UNSUPPORTED | 404 | false | account service | Apple routes called on a self-host single-user deployment, or `DELETE /v1/me` in single-user mode |
| FORBIDDEN | 403 | false | all | Authenticated but the operation is not allowed for this identity (e.g. internal route with a user token) |
| ACCOUNT_DISABLED | 403 | false | all | Account disabled by operator |
| ACCOUNT_DELETING | 403 | false | all | Account deletion in progress; no new work accepted |
| NOT_FOUND | 404 | false | all | Resource absent **or owned by another account**. Services never reveal cross-account existence with 403. Service-specific `*_NOT_FOUND` codes keep the same rule. |
| IDEMPOTENCY_CONFLICT | 409 | false | all | `Idempotency-Key` / `operationKey` reused with a different payload |
| RESERVATION_NOT_FOUND | 404 | false | internal quota | Unknown reservation ID |
| RESERVATION_ALREADY_SETTLED | 409 | false | internal quota | Settle called with an outcome different from the stored one; `params.status` holds the stored status |
| QUOTA_EXCEEDED | 429 | false | business services, internal quota | Remaining daily quota is smaller than the requested amount. `params`: `kind`, `limit`, `used`, `reserved`, `remaining`, `requested`, `resetAt`; `retryAfterSeconds` = seconds until `resetAt` |
| QUOTA_REQUEST_TOO_LARGE | 422 | false | business services, internal quota | A single operation is larger than the whole daily limit (e.g. a 45-minute episode with a 30-minute limit); rejected as a whole, never truncated. `params`: `kind`, `limit`, `requested` |
| MEDIA_DURATION_UNKNOWN | 422 | false | content pipeline | Duration probe failed or returned no finite duration; transcription/translation is not started and nothing is reserved |
| RATE_LIMITED | 429 | true | account service | Request-rate protection on auth endpoints (distinct from daily quota) |
| ACCOUNT_SERVICE_UNAVAILABLE | 503 | true | business services | Introspection or reservation call failed; the request is rejected, never processed without identity or quota |
| SERVICE_UNAVAILABLE | 503 | true | all | Dependency or database unavailable |
| INTERNAL_ERROR | 500 | false | all | Unclassified; see `traceId` |

## 3. Job- and turn-level codes

Asynchronous tasks that were accepted and later cannot run report these codes
in their task error object (content `ContentJobError`, assistant turn error).

| Code | retryable | Meaning | Quota effect |
| --- | --- | --- | --- |
| QUOTA_EXCEEDED | false | Reservation refused when the task left the queue (only possible for work accepted before the reservation step, e.g. legacy rows) | none reserved |
| MEDIA_DURATION_UNKNOWN | false | Probe inside the worker could not determine duration | none reserved |
| ACCOUNT_DELETING | false | Task stopped by account deletion | reservation released (`account_deleted`) |
| QUOTA_SETTLEMENT_PENDING | true | Terminal state stored but settlement not yet acknowledged; informational only, never shown as failure | settlement replayed from outbox |

Existing job codes in `content-job-error-codes.md` and
`assistant-v2-error-codes.md` remain valid. `FORBIDDEN` for "job belongs to
another owner scope" in the content contract is superseded by `NOT_FOUND`
(`JOB_NOT_FOUND`) from WP03 on.

## 4. Quota charging and refund rules

These rules are normative for WP04; `account-v1-integration.md` §3 defines the
state machine.

1. **Period.** Asia/Shanghai calendar day. `periodKey` is fixed when the
   reservation is created and never moves, even if the task completes after
   midnight. `resetAt` is the next 00:00 Asia/Shanghai.
2. **Media amount.** `ceil(probedDurationSeconds)` of the audio/video actually
   submitted for transcription/translation. Probe before reserving; unknown
   duration → `MEDIA_DURATION_UNKNOWN`; amount > daily limit →
   `QUOTA_REQUEST_TOO_LARGE`.
3. **Assistant amount.** One unit per submitted conversation turn that will
   call the model.
4. **Reserve before queueing.** A queued task already holds its reservation.
   Queue position never changes the charge.
5. **Consume** only when the task reaches a successful terminal state.
6. **Release** on failure, cancellation before success, rejection before
   start, account deletion, or when an existing same-account artifact is
   reused instead of processing.
7. **Success wins once.** If success and cancellation race, the first stored
   terminal state decides; settlement is applied exactly once. Work that
   already succeeded is not refunded when the user later cancels or deletes the
   record.
8. **No double charge.** Network retries, worker crash recovery, and the
   internal media call made on behalf of an assistant transcript all reuse the
   same `operationKey` and therefore the same reservation.
9. **Free paths.** Playback, download of existing media, reuse of a ready
   same-account artifact and reads of existing subtitles never reserve quota.
   Media download jobs still obey queue, concurrency and disk limits.
10. **No timeout release.** A reservation whose task may still be running is
    never released by elapsed time alone; only reconciliation against the
    task's durable state may release it.
11. **Never repair by deleting.** Ledger inconsistencies are corrected by
    appending compensating ledger rows, never by clearing the ledger.
