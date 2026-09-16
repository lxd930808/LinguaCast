# Assistant V1 contracts — archived

> **Archived (V18):** the research assistant V1 API was removed in V18. The
> service now serves only `/v2/assistant/*` (see `assistant-v2.openapi.yaml`,
> `assistant-sse-v2.md` and `assistant-v2-error-codes.md`); every
> `/v1/assistant/*` business route returns 404. The `/v1/assistant-health/*`
> probes are unchanged.

The following files are kept byte-for-byte for history. They are pinned by the
V15 Gate 0 SHA-256 freeze (`services/research-assistant/tests/evaluation/v15-baseline.test.ts`),
so they carry no in-file archive banner. They do not apply to V18 deployments:

| File | Content |
| --- | --- |
| `assistant-v1.openapi.yaml` | V13/V14 session, turn, search and source-binding API |
| `assistant-v1.wire.schema.json` | JSON Schema mirror used by the frozen V15 baseline replay |
| `assistant-sse-v1.md` | V1 turn event stream |
| `assistant-error-codes.md` | V1 error codes |
| `assistant-v10-integration.md` | V1 source-binding flow against the content service |

Existing V1 data stays in the SQLite `sessions`, `turns`, `messages`,
`reports` and related tables (migration `0001_init.sql` is never dropped).
Back it up with `deploy/research-assistant/backup.sh` and verify with
`restore-verify.sh` before upgrading; restore only into an isolated location.
