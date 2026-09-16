import assert from 'node:assert/strict';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { createApp } from '../../src/app.js';
import { ACCOUNT_CONTEXT_HEADER, signAccountContext, verifyAccountContext } from '../../src/auth/account-context.js';
import { IdentityResolver } from '../../src/auth/identity.js';
import { loadConfig } from '../../src/config/index.js';
import { HttpV10ContentClient, type V10ContentClient } from '../../src/content/v10-client.js';
import { openDatabase } from '../../src/db/migrations.js';
import { FakeAgentRuntime } from '../../src/agent/runtime.js';
import { createV2Stack } from '../../src/api/v2/assemble.js';
import { RedactingLogger } from '../../src/observability/logger.js';

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), '../../migrations');
const SIGNING_KEY = 'assistant-test-context-signing-key-012345';
const ACCOUNT_CALLER = 'account-caller-token-0123456789abcdef00';
const ACCOUNT_A = `acc_${'A'.repeat(26)}`;
const ACCOUNT_B = `acc_${'B'.repeat(26)}`;

const INTROSPECTION: Record<string, unknown> = {
  'lca_token-a': { active: true, identity: { accountId: ACCOUNT_A, authMode: 'apple', sessionId: 'ses_a' } },
  'lca_token-b': { active: true, identity: { accountId: ACCOUNT_B, authMode: 'apple', sessionId: 'ses_b' } }
};

const fakeV10: V10ContentClient = {
  async lookup() {
    return null;
  },
  async create() {
    throw new Error('create should not run');
  },
  async get() {
    throw new Error('get should not run');
  },
  async downloadSegments() {
    throw new Error('download should not run');
  }
};

function harness() {
  const root = mkdtempSync(join(tmpdir(), 'assistant-isolation-'));
  for (const dir of ['workspaces', 'global-memory', 'shared-versions']) mkdirSync(join(root, dir));
  const config = loadConfig({
    ASSISTANT_IDENTITY_MODE: 'account',
    ACCOUNT_SERVICE_URL: 'http://account.internal:3240',
    ASSISTANT_ACCOUNT_TOKEN: 'assistant-introspection-token-0123456789',
    ACCOUNT_CONTEXT_SIGNING_KEY: SIGNING_KEY,
    ASSISTANT_INTERNAL_CALLERS: `account-service:${ACCOUNT_CALLER}`,
    V10_SERVICE_TOKEN: 'test-v10-token-0123456789',
    V10_BASE_URL: 'https://content.example.test',
    NODE_ENV: 'test',
    ASSISTANT_DATABASE_PATH: join(root, 'a.db'),
    ASSISTANT_TEMP_ROOT: join(root, 'tmp'),
    ASSISTANT_WORKSPACE_ROOT: join(root, 'workspaces'),
    ASSISTANT_GLOBAL_MEMORY_ROOT: join(root, 'global-memory'),
    ASSISTANT_SHARED_VERSION_ROOT: join(root, 'shared-versions')
  });
  const identity = new IdentityResolver({
    mode: config.identity.mode,
    selfhostToken: null,
    accountServiceUrl: config.identity.accountServiceUrl,
    introspectionToken: config.identity.introspectionToken,
    internalCallers: config.identity.internalCallers,
    contextSigningKey: config.identity.contextSigningKey,
    fetchImpl: (async (_url: string | URL | Request, init?: RequestInit) => {
      const { token } = JSON.parse(String(init?.body)) as { token: string };
      return new Response(JSON.stringify(INTROSPECTION[token] ?? { active: false, inactiveReason: 'unknown' }), { status: 200 });
    }) as typeof fetch
  });
  const db = openDatabase(config.databasePath, MIGRATIONS);
  const v2 = createV2Stack({ db, config, agent: new FakeAgentRuntime(), v10: fakeV10 });
  const logger = new RedactingLogger(() => undefined);
  const app = createApp({
    config,
    logger,
    v2: v2.application,
    identity,
    internal: { config, identity, logger, v2: { store: v2.store, orchestrator: v2.orchestrator } },
    readiness: {
      config: async () => ({ ok: true }),
      database: async () => ({ ok: true }),
      tempDir: async () => ({ ok: true }),
      piConfig: async () => ({ ok: true }),
      ytdlp: async () => ({ ok: true })
    }
  });
  return { root, config, db, v2, app };
}

