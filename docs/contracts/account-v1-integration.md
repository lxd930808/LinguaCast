# V18 Account Integration Contract (account-v1-integration)

> Contract version: v1 (proposed; frozen by V18 WP01). Companion to
> `account-v1.openapi.yaml` and `account-v1-errors.md`. Defines how business
> services derive identity, propagate it across service calls, reserve and
> settle quota, and delete account data. §1–§2 and §4–§5 are implemented
> (WP02/WP03); §3 quota is implemented in WP04.

## 1. Credentials and sessions

| Item | Rule |
| --- | --- |
| Access token | Opaque random 32 bytes, base64url, prefix `lca_`. Default TTL 900 s (`ACCOUNT_ACCESS_TOKEN_TTL_SECONDS`). Stored as SHA-256 only. |
| Refresh token | Opaque random 32 bytes, base64url, prefix `lcr_`. Single use; rotated on every refresh. Stored as SHA-256 only. |
| Session | `ses_<ULID>`; absolute lifetime 30 days (`ACCOUNT_SESSION_MAX_AGE_SECONDS`), not extended by refresh. One per device sign-in. |
| Challenge | `ach_<ULID>` + nonce (32 random bytes, base64url). TTL 300 s (`ACCOUNT_CHALLENGE_TTL_SECONDS`). Consumed inside the same transaction that validates it, even when later checks fail. |
| Refresh reuse | Presenting a rotated refresh token revokes the session (family). Grace: if the presented token is the *immediate* predecessor, was rotated less than 30 s ago (`ACCOUNT_REFRESH_GRACE_SECONDS`), and its successor has never been used for refresh, the server rotates again (the unused successor is invalidated) instead of revoking. This covers lost responses on mobile networks. |
| Apple mapping | `apple_identities(apple_sub UNIQUE, account_id)`. Email and name are optional display data and never used for lookup. |
| Apple revocation | The Apple refresh token obtained by redeeming `authorizationCode` is stored encrypted-at-rest (key from environment) and revoked through Apple's revoke endpoint during account deletion. If Apple credentials are absent the deployment cannot enable Apple mode. |
| Transactions | Challenge consumption, account creation/lookup, session creation and refresh rotation each run in a single `BEGIN IMMEDIATE` SQLite transaction. |

Self-host single-user mode (`AUTH_MODE=selfhost`): the deployment token
(`SELFHOST_ACCESS_TOKEN`, ≥ 32 characters) is compared in constant time and
yields the fixed identity `{ accountId: "selfhost", authMode: "selfhost",
sessionId: null }`. No request field, header or query can select another
account. Apple routes and `DELETE /v1/me` return `AUTH_MODE_UNSUPPORTED`. A
deployment may instead enable Apple mode with its own Apple credentials; the two
modes are mutually exclusive per deployment.

## 2. Identity resolution and propagation

### 2.1 RequestIdentity

```ts
interface RequestIdentity {
  accountId: string;            // acc_<ULID> | "selfhost"
  authMode: 'apple' | 'selfhost';
  sessionId: string | null;     // null in selfhost mode
}
```

Only the authentication entry of each service constructs a `RequestIdentity`.
Route handlers, stores, workers, object keys, caches and SSE lookups receive it
(or the persisted `accountId`) as an argument; the static
`CONTENT_OWNER_SCOPE` / `ASSISTANT_OWNER_SCOPE` configuration values are removed
as identity sources. `owner_scope` columns keep their name and store
`accountId`.

### 2.2 Public requests (App → business service)

1. Client sends `Authorization: Bearer lca_…` (or the self-host token).
2. Service calls `POST /internal/v1/auth/introspect` with its internal service
   token. In official mode the result is **not cached**, so logout and deletion
   take effect on the next request.
3. `active=false` → `401` with the code mapped from `inactiveReason`
   (`expired` → `ACCESS_TOKEN_EXPIRED`, `revoked` → `SESSION_REVOKED`,
   `account_disabled` → `ACCOUNT_DISABLED`, `account_deleting` →
   `ACCOUNT_DELETING`, otherwise `AUTH_REQUIRED`).
4. Introspection transport failure → `503 ACCOUNT_SERVICE_UNAVAILABLE`. The
   request is never processed anonymously.
5. Headers such as `X-Owner-Scope`, `X-LinguaCast-Account-Context` or body
   fields named `ownerScope`/`accountId` on a public request are ignored; a
   public request carrying `X-LinguaCast-Account-Context` is rejected with
   `400 INVALID_REQUEST`.

