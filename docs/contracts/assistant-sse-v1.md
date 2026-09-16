# Assistant SSE v1

> Frozen with V13 WP0. SSE is a projection of the durable `events` table, not
> the source of truth. After disconnect, clients MUST GET the session snapshot
> and only then reconnect with `Last-Event-ID`.

## Endpoint

```
GET /v1/assistant/turns/{turnId}/events
Authorization: Bearer <assistant-service-token>
Last-Event-ID: <optional monotonic event id>
```

Response:

```
HTTP/1.1 200 OK
Content-Type: text/event-stream; charset=utf-8
Cache-Control: no-cache, no-transform
Connection: keep-alive
X-Accel-Buffering: no
```

Proxies MUST disable response buffering and keep the stream readable for at
least 15 minutes of idle heartbeat.

## Event frame

```
id: 42
event: message.delta
data: {"schemaVersion":1,"sessionId":"as_...","turnId":"at_...","sequence":7,"occurredAt":"2026-08-31T01:02:03Z","payload":{"text":"..."}}
```

Rules:

- `id` is a session-scoped monotonic integer stored in SQLite. It never repeats
  and never goes backward.
- `event` is one of the types below. Unknown types MUST be ignored by clients.
- `data` is a single JSON object. Multi-line `data:` frames concatenate with `\n`.
- Heartbeats use `event: heartbeat` and an empty or `{ "t": <rfc3339> }` payload.
- Heartbeat interval is 15 seconds.

## Event types

| Type | When | Payload |
| --- | --- | --- |
| `turn.accepted` | Turn persisted as queued | `{ "kind": "research\|qa" }` |
| `turn.started` | Worker claimed the turn | `{ "kind": "research\|qa" }` |
| `tool.started` | A whitelist tool began | `{ "tool": "search_youtube", "callId": "..." }` |
| `tool.completed` | Tool finished | `{ "tool": "search_youtube", "callId": "...", "ok": true }` |
| `search.plan_ready` | Search plan validated | `{ "searchRunId": "srun_...", "intent": "topic", "queryCount": 1 }` |
| `search.source_started` | A provider child run began | `{ "searchRunId": "srun_...", "provider": "podcastindex" }` |
| `search.source_completed` | A provider child run finished | `{ "searchRunId": "srun_...", "provider": "podcastindex", "status": "success", "acceptedCount": 8 }` |
| `search.results_ranked` | Aggregate ranking persisted | `{ "searchRunId": "srun_...", "acceptedCount": 10 }` |
| `session.title_updated` | Session list title replaced (provisional or LLM) | `{ "title": "..." }` |
| `message.delta` | Streaming draft token(s) | `{ "text": "partial" }` |
| `report.ready` | Research report committed | `{ "reportId": "...", "title": "..." }` |
| `content.progress` | V10/index preparation | `{ "bindingId": "...", "stage": "...", "progress": 0.4 }` |
| `transcript.ready` | Current binding index active | `{ "bindingId": "...", "contentKey": "..." }` |
| `citation.ready` | QA citations committed | `{ "messageId": "...", "citationIds": ["ct_..."] }` |
| `turn.completed` | Terminal success | `{ "phase": "report_ready\|qa_ready" }` |
| `turn.failed` | Terminal failure | `{ "code": "MODEL_PROVIDER_UNAVAILABLE", "retryable": true }` |
| `turn.cancelled` | User cancel committed | `{ "code": "TURN_CANCELLED" }` |
| `heartbeat` | Keep-alive | `{ "t": "2026-08-31T01:02:18Z" }` |

`message.delta` is display-only. The final assistant message and report MUST be
read from the REST snapshot.

## Replay

1. Client sends `Last-Event-ID` equal to the last persisted id it applied.
2. Server replays committed events with `id > Last-Event-ID` for that turn.
3. If the cursor is older than the 24-hour retention window, the server
   returns `409 EVENT_CURSOR_EXPIRED`. The client MUST GET
   `/v1/assistant/sessions/{sessionId}` and drop the stale stream.
4. Replay is idempotent: applying the same event id twice must not duplicate
   UI messages.

## Client lifecycle

- Going to background closes the SSE connection and does **not** cancel the turn.
- Returning to foreground: GET snapshot, then reconnect only if a turn is
  queued/running.
- Explicit cancel is `POST /v1/assistant/turns/{turnId}/cancel`.
