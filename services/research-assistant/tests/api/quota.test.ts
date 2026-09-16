import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import type { AgentEvent, AgentRuntime } from '../../src/agent/runtime.js';
import { FakeAgentRuntime } from '../../src/agent/runtime.js';
import { createApp } from '../../src/app.js';
import { IdentityResolver } from '../../src/auth/identity.js';
import { loadConfig } from '../../src/config/index.js';
import type { V10ContentClient } from '../../src/content/v10-client.js';
import { openDatabase } from '../../src/db/migrations.js';
import { createV2Stack } from '../../src/api/v2/assemble.js';
import { RedactingLogger } from '../../src/observability/logger.js';
import { QuotaError, type QuotaClient, type ReserveRequest, type ReservationView } from '../../src/quota/quota-client.js';
import { TurnSettlementDispatcher } from '../../src/quota/settlement-dispatcher.js';
import { TurnScheduler } from '../../src/quota/turn-scheduler.js';

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), '../../migrations');
const ACCOUNT_A = `acc_${'A'.repeat(26)}`;
const ACCOUNT_B = `acc_${'B'.repeat(26)}`;
const TOKENS: Record<string, string> = { 'lca_token-a': ACCOUNT_A, 'lca_token-b': ACCOUNT_B };

const fakeV10: V10ContentClient = {
  async lookup() {
    return null;
  },
  async create() {
    throw new Error('not used');
  },
  async get() {
    throw new Error('not used');
  },
  async downloadSegments() {
    throw new Error('not used');
  }
};

class FakeQuota implements QuotaClient {
  limit = 20;
  down = false;
  readonly calls: ReserveRequest[] = [];
  readonly settled: Array<[string, string, string]> = [];
  private readonly rows = new Map<string, ReservationView & { accountId: string }>();
  private seq = 0;

  async reserve(request: ReserveRequest): Promise<ReservationView> {
    if (this.down) throw new QuotaError(503, 'ACCOUNT_SERVICE_UNAVAILABLE', 'down', true);
    this.calls.push(request);
    const existing = [...this.rows.values()].find((r) => r.accountId === request.accountId && r.operationKey === request.operationKey);
    if (existing) return { ...existing };
    const used = [...this.rows.values()].filter((r) => r.accountId === request.accountId && r.status !== 'released').length;
    if (used + request.amount > this.limit) {
      throw new QuotaError(429, 'QUOTA_EXCEEDED', 'daily quota is exhausted', false, {
        kind: 'assistant',
        remaining: 0,
        resetAt: '2026-09-14T16:00:00.000Z'
      });
    }
    const row = {
      reservationId: `qr_${String(++this.seq).padStart(26, '0')}`,
      status: 'reserved' as const,
      amount: request.amount,
      operationKey: request.operationKey,
      accountId: request.accountId
    };
    this.rows.set(row.reservationId, row);
    return { ...row };
  }

  async settle(reservationId: string, outcome: 'consumed' | 'released', reason: string): Promise<'settled' | 'conflict'> {
    if (this.down) throw new QuotaError(503, 'ACCOUNT_SERVICE_UNAVAILABLE', 'down', true);
    const row = this.rows.get(reservationId);
    if (!row || (row.status !== 'reserved' && row.status !== outcome)) return 'conflict';
    if (row.status === 'reserved') {
      row.status = outcome;
      this.settled.push([reservationId, outcome, reason]);
    }
    return 'settled';
  }
}

/** Agent whose runs wait until released (keeps a turn running). */
class GatedAgent implements AgentRuntime {
  started = 0;
  private waiters: Array<() => void> = [];

  releaseAll(): void {
    for (const release of this.waiters.splice(0)) release();
  }

  async *run(input: Parameters<AgentRuntime['run']>[0]): AsyncIterable<AgentEvent> {
    this.started += 1;
    await new Promise<void>((resolve) => {
      this.waiters.push(resolve);
      input.signal.addEventListener('abort', () => resolve(), { once: true });
    });
    yield { type: 'done' };
  }
}

class FailingAgent implements AgentRuntime {
  // eslint-disable-next-line require-yield
  async *run(): AsyncIterable<AgentEvent> {
    throw new Error('model provider unavailable');
  }
}