### 2.3 Internal requests (service → service)

Used when the research assistant creates transcript jobs in the content
pipeline, and when the content pipeline calls the media service.

| Header | Value |
| --- | --- |
| `Authorization` | `Bearer <INTERNAL_SERVICE_TOKEN of the callee>` — proves a trusted service, not a user |
| `X-LinguaCast-Account-Context` | `v1.<base64url(JSON)>.<base64url(HMAC-SHA256)>` |

Signed JSON payload:

```json
{ "accountId": "acc_…", "authMode": "apple", "sessionId": "ses_…",
  "operationKey": "assistant-transcript:tj_…", "reservationId": "qr_…",
  "issuer": "research-assistant", "exp": 1760000000 }
```

- HMAC key: `ACCOUNT_CONTEXT_SIGNING_KEY`, shared only among backend services;
  `exp` ≤ 300 s after issue.
- The callee verifies bearer **and** signature **and** `exp`; any failure →
  `401 AUTH_REQUIRED`. It then builds `RequestIdentity` from the payload.
- Internal routes never accept a user access token, and public routes never
  accept the internal token as a user identity. There is no administrator
  identity that acts for users.
- `operationKey`, when present, is used by the callee as the logical operation
  of the reservation it creates, so retries of the same assistant transcript
  resolve to the same reservation (§3.4). `reservationId` is reserved for
  future use and currently ignored.

### 2.4 Per-service configuration (implemented in WP03)

| Setting | Content pipeline | Research assistant | Media service |
| --- | --- | --- | --- |
| Identity mode (required) | `CONTENT_IDENTITY_MODE` | `ASSISTANT_IDENTITY_MODE` | `MEDIA_IDENTITY_MODE` |
| Selfhost deployment token | `CONTENT_SERVICE_TOKEN` | `ASSISTANT_SERVICE_TOKEN` | `AUTH_TOKEN` |
| Account service URL (account mode) | `ACCOUNT_SERVICE_URL` | `ACCOUNT_SERVICE_URL` | `ACCOUNT_SERVICE_URL` |
| Own introspection token (account mode; registered in `ACCOUNT_INTERNAL_TOKENS`) | `CONTENT_ACCOUNT_TOKEN` | `ASSISTANT_ACCOUNT_TOKEN` | `MEDIA_ACCOUNT_TOKEN` |
| Accepted internal callers | `CONTENT_INTERNAL_CALLERS` (`research-assistant`, `account-service`) | `ASSISTANT_INTERNAL_CALLERS` (`account-service`) | `MEDIA_INTERNAL_CALLERS` (`content-pipeline`, `account-service`) |
| Context signing key (required in account mode) | `ACCOUNT_CONTEXT_SIGNING_KEY` | `ACCOUNT_CONTEXT_SIGNING_KEY` | `ACCOUNT_CONTEXT_SIGNING_KEY` |
| Outbound call to next service | `MEDIA_API_TOKEN` = media caller token (account) or `AUTH_TOKEN` (selfhost) | `V10_SERVICE_TOKEN` = content caller token (account) or `CONTENT_SERVICE_TOKEN` (selfhost) | — |
| Media URL signing key | — | — | `MEDIA_URL_SIGNING_KEY` (account mode required; selfhost defaults to `AUTH_TOKEN`) |

Selfhost deployments leave `ACCOUNT_CONTEXT_SIGNING_KEY` unset on callers so
outbound calls use the callee's deployment token without a context header.
`docs/contracts/account-context-v1.vectors.json` holds shared test vectors;
every service's tests verify them.

### 2.5 Network boundary

- `/internal/*` paths and internal ports are reachable only on the container
  network; public reverse-proxy templates deny `/internal/` explicitly.
- The PO-Token sidecar and media service internal port are never published.

## 3. Quota reservation state machine

### 3.1 States

```text
             reserve (201)                    settle consumed
 (none) ───────────────────▶ reserved ──────────────────────────▶ consumed
                                 │
                                 │ settle released
                                 ▼
                              released
```

- `reserved` counts against `reserved` in the period snapshot.
- `consumed` counts against `used`. `released` counts against nothing.
- `consumed` and `released` are terminal. Re-settling with the same outcome is
  a no-op `200`; with the other outcome → `409 RESERVATION_ALREADY_SETTLED`.
- Every transition appends a row to `quota_ledger` (`reserve`, `consume`,
  `release`, `adjust`). Invariant checked by tests and by `verify.sh`:
  for each (account, kind, period): `used = Σ consume`,
  `reserved = Σ reserve − Σ consume − Σ release`, and `used + reserved ≤ limit`
  at every reservation commit.