async function withServer<T>(h: ReturnType<typeof harness>, fn: (base: string) => Promise<T>): Promise<T> {
  await new Promise<void>((resolve) => h.app.server.listen(0, '127.0.0.1', () => resolve()));
  const port = (h.app.server.address() as { port: number }).port;
  try {
    return await fn(`http://127.0.0.1:${port}`);
  } finally {
    await h.app.close();
    h.db.close();
  }
}

async function call(
  base: string,
  method: string,
  path: string,
  options: { token?: string; body?: unknown; headers?: Record<string, string> } = {}
): Promise<{ status: number; body: any }> {
  const headers: Record<string, string> = { ...options.headers };
  if (options.token) headers.authorization = `Bearer ${options.token}`;
  if (options.body !== undefined) headers['content-type'] = 'application/json';
  const response = await fetch(`${base}${path}`, {
    method,
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body)
  });
  const text = await response.text();
  let body: unknown = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  return { status: response.status, body };
}

test('researches, turns, events, artifacts and memory never cross accounts', async () => {
  const h = harness();
  await withServer(h, async (base) => {
    const createdA = await call(base, 'POST', '/v2/assistant/researches', {
      token: 'lca_token-a',
      body: { title: 'A research' },
      headers: { 'idempotency-key': 'shared-key-0001' }
    });
    assert.equal(createdA.status, 201);
    const createdB = await call(base, 'POST', '/v2/assistant/researches', {
      token: 'lca_token-b',
      body: { title: 'B research' },
      headers: { 'idempotency-key': 'shared-key-0001' }
    });
    assert.equal(createdB.status, 201, 'the same idempotency key in another account creates its own research');
    const researchA = createdA.body.researchId as string;
    const researchB = createdB.body.researchId as string;
    assert.ok(researchA && researchB && researchA !== researchB);
    assert.equal(h.v2.store.getResearch(researchA)?.ownerScope, ACCOUNT_A);

    const listB = await call(base, 'GET', '/v2/assistant/researches', { token: 'lca_token-b' });
    assert.deepEqual(listB.body.researches.map((r: { researchId: string }) => r.researchId), [researchB]);

    const turn = await call(base, 'POST', `/v2/assistant/researches/${researchA}/turns`, {
      token: 'lca_token-a',
      body: { mode: 'research', message: 'hello' },
      headers: { 'idempotency-key': 'turn-key-0001' }
    });
    assert.equal(turn.status, 202);
    const turnId = turn.body.turnId as string;
    assert.match(turnId, /^vt_/);

    const foreign: Array<[string, string, unknown?]> = [
      ['GET', `/v2/assistant/researches/${researchA}`],
      ['DELETE', `/v2/assistant/researches/${researchA}`],
      ['POST', `/v2/assistant/researches/${researchA}/turns`, { mode: 'research', message: 'steal' }],
      ['GET', `/v2/assistant/researches/${researchA}/artifacts`],
      ['GET', `/v2/assistant/researches/${researchA}/memory`],
      ['GET', `/v2/assistant/researches/${researchA}/transcriptions`],
      ['GET', `/v2/assistant/turns/${turnId}/events`],
      ['POST', `/v2/assistant/turns/${turnId}/cancel`]
    ];
    for (const [method, path, body] of foreign) {
      const res = await call(base, method, path, { token: 'lca_token-b', body, headers: { 'idempotency-key': `foreign-${method}-${path.length}` } });
      assert.equal(res.status, 404, `${method} ${path}`);
      assert.match(res.body.error.code, /_NOT_FOUND$/);
    }
    assert.equal(h.v2.store.getResearch(researchA)?.status === 'deleted', false, 'foreign delete had no effect');
    assert.equal((await call(base, 'GET', `/v2/assistant/researches/${researchA}`, { token: 'lca_token-a' })).status, 200);
  });
});

