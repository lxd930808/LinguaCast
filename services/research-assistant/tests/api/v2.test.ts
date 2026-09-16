import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { loadConfig } from '../../src/config/index.js';
import { createApp } from '../../src/app.js';
import { RedactingLogger } from '../../src/observability/logger.js';
import { openDatabase } from '../../src/db/migrations.js';
import { FakeAgentRuntime, type AgentRuntime } from '../../src/agent/runtime.js';
import type { V10ContentClient } from '../../src/content/v10-client.js';
import { createV2Stack } from '../../src/api/v2/assemble.js';
import { newSourceId } from '../../src/research-v2/state.js';
import { validate, type SchemaNode } from '../support/json-schema-lite.js';

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), '../../migrations');
const TOKEN = 'test-assistant-token-0123456789';
const wireSchema = JSON.parse(
  readFileSync(new URL('../../../../docs/contracts/assistant-v2.wire.schema.json', import.meta.url), 'utf8')
) as SchemaNode;


const fakeV10: V10ContentClient = {
  async lookup() {
    return null;
  },
  async create() {
    throw new Error('create should not run in this test');
  },
  async get() {
    throw new Error('get should not run');
  },
  async downloadSegments() {
    throw new Error('download should not run');
  }
};

function expectValid(def: string, value: unknown, label: string): void {
  const errors = validate({ $ref: `#/definitions/${def}`, definitions: wireSchema.definitions }, value);
  assert.deepEqual(errors, [], `${label} must validate against ${def}:\n${errors.join('\n')}`);
}

function parseSse(text: string): Array<{ id?: string; event: string; data: unknown }> {
  const frames: Array<{ id?: string; event: string; data: unknown }> = [];
  for (const block of text.split('\n\n')) {
    if (!block.trim()) continue;
    let id: string | undefined;
    let event = 'message';
    const dataLines: string[] = [];
    for (const line of block.split('\n')) {
      if (line.startsWith('id:')) id = line.slice(3).trim();
      else if (line.startsWith('event:')) event = line.slice(6).trim();
      else if (line.startsWith('data:')) dataLines.push(line.slice(5).trimStart());
    }
    const raw = dataLines.join('\n');
    frames.push({ id, event, data: raw ? JSON.parse(raw) : null });
  }
  return frames;
}

async function listen(
  app: ReturnType<typeof createApp>
): Promise<{ port: number; close: () => Promise<void> }> {
  await new Promise<void>((resolve) => app.server.listen(0, '127.0.0.1', () => resolve()));
  const port = (app.server.address() as { port: number }).port;
  return {
    port,
    close: async () => {
      await app.close();
    }
  };
}

function harness(env: NodeJS.ProcessEnv = {}, agent: AgentRuntime = new FakeAgentRuntime()) {
  const root = mkdtempSync(join(tmpdir(), 'assistant-v2-api-'));
  const workspaceRoot = join(root, 'workspaces');
  const globalMemoryRoot = join(root, 'global-memory');
  const sharedVersionRoot = join(root, 'shared-versions');
  mkdirSync(workspaceRoot);
  mkdirSync(globalMemoryRoot);
  mkdirSync(sharedVersionRoot);
  const config = loadConfig({
    ASSISTANT_IDENTITY_MODE: 'selfhost', ASSISTANT_SERVICE_TOKEN: TOKEN,
    V10_SERVICE_TOKEN: 'test-v10-token-0123456789',
    V10_BASE_URL: 'https://content.example.test',
    NODE_ENV: 'test',
    ASSISTANT_DATABASE_PATH: join(root, 'a.db'),
    ASSISTANT_TEMP_ROOT: join(root, 'tmp'),
    ASSISTANT_WORKSPACE_ROOT: workspaceRoot,
    ASSISTANT_GLOBAL_MEMORY_ROOT: globalMemoryRoot,
    ASSISTANT_SHARED_VERSION_ROOT: sharedVersionRoot,
    ...env
  });
  const db = openDatabase(config.databasePath, MIGRATIONS);
  const v2 = createV2Stack({ db, config, agent, v10: fakeV10 });
  const app = createApp({
    config,
    logger: new RedactingLogger(() => undefined),
    v2: v2.application,
    readiness: {
      config: async () => ({ ok: true }),
      database: async () => ({ ok: true }),
      tempDir: async () => ({ ok: true }),
      piConfig: async () => ({ ok: true }),
      ytdlp: async () => ({ ok: true })
    }
  });
  return { root, config, db, v2, app, close: () => db.close() };
}