### 3.2 Atomic reservation

Within one `BEGIN IMMEDIATE` transaction the account service: looks up
`(account_id, kind, operation_key)`; returns it if present (same amount) or
`409` (different amount); otherwise computes current `used + reserved` for the
Asia/Shanghai period, rejects with `QUOTA_REQUEST_TOO_LARGE` when
`amount > limit`, rejects with `QUOTA_EXCEEDED` when
`used + reserved + amount > limit`, else inserts reservation and ledger rows.
Limits come from server configuration (`QUOTA_MEDIA_SECONDS_PER_DAY`, default
1800; `QUOTA_ASSISTANT_TURNS_PER_DAY`, default 20; `QUOTA_ENFORCED`, default
`true` in Apple mode and `false` in selfhost mode).

### 3.3 Task services: queue, concurrency and settlement outbox

Each task service owns its execution queue in its own SQLite database:

1. **Submit** (HTTP request thread): authenticate → validate → reuse check
   (identical active or ready work is returned free) → (media) probe duration
   (`MEDIA_DURATION_UNKNOWN` / `MEDIA_TOO_LONG` reject before reserving) →
   reserve with a deterministic `operationKey` → insert the task row
   with `account_id`, `operation_key`, `reservation_id`, status `queued` in one
   local transaction. A failure after reservation but before the local insert
   is repaired by the idempotent retry (same `operationKey` returns the same
   reservation) or by reconciliation (§3.5).
2. **Dispatch**: a worker claims the oldest (FIFO) queued task whose account has
   no running task of that kind and while the global running count is below
   `*_GLOBAL_CONCURRENCY` (default 1), using a single conditional `UPDATE … WHERE`
   so slot acquisition is atomic. Per-account concurrency defaults to 1 for
   media and 1 for assistant, independently.
3. **Terminal state**: in the same local transaction that stores the terminal
   status, insert `quota_settlement_outbox(reservation_id, outcome, reason,
   created_at, delivered_at NULL)`.
4. **Delivery**: a background loop posts outbox rows to `/settle` and sets
   `delivered_at` on `200`/`409-already-settled-same-meaning`. Undelivered rows
   are replayed on start and periodically.

### 3.4 Operation keys

| Operation | operationKey | kind / amount |
| --- | --- | --- |
| Content job (podcast or video) | `content-job:<jobId>`; the jobId itself is idempotent per `(accountId, Idempotency-Key)` | media / ceil(duration) |
| Assistant turn | `assistant-turn:<turnId>` | assistant / 1 |
| Assistant-derived transcript | `assistant-transcript:<transcriptJobId>`, carried as `operationKey` in the signed account context; the content pipeline probes and reserves under that key, so repeated submissions for the same transcript job reuse one reservation. If that reservation is already settled (an earlier attempt finished or failed), a new attempt uses `<key>#<jobId>` | media / ceil(duration) |
| Content job retry | `<original operationKey>#retry<attempt>` (the failed attempt was released) | media / stored duration |
| Reused ready artifact | no reservation | — |
| Media download / playback | no reservation | — |

A new request for a different target language or translation quality is a new
job and therefore a new operation.

### 3.4a Implementation notes (WP04)

| Service | Probe | Queue & concurrency settings | Terminal → settlement |
| --- | --- | --- | --- |
| Content pipeline | Podcasts: bounded head download (`CONTENT_PROBE_HEAD_BYTES`, default 2 MiB; every redirect SSRF-checked) + ffprobe; the audio stream bitrate decides between header duration and a constant-bitrate estimate scaled by the total length. Videos: media service `POST /v1/videos/{id}/probe` (yt-dlp metadata, no download) | `CONTENT_ACCOUNT_CONCURRENCY` (1), `CONTENT_GLOBAL_CONCURRENCY` (1, one worker per slot); `CONTENT_QUOTA_ENABLED` defaults to on in account mode | ready → consume/succeeded; failed → release/failed; cancelled → release/cancelled (written in the same transaction as the status) |
| Research assistant | One unit per turn | `ASSISTANT_ACCOUNT_TURNS` (1), `ASSISTANT_GLOBAL_PI_TURNS` (1); `ASSISTANT_QUOTA_ENABLED` defaults to on in account mode | completed → consume/succeeded; failed, cancelled and interrupted → release (interrupted turns have no public retry route) |
| Account service | — | `QUOTA_MEDIA_SECONDS_PER_DAY` (1800), `QUOTA_ASSISTANT_TURNS_PER_DAY` (20), `QUOTA_MEDIA_CONCURRENCY` / `QUOTA_ASSISTANT_CONCURRENCY` (reported in `/v1/me/quota`), `QUOTA_ENFORCED` | Account deletion completion releases open reservations and anonymizes quota history |