async function waitFor(check: () => boolean, label: string, timeoutMs = 5000): Promise<void> {
  const started = Date.now();
  while (!check()) {
    if (Date.now() - started > timeoutMs) assert.fail(`timed out waiting for ${label}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

async function harness(options: { agent?: AgentRuntime; env?: NodeJS.ProcessEnv } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'assistant-quota-'));
  for (const dir of ['workspaces', 'global-memory', 'shared-versions']) mkdirSync(join(root, dir));
  const config = loadConfig({
    ASSISTANT_IDENTITY_MODE: 'account',
    ACCOUNT_SERVICE_URL: 'http://account.internal:3240',
    ASSISTANT_ACCOUNT_TOKEN: 'assistant-introspection-token-0123456789',
    ACCOUNT_CONTEXT_SIGNING_KEY: 'assistant-quota-context-signing-key-0123',
    V10_SERVICE_TOKEN: 'test-v10-token-0123456789',
    V10_BASE_URL: 'https://content.example.test',
    NODE_ENV: 'test',
    ASSISTANT_DATABASE_PATH: join(root, 'a.db'),
    ASSISTANT_TEMP_ROOT: join(root, 'tmp'),
    ASSISTANT_WORKSPACE_ROOT: join(root, 'workspaces'),
    ASSISTANT_GLOBAL_MEMORY_ROOT: join(root, 'global-memory'),
    ASSISTANT_SHARED_VERSION_ROOT: join(root, 'shared-versions'),
    ...options.env
  });
  const identity = new IdentityResolver({
    mode: 'account',
    selfhostToken: null,
    accountServiceUrl: config.identity.accountServiceUrl,
    introspectionToken: config.identity.introspectionToken,
    internalCallers: [],
    contextSigningKey: config.identity.contextSigningKey,
    fetchImpl: (async (_url: string | URL | Request, init?: RequestInit) => {
      const { token } = JSON.parse(String(init?.body)) as { token: string };
      const accountId = TOKENS[token];
      return new Response(
        JSON.stringify(accountId ? { active: true, identity: { accountId, authMode: 'apple', sessionId: 's' } } : { active: false }),
        { status: 200 }
      );
    }) as typeof fetch
  });
  const db = openDatabase(config.databasePath, MIGRATIONS);
  const quota = new FakeQuota();
  const v2 = createV2Stack({ db, config, agent: options.agent ?? new FakeAgentRuntime(), v10: fakeV10, quota });
  const app = createApp({
    config,
    logger: new RedactingLogger(() => undefined),
    v2: v2.application,
    identity,
    readiness: { config: async () => ({ ok: true }), database: async () => ({ ok: true }) } as never
  });
  await new Promise<void>((resolve) => app.server.listen(0, '127.0.0.1', () => resolve()));
  const base = `http://127.0.0.1:${(app.server.address() as { port: number }).port}`;
  let seq = 0;
  const call = async (method: string, path: string, token: string, body?: unknown) => {
    const response = await fetch(`${base}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${token}`,
        'idempotency-key': `key-${++seq}`,
        ...(body !== undefined ? { 'content-type': 'application/json' } : {})
      },
      body: body === undefined ? undefined : JSON.stringify(body)
    });
    const text = await response.text();
    return { status: response.status, body: text ? (JSON.parse(text) as any) : null };
  };
  const research = async (token: string) => (await call('POST', '/v2/assistant/researches', token, { title: 'q' })).body.researchId as string;
  const turn = (token: string, researchId: string) =>
    call('POST', `/v2/assistant/researches/${researchId}/turns`, token, { mode: 'research', message: 'hello' });
  return {
    config,
    v2,
    quota,
    call,
    research,
    turn,
    close: async () => {
      await app.close();
      db.close();
    }
  };
}

test('each turn reserves one unit; completion consumes it through the outbox', async () => {
  const h = await harness();
  try {
    const researchId = await h.research('lca_token-a');
    const accepted = await h.turn('lca_token-a', researchId);
    assert.equal(accepted.status, 202);
    const turnId = accepted.body.turnId as string;
    assert.deepEqual(h.quota.calls, [{ accountId: ACCOUNT_A, operationKey: `assistant-turn:${turnId}`, amount: 1, subjectRef: turnId }]);
    const row = h.v2.store.getTurn(turnId)!;
    assert.ok(row.reservationId);
    await waitFor(() => h.v2.store.getTurn(turnId)?.status === 'completed', 'turn completion');
    assert.deepEqual(
      { ...h.v2.store.settlementFor(row.reservationId!) },
      { reservationId: row.reservationId, outcome: 'consumed', reason: 'succeeded', turnId, attempts: 0, deliveredAt: null }
    );
    const dispatcher = new TurnSettlementDispatcher({ store: h.v2.store, client: h.quota, logger: new RedactingLogger(() => undefined) });
    assert.equal((await dispatcher.runOnce()).delivered, 1);
    assert.deepEqual(h.quota.settled.map(([, outcome, reason]) => [outcome, reason]), [['consumed', 'succeeded']]);
    assert.equal(h.v2.store.listQuotaIntents(Number.MAX_SAFE_INTEGER).length, 0);
  } finally {
    await h.close();
  }
});

test('exhausted quota rejects the turn before anything is stored; outages fail closed', async () => {
  const h = await harness();
  try {
    h.quota.limit = 0;
    const researchId = await h.research('lca_token-a');
    const rejected = await h.turn('lca_token-a', researchId);
    assert.equal(rejected.status, 429);
    assert.equal(rejected.body.error.code, 'QUOTA_EXCEEDED');
    assert.equal(rejected.body.error.params.resetAt, '2026-09-14T16:00:00.000Z');
    assert.deepEqual(h.v2.store.listTurns(researchId), []);
    assert.equal(h.v2.store.listQuotaIntents(Number.MAX_SAFE_INTEGER).length, 0);

    h.quota.limit = 20;
    h.quota.down = true;
    const down = await h.turn('lca_token-a', researchId);
    assert.equal(down.status, 503);
    assert.equal(down.body.error.code, 'ACCOUNT_SERVICE_UNAVAILABLE');
    assert.deepEqual(h.v2.store.listTurns(researchId), []);
  } finally {
    await h.close();
  }
});