const jsonHeaders = {
  authorization: `Bearer ${TOKEN}`,
  'content-type': 'application/json',
  'idempotency-key': 'ik-create-1'
};

test('V2 is always served and removed V1 business routes return 404', async () => {
  const ctx = harness();
  const { port, close } = await listen(ctx.app);
  try {
    const unauth = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches`);
    assert.equal(unauth.status, 401);
    const body = (await unauth.json()) as { error: { code: string } };
    assert.equal(body.error.code, 'AUTH_REQUIRED');
    const listed = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches`, {
      headers: { authorization: `Bearer ${TOKEN}` }
    });
    assert.equal(listed.status, 200);
    const removed: Array<[string, string]> = [
      ['GET', '/v1/assistant/sessions'],
      ['POST', '/v1/assistant/sessions'],
      ['POST', '/v1/assistant/sessions/as_x/turns'],
      ['GET', '/v1/assistant/turns/at_x/events']
    ];
    for (const [method, path] of removed) {
      const v1 = await fetch(`http://127.0.0.1:${port}${path}`, {
        method,
        headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
        body: method === 'POST' ? JSON.stringify({ outputLanguage: 'zh-Hans' }) : undefined
      });
      assert.equal(v1.status, 404, `${method} ${path}`);
      const v1Body = (await v1.json()) as { error: { code: string } };
      assert.equal(v1Body.error.code, 'NOT_FOUND');
    }
  } finally {
    await close();
    ctx.close();
  }
});

