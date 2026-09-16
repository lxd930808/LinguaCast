# Assistant SSE v2

> Frozen with V15 WP1. SSE is a projection of the durable `v2_events` table, not
> the source of truth. Complete search results, web pages, transcripts, memory
> bodies, and reports are read from artifact REST. After disconnect, clients
> SHOULD reconnect with `Last-Event-ID`; if the cursor is expired they MUST GET
> `/v2/assistant/researches/{researchId}` and drop the stale stream.

V1 SSE (`assistant-sse-v1.md`) is archived; V18 removed the `/v1/assistant/*` business routes.

## Endpoint

```
GET /v2/assistant/turns/{turnId}/events
Authorization: Bearer <assistant-service-token>
Last-Event-ID: <optional monotonic event id>
X-Client-Version: <optional>
X-Request-ID: <optional>
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
event: report.delta
data: {"schemaVersion":2,"eventId":42,"sequence":7,"researchId":"01ARZ3NDEKTSV4RRFFQ69G5FAV","turnId":"vt_01ARZ3NDEKTSV4RRFFQ69G5FB0","type":"report.delta","occurredAt":"2026-09-03T01:02:03Z","payload":{"text":"..."}}
```

Rules:

- `id` is the durable integer `eventId` for that turn. It never repeats and never goes backward.
- `event` equals `data.type`. Unknown types MUST be ignored, then the client SHOULD refresh the Research snapshot once.
- `data` is a single JSON object. Multi-line `data:` frames concatenate with `\n`.
- Envelope fields are always `schemaVersion`, `eventId`, `sequence`, `researchId`, `turnId`, `type`, `occurredAt`, `payload`.
- Heartbeats use `event: heartbeat` and `{ "t": <rfc3339> }` only (no research envelope required).
- Heartbeat interval is 15 seconds.
- Payload objects carry stable IDs, status, counts, and restricted deltas. They MUST NOT include real paths, argv, headers, cookies, provider keys, full artifact bodies, or unbounded report text.
- `report.delta` `payload.text` is display-only, max 512 UTF-8 characters per event. The final report is the REST artifact after `report.completed`.

## Event types

| Type | When | Payload |
| --- | --- | --- |
| `workspace.created` | Workspace directory + initial manifest committed | `{ "workspaceStatus": "ready" }` |
| `web.search_started` | Web search tool began | `{ "artifactId": "<ulid>", "query": "..." }` |
| `web.search_completed` | Web search artifact ready (success or empty) | `{ "artifactId": "<ulid>", "status": "success\|empty", "resultCount": 0 }` |
| `web.search_failed` | Web search failed; failure artifact saved | `{ "artifactId": "<ulid>", "code": "WEB_SEARCH_FAILED" }` |
| `web.page_saved` | Page extract committed | `{ "artifactId": "<ulid>", "evidenceLevel": "primary_content" }` |
| `source.saved` | YouTube/Podcast/web search or page artifact ready | `{ "artifactId": "<ulid>", "kind": "youtube_search\|podcast_search\|web_search\|web_page" }` |
| `transcript.job_updated` | TranscriptJob status changed | `{ "transcriptJobId": "tj_...", "status": "running", "progress": 0.4 }` |
| `transcript.saved` | Source-only transcript artifact ready | `{ "artifactId": "<ulid>", "transcriptJobId": "tj_..." }` |
| `memory.updated` | Research memory artifact replaced | `{ "artifactId": "<ulid>", "entryCount": 3 }` |
| `memory.proposed` | Global preference proposal created | `{ "proposalId": "mp_...", "status": "pending" }` |
| `thinking.started` | One model reasoning block began | `{ "blockId": "th_0" }` |
| `thinking.delta` | Streaming reasoning text | `{ "blockId": "th_0", "text": "partial" }` |
| `thinking.completed` | Reasoning block finished; full text is only in `snapshot.turnWork` | `{ "blockId": "th_0", "durationMs": 12000, "redacted": true }` |
| `tool.started` | Whitelisted business tool began | `{ "callId": "call_1", "tool": "search_youtube", "query": "..." }` |
| `tool.completed` | Tool finished | `{ "callId": "call_1", "tool": "search_youtube", "ok": true }` |
| `report.delta` | Streaming report draft | `{ "text": "partial" }` |
| `report.completed` | Report file, manifest, citations, and DB projection committed | `{ "artifactId": "<ulid>", "citationCount": 4 }` |
| `turn.started` | Worker claimed the turn | `{ "mode": "research\|content_qa" }` |
| `turn.completed` | Terminal success | `{ "status": "completed" }` |
| `turn.failed` | Terminal failure | `{ "code": "MODEL_PROVIDER_UNAVAILABLE", "retryable": true }` |
| `turn.cancelled` | User cancel committed | `{ "code": "TURN_CANCELLED" }` |
| `heartbeat` | Keep-alive | `{ "t": "2026-09-03T01:02:18Z" }` |

Turn-work rules:

- `thinking.delta` `payload.text` is display-only, max 512 UTF-8 characters per event, same rule as `report.delta`. `thinking.completed` does not repeat the full text; clients fold live text from deltas and reload folded text from `snapshot.turnWork` after refresh.
- `thinking.completed` `payload.redacted` is `true` when the provider redacted the reasoning. Redacted blocks emit no `thinking.delta`; clients must show a placeholder instead of any text.
- `tool.started` / `tool.completed` payloads carry only `callId`, `tool`, and an optional `query` (max 200 chars, from the tool's `query` argument). They never include paths, argv, URIs, or raw tool JSON.
- Clients that recognize the `thinking.*` and `tool.*` types MUST NOT refresh the whole snapshot because of them; only unknown types trigger a refresh.

`report.completed` MUST be emitted only after the report artifact is `ready`. Clients must not treat concatenated `report.delta` text as the final report.

## Order

Typical research Turn:

1. `turn.started`
2. `workspace.created` (only if this is the first turn after create; create REST may already have committed the workspace)
3. Zero or more `thinking.started` → `thinking.delta`* → `thinking.completed` groups interleaved with `tool.started` / `tool.completed`
4. Zero or more `web.search_*`, `source.saved`, `web.page_saved`, `transcript.job_updated`, `transcript.saved`, `memory.updated`, `memory.proposed`; `tool.started` for a search tool always precedes its `source.saved`
5. Zero or more `report.delta`
6. `report.completed` (research Turn that produced a report)
7. Exactly one of `turn.completed` | `turn.failed` | `turn.cancelled`

Partial source failure does not skip already-saved artifact events. Cancel keeps ready artifacts; it does not emit deletes.

## Replay

1. Client sends `Last-Event-ID` equal to the last persisted id it applied.
2. Server replays committed events with `eventId > Last-Event-ID` for that turn.
3. If the cursor is older than the 24-hour retention window, the server returns `409 EVENT_CURSOR_EXPIRED`. The client MUST GET `/v2/assistant/researches/{researchId}` and drop the stale stream.
4. Replay is idempotent: applying the same `eventId` twice must not duplicate UI cards or messages.
5. Duplicate frames with the same `eventId` are ignored.
6. Heartbeats are not durable and are not replayed.

## Client lifecycle

- Going to background closes the SSE connection and does **not** cancel the turn.
- Returning to foreground: GET Research snapshot, then reconnect only if a turn is queued/running/interrupted.
- Explicit cancel is `POST /v2/assistant/turns/{turnId}/cancel` with `Idempotency-Key`.
- Unknown events: ignore payload, refresh snapshot once, keep the stream.