test('removed V1 routes return 404 and public requests cannot carry an account context', async () => {
  const h = harness();
  await withServer(h, async (base) => {
    const v1 = await call(base, 'GET', '/v1/assistant/sessions', { token: 'lca_token-a' });
    assert.equal(v1.status, 404);
    assert.equal(v1.body.error.code, 'NOT_FOUND');

    const smuggled = await call(base, 'GET', '/v2/assistant/researches', {
      token: 'lca_token-b',
      headers: {
        [ACCOUNT_CONTEXT_HEADER]: signAccountContext({ accountId: ACCOUNT_A, authMode: 'apple', sessionId: null, issuer: 'x' }, SIGNING_KEY)
      }
    });
    assert.equal(smuggled.status, 400);
    assert.equal((await call(base, 'GET', '/v2/assistant/researches')).body.error.code, 'AUTH_REQUIRED');
    assert.equal((await call(base, 'GET', '/v2/assistant/researches', { token: ACCOUNT_CALLER })).status, 401);
  });
});

test('account purge removes one account’s researches, workspaces and global memory only', async () => {
  const h = harness();
  await withServer(h, async (base) => {
    const researchA = (await call(base, 'POST', '/v2/assistant/researches', { token: 'lca_token-a', body: {}, headers: { 'idempotency-key': 'purge-a' } })).body.researchId;
    const researchB = (await call(base, 'POST', '/v2/assistant/researches', { token: 'lca_token-b', body: {}, headers: { 'idempotency-key': 'purge-b' } })).body.researchId;
    const memory = h.v2.orchestrator.globalMemory;
    memory.writeConfirmed({ content: 'A prefers concise answers', sourceResearchId: researchA });
    memory.writeConfirmed({ content: 'B prefers long answers', sourceResearchId: researchB });
    assert.deepEqual(memory.listConfirmed(ACCOUNT_A).map((entry) => entry.content), ['A prefers concise answers']);
    assert.deepEqual(memory.listConfirmed(ACCOUNT_B).map((entry) => entry.content), ['B prefers long answers']);
    const dirA = memory.rootFor(ACCOUNT_A);
    assert.ok(dirA.endsWith(join('accounts', ACCOUNT_A)) && existsSync(join(dirA, 'preferences.json')));
    const workspaceA = join(h.config.workspaceRoot, researchA);
    assert.ok(existsSync(workspaceA));

    const path = `/internal/v1/accounts/${ACCOUNT_A}/purge`;
    assert.equal((await call(base, 'POST', path, { token: 'lca_token-a' })).status, 401);
    assert.equal((await call(base, 'POST', '/internal/v1/accounts/selfhost/purge', { token: ACCOUNT_CALLER })).status, 400);
    const done = await call(base, 'POST', path, { token: ACCOUNT_CALLER });
    assert.equal(done.status, 200);
    assert.deepEqual(done.body, { status: 'done', deletedResearches: 1 });

    assert.equal(h.v2.store.getResearch(researchA, true), null);
    assert.equal(existsSync(workspaceA), false);
    assert.equal(existsSync(dirA), false);
    assert.deepEqual(memory.listConfirmed(ACCOUNT_A), []);
    assert.equal(memory.listConfirmed(ACCOUNT_B).length, 1);
    assert.ok(h.v2.store.getResearch(researchB));
    assert.deepEqual((await call(base, 'POST', path, { token: ACCOUNT_CALLER })).body, { status: 'done', deletedResearches: 0 });
  });
});