test('V2 research create list snapshot turn SSE and delete', async () => {
  const ctx = harness();
  const { port, close } = await listen(ctx.app);
  const headers = { ...jsonHeaders };
  try {
    const created = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ title: 'AI and accounting', outputLanguage: 'zh-Hans', storefront: 'US' })
    });
    assert.equal(created.status, 201);
    const research = (await created.json()) as { researchId: string; status: string; grants: unknown[] };
    expectValid('Research', research, 'created research');
    assert.match(research.researchId, /^[0-9A-HJKMNP-TV-Z]{26}$/);
    assert.equal(research.status, 'ready');
    assert.equal(JSON.stringify(research).includes(ctx.root), false);

    const reused = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ title: 'AI and accounting', outputLanguage: 'zh-Hans', storefront: 'US' })
    });
    assert.equal(reused.status, 201);
    assert.equal(((await reused.json()) as { researchId: string }).researchId, research.researchId);

    const conflict = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ title: 'Something else', outputLanguage: 'zh-Hans', storefront: 'US' })
    });
    assert.equal(conflict.status, 409);
    const conflictBody = (await conflict.json()) as { error: { code: string } };
    assert.equal(conflictBody.error.code, 'IDEMPOTENCY_CONFLICT');

    const listed = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches`, {
      headers: { authorization: `Bearer ${TOKEN}` }
    });
    assert.equal(listed.status, 200);
    const listBody = await listed.json();
    expectValid('ResearchListResponse', listBody, 'list');

    const snapshot = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}`, {
      headers: { authorization: `Bearer ${TOKEN}` }
    });
    assert.equal(snapshot.status, 200);
    const snapBody = await snapshot.json();
    expectValid('ResearchSnapshot', snapBody, 'snapshot');

    const turn = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}/turns`, {
      method: 'POST',
      headers: { ...headers, 'idempotency-key': 'ik-turn-1' },
      body: JSON.stringify({ message: 'Research AI impact on accounting', mode: 'research' })
    });
    assert.equal(turn.status, 202);
    const accepted = (await turn.json()) as { turnId: string; eventsURL: string; status: string };
    expectValid('TurnAcceptedResponse', accepted, 'turn accepted');
    assert.match(accepted.turnId, /^vt_[0-9A-HJKMNP-TV-Z]{26}$/);
    assert.equal(accepted.eventsURL, `/v2/assistant/turns/${accepted.turnId}/events`);

    const sse = await fetch(`http://127.0.0.1:${port}${accepted.eventsURL}`, {
      headers: { authorization: `Bearer ${TOKEN}` },
      signal: AbortSignal.timeout(10_000)
    });
    assert.equal(sse.status, 200);
    assert.match(sse.headers.get('content-type') ?? '', /text\/event-stream/);
    const frames = parseSse(await sse.text());
    const types = frames.filter((frame) => frame.event !== 'heartbeat').map((frame) => frame.event);
    assert.equal(types[0], 'turn.started');
    assert.ok(types.includes('workspace.created'));
    assert.ok(types.includes('report.completed'));
    assert.equal(types.at(-1), 'turn.completed');
    for (const frame of frames.filter((item) => item.event !== 'heartbeat')) {
      expectValid('SseEventData', frame.data, String(frame.event));
      const data = frame.data as { schemaVersion: number; type: string; payload: Record<string, unknown> };
      assert.equal(data.schemaVersion, 2);
      assert.equal(data.type, frame.event);
      assert.equal(JSON.stringify(data.payload).includes(ctx.root), false);
    }

    const replay = await fetch(`http://127.0.0.1:${port}${accepted.eventsURL}`, {
      headers: { authorization: `Bearer ${TOKEN}`, 'Last-Event-ID': frames[0]?.id ?? '1' },
      signal: AbortSignal.timeout(10_000)
    });
    assert.equal(replay.status, 200);
    const replayed = parseSse(await replay.text()).filter((frame) => frame.event !== 'heartbeat');
    assert.ok(replayed.every((frame) => Number(frame.id) > Number(frames[0]?.id)));

    const artifacts = await fetch(
      `http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}/artifacts`,
      { headers: { authorization: `Bearer ${TOKEN}` } }
    );
    assert.equal(artifacts.status, 200);
    const artifactList = await artifacts.json();
    expectValid('ArtifactListResponse', artifactList, 'artifact list');
    const report = (artifactList as { artifacts: Array<{ artifactId: string; kind: string }> }).artifacts.find(
      (item) => item.kind === 'report'
    );
    assert.ok(report);
    const body = await fetch(
      `http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}/artifacts/${report.artifactId}`,
      { headers: { authorization: `Bearer ${TOKEN}` } }
    );
    assert.equal(body.status, 200);
    const artifactBody = await body.json();
    expectValid('ArtifactBody', artifactBody, 'artifact body');
    assert.equal(JSON.stringify(artifactBody).includes('relativePath'), false);

    const pathInject = await fetch(
      `http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}/artifacts?path=/etc/passwd`,
      { headers: { authorization: `Bearer ${TOKEN}` } }
    );
    assert.equal(pathInject.status, 400);
    assert.equal(((await pathInject.json()) as { error: { code: string } }).error.code, 'INVALID_REQUEST');

    const missingConfirm = await fetch(
      `http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}/sources/${newSourceId()}/transcription`,
      {
        method: 'POST',
        headers: { ...headers, 'idempotency-key': 'ik-tx-1' },
        body: JSON.stringify({ confirmed: true, targetLanguage: 'zh-Hans', translationQuality: 'quality' })
      }
    );
    assert.equal(missingConfirm.status, 404);
    assert.equal(((await missingConfirm.json()) as { error: { code: string } }).error.code, 'SOURCE_NOT_FOUND');

    const unconfirmed = await fetch(
      `http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}/sources/${newSourceId()}/transcription`,
      {
        method: 'POST',
        headers: { ...headers, 'idempotency-key': 'ik-tx-2' },
        body: JSON.stringify({ targetLanguage: 'zh-Hans', translationQuality: 'quality' })
      }
    );
    assert.equal(unconfirmed.status, 400);
    assert.equal(
      ((await unconfirmed.json()) as { error: { code: string } }).error.code,
      'TRANSCRIPT_CONFIRMATION_REQUIRED'
    );

    const deleted = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}`, {
      method: 'DELETE',
      headers: { ...headers, 'idempotency-key': 'ik-del-1' }
    });
    assert.equal(deleted.status, 202);
    const gone = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}`, {
      headers: { authorization: `Bearer ${TOKEN}` }
    });
    assert.equal(gone.status, 404);
    const deletedAgain = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}`, {
      method: 'DELETE',
      headers: { ...headers, 'idempotency-key': 'ik-del-2' }
    });
    assert.equal(deletedAgain.status, 204);
  } finally {
    await close();
    ctx.close();
  }
});

test('V2 transcription confirmation is minted by the route not the model', async () => {
  const ctx = harness();
  const { port, close } = await listen(ctx.app);
  try {
    const created = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches`, {
      method: 'POST',
      headers: jsonHeaders,
      body: JSON.stringify({ title: 'Transcript source', outputLanguage: 'zh-Hans' })
    });
    const research = (await created.json()) as { researchId: string };
    const sourceId = newSourceId();
    ctx.v2!.orchestrator.writerFor(research.researchId).save({
      kind: 'youtube_search',
      producer: 'search_youtube',
      evidenceLevel: 'search_metadata',
      contents: JSON.stringify({
        results: [
          {
            sourceId: 'dQw4w9WgXcQ',
            assistantSourceId: sourceId,
            canonicalURL: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
            title: 'Demo'
          }
        ]
      })
    });
    const response = await fetch(
      `http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}/sources/${sourceId}/transcription`,
      {
        method: 'POST',
        headers: { ...jsonHeaders, 'idempotency-key': 'ik-tx-ok' },
        body: JSON.stringify({ confirmed: true, targetLanguage: 'zh-Hans', translationQuality: 'quality' })
      }
    );
    const payload = (await response.json()) as { error?: { code: string }; confirmationToken?: string };
    assert.notEqual(response.status, 401);
    assert.equal(payload.confirmationToken, undefined);
    assert.notEqual(payload.error?.code, 'TRANSCRIPT_CONFIRMATION_REQUIRED');
    const stored = ctx.v2!.store.listTranscriptJobs(research.researchId);
    assert.ok(stored.some((job) => job.confirmationTokenHash && job.sourceId === sourceId));
  } finally {
    await close();
    ctx.close();
  }
});