test('failed and cancelled turns release; queued turns wait for their account slot', async () => {
  const gated = new GatedAgent();
  const h = await harness({ agent: gated, env: { ASSISTANT_GLOBAL_PI_TURNS: '2' } });
  try {
    const a1 = await h.research('lca_token-a');
    const a2 = await h.research('lca_token-a');
    const b1 = await h.research('lca_token-b');
    const first = (await h.turn('lca_token-a', a1)).body.turnId as string;
    await waitFor(() => gated.started === 1, 'first A turn start');
    const second = (await h.turn('lca_token-a', a2)).body.turnId as string;
    const other = (await h.turn('lca_token-b', b1)).body.turnId as string;
    await waitFor(() => gated.started === 2, 'B turn start');
    assert.equal(h.v2.store.getTurn(second)?.status, 'queued', 'A allows one running turn');
    assert.equal(h.v2.store.getTurn(other)?.status, 'running', 'B has its own slot');

    const cancel = await h.call('POST', `/v2/assistant/turns/${second}/cancel`, 'lca_token-a');
    assert.equal(cancel.status, 200);
    assert.equal(h.v2.store.settlementFor(h.v2.store.getTurn(second)!.reservationId!)?.reason, 'cancelled');

    gated.releaseAll();
    await waitFor(() => h.v2.store.getTurn(first)?.status === 'completed' && h.v2.store.getTurn(other)?.status === 'completed', 'completion');
    assert.equal(h.v2.store.getTurn(second)?.status, 'cancelled', 'a cancelled queued turn never starts');
    assert.equal(gated.started, 2);
  } finally {
    gated.releaseAll();
    await h.close();
  }
});

test('a model failure releases the reservation', async () => {
  const h = await harness({ agent: new FailingAgent() });
  try {
    const researchId = await h.research('lca_token-a');
    const turnId = (await h.turn('lca_token-a', researchId)).body.turnId as string;
    await waitFor(() => h.v2.store.getTurn(turnId)?.status === 'failed', 'turn failure');
    const settlement = h.v2.store.settlementFor(h.v2.store.getTurn(turnId)!.reservationId!);
    assert.deepEqual([settlement?.outcome, settlement?.reason], ['released', 'failed']);
  } finally {
    await h.close();
  }
});

test('recovery re-creates lost settlements and releases reservations of turns that were never inserted', async () => {
  const h = await harness({ agent: new GatedAgent() });
  try {
    const researchId = await h.research('lca_token-a');
    const turnId = (await h.turn('lca_token-a', researchId)).body.turnId as string;
    const reservationId = h.v2.store.getTurn(turnId)!.reservationId!;
    const db = h.v2.store.getDb();
    db.prepare("UPDATE v2_turns SET status = 'interrupted' WHERE turn_id = ?").run(turnId);
    assert.equal(h.v2.store.settlementFor(reservationId), null, 'simulated crash lost the outbox row');
    h.v2.store.recordQuotaIntent('assistant-turn:vt_crashed', ACCOUNT_A, 'vt_crashed', 1, Date.now() - 120_000);

    const result = await new TurnSettlementDispatcher({ store: h.v2.store, client: h.quota, logger: new RedactingLogger(() => undefined) }).runOnce();
    assert.equal(result.repaired, 1);
    assert.equal(result.intents, 1);
    assert.deepEqual(
      h.quota.settled.map(([, outcome, reason]) => [outcome, reason]).sort(),
      [
        ['released', 'failed'],
        ['released', 'rejected_before_start']
      ]
    );
  } finally {
    await h.close();
  }
});

test('scheduler starts turns FIFO within per-account and global limits', async () => {
  const queue = [
    { turnId: 't1', ownerScope: 'a' },
    { turnId: 't2', ownerScope: 'a' },
    { turnId: 't3', ownerScope: 'b' },
    { turnId: 't4', ownerScope: 'c' }
  ];
  const finishers = new Map<string, () => void>();
  const started: string[] = [];
  const scheduler = new TurnScheduler({
    store: { listQueuedTurns: () => queue.filter((turn) => !started.includes(turn.turnId)) },
    run: (turnId) => {
      started.push(turnId);
      return new Promise<void>((resolve) => finishers.set(turnId, resolve));
    },
    limits: { perOwner: 1, global: 2 }
  });
  scheduler.enqueue();
  assert.deepEqual(started, ['t1', 't3']);
  finishers.get('t1')!();
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(started, ['t1', 't3', 't2']);
  finishers.get('t3')!();
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(started, ['t1', 't3', 't2', 't4']);
});