Over-estimates of a podcast's duration are not refunded after download; the
probe result is the charged amount.

### 3.5 Restart reconciliation

On start, each task service:

1. Replays undelivered outbox rows.
2. For tasks in `queued`/`running` with a `reservation_id`, keeps the
   reservation (running tasks are re-leased by existing lease recovery, never
   released by timeout).
3. For reservations the account service reports as `reserved` whose task row
   is terminal, settles according to the stored terminal status.
4. For reservations with no local task row (crash between reserve and insert),
   releases with reason `rejected_before_start` after a safety delay of at least
   one lease period.

The account service never releases a `reserved` row on its own; it exposes
stale reservations (older than 24 h) in logs for operator review.

## 4. Account deletion workflow

1. `DELETE /v1/me` (transaction): account `status=deleting`; revoke all
   sessions; insert `account_deletions(deletion_id, account_id, requested_at,
   steps_json, completed_at NULL)`; move the sealed Apple refresh token into the
   deletion row and delete the `apple_identities` mapping immediately, so a new
   sign-in with the same Apple ID can only create a new account; return `202`.
2. Worker, retrying with backoff until done, calls on each business service
   (content pipeline, research assistant, media service):
   `POST /internal/v1/accounts/{accountId}/purge` with the `account-service`
   internal caller token (no user context). Only `acc_` IDs are accepted;
   the selfhost owner is never purged. Each service must be idempotent and return `200 {status:"done"}`
   or `202 {status:"in_progress"}`. A service purge: stops queued/running tasks
   of the account (reservations released with `account_deleted`), deletes
   account rows, workspaces, memories, SSE event rows, cache entries and object
   storage keys under the account prefix.
3. Revoke the Apple refresh token held in the deletion row (`invalid_grant`
   counts as already revoked), then clear it.
4. Mark each step complete in `steps_json`; when all are done set
   `completed_at` and keep the row as a **tombstone** (accountId and timestamps
   only, no personal data). Quota ledger rows are anonymized, not deleted.
5. Signing in again with the same Apple ID creates a new `accountId`.

Backup restore: after restoring any service database, operators run the
tombstone replay (`restore-verify.sh`), which re-applies purge for every
tombstoned `accountId` before the service accepts traffic.

Pre-V18 single-user data stays under its original `owner_scope` (`selfhost` by
default) and is never assigned to an Apple account.

## 5. Object and cache namespaces

| Resource | Namespace rule |
| --- | --- |
| Content DB unique keys | `(owner_scope, …)` already present; `owner_scope` = `accountId` |
| Content R2 keys | `<prefix>/<env>/accounts/<accountId>/…` for new objects; pre-V18 keys stay as-is under `selfhost` |
| Media service job/media URLs | Job rows carry `accountId` (restored pre-V18 jobs: `selfhost`) and dedupe per account. Files are served either with an owner Bearer credential on `/media/{jobId}/{file}` or via `/media-signed/{jobId}/{exp}/{sig}/{file}` where `sig = base64url(HMAC-SHA256(MEDIA_URL_SIGNING_KEY, "media-v1\n{jobId}\n{accountId}\n{exp}"))`; the path form keeps relative HLS segment URIs authorized. `?access_token=` is no longer accepted. |
| Assistant DB | every V2 table reachable by ID joins to `v2_researches.owner_scope`; foreign IDs return `*_NOT_FOUND` |
| Assistant workspaces | `<workspaceRoot>/<researchId>` (research IDs are globally unique ULIDs); ownership is enforced through `v2_researches.owner_scope`, and account purge enumerates the account's researches. (WP03 decision: the per-account directory level originally proposed here was not needed for isolation and would have forced a workspace layout migration.) |
| Assistant global memory | `v2_memory_entries.owner_scope` (migration 0004 backfills from the source research, orphans → `selfhost`); preferences file under `<globalMemoryRoot>/accounts/<accountId>/`, selfhost keeps the legacy root file. Admin shared grants are honored only in selfhost identity mode. |
| Search/web caches | Provider response caches may stay global (no user data); any cache keyed by user input that stores user-visible results includes `accountId` |
| SSE | Event stream lookup requires the turn to belong to the caller's account; unknown or foreign turn IDs → `404` |