test('V2 podcast episode with feed and enclosure is eligible; show is not', async () => {
  const ctx = harness();
  const { port, close } = await listen(ctx.app);
  try {
    const created = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches`, {
      method: 'POST',
      headers: jsonHeaders,
      body: JSON.stringify({ title: 'Podcast source', outputLanguage: 'zh-Hans' })
    });
    const research = (await created.json()) as { researchId: string };
    const episodeId = newSourceId();
    const showId = newSourceId();
    const writer = ctx.v2!.orchestrator.writerFor(research.researchId);
    writer.save({
      kind: 'podcast_search',
      producer: 'search_podcasts',
      evidenceLevel: 'search_metadata',
      contents: JSON.stringify({
        results: [
          {
            sourceId: 'ep-1',
            assistantSourceId: episodeId,
            nativeSourceId: 'ep-1',
            canonicalURL: 'https://podcasts.apple.com/episode/id9',
            title: 'Episode 9',
            feedURL: 'https://feeds.example.test/show.xml',
            enclosureUrl: 'https://cdn.example.test/9.mp3'
          },
          {
            sourceId: 'show-1',
            assistantSourceId: showId,
            nativeSourceId: 'show-1',
            canonicalURL: 'https://podcasts.apple.com/show/id1',
            title: 'Show',
            feedURL: 'https://feeds.example.test/show.xml',
            enclosureUrl: null
          }
        ]
      })
    });
    const showResponse = await fetch(
      `http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}/sources/${showId}/transcription`,
      {
        method: 'POST',
        headers: { ...jsonHeaders, 'idempotency-key': 'ik-tx-show' },
        body: JSON.stringify({ confirmed: true, targetLanguage: 'zh-Hans', translationQuality: 'quality' })
      }
    );
    const showPayload = (await showResponse.json()) as { error?: { code: string } };
    assert.equal(showResponse.status, 409);
    assert.equal(showPayload.error?.code, 'TRANSCRIPT_SOURCE_NOT_ELIGIBLE');
    const episodeResponse = await fetch(
      `http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}/sources/${episodeId}/transcription`,
      {
        method: 'POST',
        headers: { ...jsonHeaders, 'idempotency-key': 'ik-tx-episode' },
        body: JSON.stringify({ confirmed: true, targetLanguage: 'zh-Hans', translationQuality: 'quality' })
      }
    );
    const episodePayload = (await episodeResponse.json()) as { error?: { code: string } };
    assert.notEqual(episodePayload.error?.code, 'TRANSCRIPT_SOURCE_NOT_ELIGIBLE');
    assert.ok(ctx.v2!.store.listTranscriptJobs(research.researchId).some((job) => job.sourceId === episodeId));
  } finally {
    await close();
    ctx.close();
  }
});

test('V2 memory confirm and reject round-trip', async () => {
  const ctx = harness();
  const { port, close } = await listen(ctx.app);
  try {
    const created = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches`, {
      method: 'POST',
      headers: jsonHeaders,
      body: JSON.stringify({ title: 'Memory', outputLanguage: 'zh-Hans' })
    });
    const research = (await created.json()) as { researchId: string };
    const proposal = ctx.v2!.orchestrator.memoryProposals.propose({
      researchId: research.researchId,
      content: 'Write future reports in Simplified Chinese by default.',
      reason: 'User asked for Chinese output in this research.'
    });
    const confirmed = await fetch(
      `http://127.0.0.1:${port}/v2/assistant/memory-proposals/${proposal.proposalId}/confirm`,
      {
        method: 'POST',
        headers: { authorization: `Bearer ${TOKEN}`, 'idempotency-key': 'ik-mem-1' }
      }
    );
    assert.equal(confirmed.status, 200);
    const entry = await confirmed.json();
    expectValid('MemoryEntry', entry, 'confirmed preference');
    const memory = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}/memory`, {
      headers: { authorization: `Bearer ${TOKEN}` }
    });
    assert.equal(memory.status, 200);
    expectValid('MemorySnapshot', await memory.json(), 'memory snapshot');

    const other = ctx.v2!.orchestrator.memoryProposals.propose({
      researchId: research.researchId,
      content: 'Prefer short reports.',
      reason: 'User asked for brevity.'
    });
    const rejected = await fetch(
      `http://127.0.0.1:${port}/v2/assistant/memory-proposals/${other.proposalId}/reject`,
      {
        method: 'POST',
        headers: { authorization: `Bearer ${TOKEN}`, 'idempotency-key': 'ik-mem-2' }
      }
    );
    assert.equal(rejected.status, 200);
    expectValid('MemoryProposal', await rejected.json(), 'rejected proposal');
  } finally {
    await close();
    ctx.close();
  }
});