test('migration 0004 assigns existing memory to its research owner and orphans to selfhost', () => {
  const root = mkdtempSync(join(tmpdir(), 'assistant-0004-'));
  const legacyMigrations = join(root, 'legacy-migrations');
  mkdirSync(legacyMigrations);
  for (const file of readdirSync(MIGRATIONS).filter((name) => /^000[1-3]_/.test(name))) {
    copyFileSync(join(MIGRATIONS, file), join(legacyMigrations, file));
  }
  const dbPath = join(root, 'legacy.db');
  const legacy = openDatabase(dbPath, legacyMigrations);
  const researchId = '01J00000000000000000000001';
  legacy
    .prepare(
      `INSERT INTO v2_researches (research_id, owner_scope, title, status, workspace_status, output_language, storefront,
         target_language, translation_quality, created_at, updated_at) VALUES (?, 'selfhost', 't', 'ready', 'ok', 'zh-Hans', 'US', 'zh-Hans', 'quality', 'x', 'x')`
    )
    .run(researchId);
  const insertMemory = legacy.prepare(
    `INSERT INTO v2_memory_entries (memory_entry_id, research_id, source_research_id, scope, type, content, status, created_at)
     VALUES (?, NULL, ?, 'global', 'preference', ?, 'confirmed', 'x')`
  );
  insertMemory.run('me_from_research', researchId, 'from research');
  insertMemory.run('me_orphan', 'gone-research', 'orphan');
  legacy.close();

  const upgraded = openDatabase(dbPath, MIGRATIONS);
  const rows = upgraded.prepare('SELECT memory_entry_id, owner_scope FROM v2_memory_entries ORDER BY memory_entry_id').all() as Array<{
    memory_entry_id: string;
    owner_scope: string;
  }>;
  assert.deepEqual(
    rows.map((row) => [row.memory_entry_id, row.owner_scope]),
    [
      ['me_from_research', 'selfhost'],
      ['me_orphan', 'selfhost']
    ]
  );
  const versions = (upgraded.prepare('SELECT version FROM schema_migrations ORDER BY version').all() as Array<{ version: number }>).map((row) => Number(row.version));
  assert.deepEqual(versions, [1, 2, 3, 4, 5, 6]);
  upgraded.close();
});

test('content-pipeline calls carry the research owner’s signed context', async () => {
  const seen: Array<string | null> = [];
  const fetchImpl = (async (_url: string | URL | Request, init?: RequestInit) => {
    seen.push(new Headers(init?.headers).get(ACCOUNT_CONTEXT_HEADER));
    return new Response(JSON.stringify({ job: null }), { status: 200 });
  }) as typeof fetch;
  const signed = new HttpV10ContentClient('https://content.internal', 'assistant-caller-token-0123456789abc', fetchImpl, SIGNING_KEY);
  const lookup = { contentType: 'video', contentKey: 'video:youtube:abc', targetLanguage: 'zh-Hans', translationQuality: 'fast' };
  await signed.lookup(lookup, { ownerScope: ACCOUNT_A, operationKey: 'assistant-transcript:tj_1' });
  const verified = verifyAccountContext(seen[0]!, SIGNING_KEY);
  assert.ok(verified.ok);
  assert.equal(verified.payload.accountId, ACCOUNT_A);
  assert.equal(verified.payload.operationKey, 'assistant-transcript:tj_1');
  assert.equal(verified.payload.issuer, 'research-assistant');
  await assert.rejects(signed.lookup(lookup), /missing its account context/);

  const selfhost = new HttpV10ContentClient('https://content.internal', 'content-selfhost-token-0123', fetchImpl);
  await selfhost.lookup(lookup, { ownerScope: 'selfhost' });
  assert.equal(seen[1], null, 'selfhost deployments without a signing key send no context');

  const vectors = JSON.parse(readFileSync(new URL('../../../../docs/contracts/account-context-v1.vectors.json', import.meta.url), 'utf8')) as {
    key: string;
    nowMs: number;
    valid: Array<{ payload: Parameters<typeof signAccountContext>[0]; token: string }>;
    invalid: Array<{ token: string; reason: string }>;
  };
  for (const vector of vectors.valid) assert.equal(signAccountContext(vector.payload, vectors.key, vectors.nowMs), vector.token);
  for (const vector of vectors.invalid) {
    const result = verifyAccountContext(vector.token, vectors.key, vectors.nowMs);
    assert.equal(!result.ok && result.reason, vector.reason);
  }
});