test('expired Last-Event-ID returns EVENT_CURSOR_EXPIRED', async () => {
  const ctx = harness();
  const { port, close } = await listen(ctx.app);
  try {
    const created = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches`, {
      method: 'POST',
      headers: jsonHeaders,
      body: JSON.stringify({ title: 'Cursor', outputLanguage: 'zh-Hans' })
    });
    const research = (await created.json()) as { researchId: string };
    const turn = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}/turns`, {
      method: 'POST',
      headers: { ...jsonHeaders, 'idempotency-key': 'ik-turn-cursor' },
      body: JSON.stringify({ message: 'hello', mode: 'research' })
    });
    const accepted = (await turn.json()) as { turnId: string; eventsURL: string };
    await fetch(`http://127.0.0.1:${port}${accepted.eventsURL}`, {
      headers: { authorization: `Bearer ${TOKEN}` },
      signal: AbortSignal.timeout(10_000)
    });
    const first = ctx.v2!.store.eventsSince(accepted.turnId, 0)[0];
    assert.ok(first);
    const old = new Date(Date.now() - 25 * 60 * 60 * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
    ctx.v2!.store.getDb().prepare('UPDATE v2_events SET occurred_at = ? WHERE event_id = ?').run(old, first.eventId);
    const expired = await fetch(`http://127.0.0.1:${port}${accepted.eventsURL}`, {
      headers: { authorization: `Bearer ${TOKEN}`, 'Last-Event-ID': String(first.eventId) }
    });
    assert.equal(expired.status, 409);
    const body = (await expired.json()) as { error: { code: string } };
    assert.equal(body.error.code, 'EVENT_CURSOR_EXPIRED');
    expectValid('ErrorEnvelope', body, 'cursor expired');
  } finally {
    await close();
    ctx.close();
  }
});

test('thinking and tool events stream and survive into snapshot turnWork', async () => {
  const agent = new FakeAgentRuntime([
    { type: 'thinking', thinking: { stage: 'start', blockId: 'th_0' } },
    { type: 'thinking', thinking: { stage: 'delta', blockId: 'th_0', text: 'The user wants research. I will search.' } },
    { type: 'thinking', thinking: { stage: 'end', blockId: 'th_0', durationMs: 1200 } },
    { type: 'tool_call', tool: 'web_search', callId: 'call_1', args: { query: 'ai accounting' } },
    { type: 'done' }
  ]);
  const ctx = harness({}, agent);
  const { port, close } = await listen(ctx.app);
  try {
    const created = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches`, {
      method: 'POST',
      headers: jsonHeaders,
      body: JSON.stringify({ title: 'Turn work', outputLanguage: 'zh-Hans' })
    });
    const research = (await created.json()) as { researchId: string };
    const turn = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}/turns`, {
      method: 'POST',
      headers: { ...jsonHeaders, 'idempotency-key': 'ik-turn-work' },
      body: JSON.stringify({ message: 'Research AI impact on accounting', mode: 'research' })
    });
    const accepted = (await turn.json()) as { turnId: string; eventsURL: string };
    const sse = await fetch(`http://127.0.0.1:${port}${accepted.eventsURL}`, {
      headers: { authorization: `Bearer ${TOKEN}` },
      signal: AbortSignal.timeout(10_000)
    });
    const frames = parseSse(await sse.text()).filter((frame) => frame.event !== 'heartbeat');
    const types = frames.map((frame) => frame.event);
    assert.ok(types.includes('thinking.started'));
    assert.ok(types.includes('thinking.delta'));
    assert.ok(types.includes('thinking.completed'));
    assert.ok(types.indexOf('tool.started') < types.indexOf('tool.completed'));
    const toolCompleted = frames.find((frame) => frame.event === 'tool.completed')?.data as {
      payload: { ok: boolean };
    };
    assert.equal(toolCompleted.payload.ok, false);

    const snapshot = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}`, {
      headers: { authorization: `Bearer ${TOKEN}` }
    });
    const snapBody = (await snapshot.json()) as { turnWork: Array<Record<string, unknown>> };
    expectValid('ResearchSnapshot', snapBody, 'snapshot with turnWork');
    assert.equal(snapBody.turnWork.length, 1);
    const work = snapBody.turnWork[0];
    expectValid('TurnWork', work, 'turnWork entry');
    assert.equal(work.turnId, accepted.turnId);
    const thinking = work.thinking as { status: string; text: string; redacted: boolean; durationMs: number };
    assert.equal(thinking.status, 'done');
    assert.equal(thinking.redacted, false);
    assert.equal(thinking.text, 'The user wants research. I will search.');
    assert.equal(thinking.durationMs, 1200);
    const tools = work.tools as Array<{ callId: string; tool: string; labelKey: string; status: string; query?: string }>;
    assert.equal(tools.length, 1);
    assert.equal(tools[0].tool, 'web_search');
    assert.equal(tools[0].labelKey, 'web_search');
    assert.equal(tools[0].status, 'failed');
    assert.equal(tools[0].query, 'ai accounting');
  } finally {
    await close();
    ctx.close();
  }
});
