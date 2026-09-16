import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { createApp, listen, type AppHandle } from '../src/app.js';
import {
  ACCOUNT_CONTEXT_HEADER,
  signAccountContext,
  verifyAccountContext,
  type AccountContextPayload
} from '../src/auth/account-context.js';
import { IdentityResolver } from '../src/auth/identity.js';
import { loadConfig, type ServiceConfig } from '../src/config.js';
import { podcastContentKey, videoContentKey } from '../src/domain/content-key.js';
import { ContentMediaStore } from '../src/domain/content-media-store.js';
import { JobStore } from '../src/jobs/job-store.js';
import { openDatabase } from '../src/jobs/migrations.js';
import { RedactingLogger } from '../src/observability/logger.js';
import { HttpMediaServiceClient, SingleFlightMediaGate } from '../src/providers/media/client.js';
import { KeyLayout } from '../src/storage/keys.js';
import { InMemoryObjectStore } from '../src/storage/object-store.js';

const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url).pathname;
const SIGNING_KEY = 'content-test-context-signing-key-0123456789';
const ASSISTANT_CALLER = 'assistant-caller-token-0123456789abcdef';
const ACCOUNT_CALLER = 'account-caller-token-0123456789abcdef00';
const ACCOUNT_A = `acc_${'A'.repeat(26)}`;
const ACCOUNT_B = `acc_${'B'.repeat(26)}`;

const INTROSPECTION: Record<string, unknown> = {
  'lca_token-a': { active: true, identity: { accountId: ACCOUNT_A, authMode: 'apple', sessionId: 'ses_a' } },
  'lca_token-b': { active: true, identity: { accountId: ACCOUNT_B, authMode: 'apple', sessionId: 'ses_b' } },
  'lca_expired': { active: false, inactiveReason: 'expired' },
  'lca_deleting': { active: false, inactiveReason: 'account_deleting' }
};

const PODCAST_BODY = {
  contentType: 'podcast_episode',
  contentKey: podcastContentKey('https://example.com/feed.xml', 'ep-001'),
  source: {
    platform: 'rss',
    sourceId: 'ep-001',
    url: 'https://media.example.com/ep-001.mp3',
    feedUrl: 'https://example.com/feed.xml'
  },
  sourceLanguage: 'en',
  targetLanguage: 'zh-Hans',
  translationQuality: 'quality',
  clientArtifactSchemaVersion: 1
};

const VIDEO_ID = 'dQw4w9WgXcQ';
const VIDEO_BODY = {
  contentType: 'video',
  contentKey: videoContentKey('youtube', VIDEO_ID),
  source: { platform: 'youtube', sourceId: VIDEO_ID, url: `https://www.youtube.com/watch?v=${VIDEO_ID}` },
  sourceLanguage: 'en',
  targetLanguage: 'zh-Hans',
  translationQuality: 'fast',
  clientArtifactSchemaVersion: 1
};

interface Fixture {
  baseUrl: string;
  config: ServiceConfig;
  store: JobStore;
  mediaStore: ContentMediaStore;
  objects: InMemoryObjectStore;
  keys: KeyLayout;
  activity: { currentOwnerScope: string | null; aborted: number; abortCurrent(): void };
  introspection: { mode: 'ok' | 'network' | 'server_error' };
  close(): Promise<void>;
}

async function setup(): Promise<Fixture> {
  const tempRoot = await mkdtemp(join(tmpdir(), 'content-isolation-'));
  const config: ServiceConfig = {
    ...loadConfig({
      CONTENT_IDENTITY_MODE: 'account',
      ACCOUNT_SERVICE_URL: 'http://account.internal:3240',
      CONTENT_ACCOUNT_TOKEN: 'content-introspection-token-0123456789ab',
      ACCOUNT_CONTEXT_SIGNING_KEY: SIGNING_KEY,
      CONTENT_INTERNAL_CALLERS: `research-assistant:${ASSISTANT_CALLER},account-service:${ACCOUNT_CALLER}`,
      MEDIA_API_TOKEN: 'test-media-token-0123456789',
      DASHSCOPE_API_KEY: 'test-dashscope-key-0123456789',
      TRANSLATION_API_KEY: 'test-translation-key-0123456789',
      TRANSLATION_MODEL: 'test-model',
      R2_ACCOUNT_ID: 'acct',
      R2_ACCESS_KEY_ID: 'r2-access',
      R2_SECRET_ACCESS_KEY: 'r2-secret-0123456789',
      R2_BUCKET: 'linguacast',
      CONTENT_TEMP_ROOT: tempRoot
    }),
    port: 0
  };
  const introspection: Fixture['introspection'] = { mode: 'ok' };
  const fakeFetch = (async (_url: string | URL | Request, init?: RequestInit) => {
    if (introspection.mode === 'network') throw new Error('ECONNREFUSED');
    if (introspection.mode === 'server_error') return new Response('{}', { status: 500 });
    const auth = new Headers(init?.headers).get('authorization');
    assert.equal(auth, `Bearer ${config.identity.introspectionToken}`);
    const { token } = JSON.parse(String(init?.body)) as { token: string };
    return new Response(JSON.stringify(INTROSPECTION[token] ?? { active: false, inactiveReason: 'unknown' }), { status: 200 });
  }) as typeof fetch;
  const identity = new IdentityResolver({
    mode: config.identity.mode,
    selfhostToken: null,
    accountServiceUrl: config.identity.accountServiceUrl,
    introspectionToken: config.identity.introspectionToken,
    internalCallers: config.identity.internalCallers,
    contextSigningKey: config.identity.contextSigningKey,
    fetchImpl: fakeFetch
  });
  const logger = new RedactingLogger(() => {});
  const db = openDatabase(join(tempRoot, 'content.db'), MIGRATIONS_DIR);
  const store = new JobStore(db);
  const mediaStore = new ContentMediaStore(db);
  const objects = new InMemoryObjectStore();
  const keys = new KeyLayout(config.r2);
  const activity = {
    currentOwnerScope: null as string | null,
    aborted: 0,
    abortCurrent() {
      this.aborted += 1;
    }
  };
  const app: AppHandle = createApp({
    config,
    logger,
    internalRoutes: { config, store, objects, keys, logger, identity, worker: activity },
    jobRoutes: { config, store, identity },
    artifactRoutes: { config, store, objects, keys, identity },
    contentMediaRoutes: { config, store, mediaStore, objects, keys, identity }
  });
  await listen(app, config, logger);
  return {
    baseUrl: `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`,
    config,
    store,
    mediaStore,
    objects,
    keys,
    activity,
    introspection,
    close: async () => {
      await app.close();
      store.close();
      await rm(tempRoot, { recursive: true, force: true });
    }
  };
}

function context(accountId: string, overrides: Partial<AccountContextPayload> = {}, key = SIGNING_KEY): string {
  return signAccountContext(
    { accountId, authMode: accountId === 'selfhost' ? 'selfhost' : 'apple', sessionId: null, issuer: 'research-assistant', ...overrides },
    key
  );
}

async function request(
  fx: Fixture,
  method: string,
  path: string,
  options: { token?: string; body?: unknown; headers?: Record<string, string> } = {}
): Promise<{ status: number; body: any; text: string }> {
  const headers: Record<string, string> = { ...options.headers };
  if (options.token) headers.authorization = `Bearer ${options.token}`;
  if (options.body !== undefined) headers['content-type'] = 'application/json';
  const response = await fetch(`${fx.baseUrl}${path}`, {
    method,
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body)
  });
  const text = await response.text();
  let body: unknown = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = null;
  }
  return { status: response.status, body, text };
}

test('accounts cannot read, cancel, retry or look up each other’s jobs', async () => {
  const fx = await setup();
  try {
    const createdA = await request(fx, 'POST', '/v1/content-jobs', {
      token: 'lca_token-a',
      body: PODCAST_BODY,
      headers: { 'idempotency-key': 'same-key-0001' }
    });
    assert.equal(createdA.status, 202);
    const createdB = await request(fx, 'POST', '/v1/content-jobs', {
      token: 'lca_token-b',
      body: PODCAST_BODY,
      headers: { 'idempotency-key': 'same-key-0001' }
    });
    assert.equal(createdB.status, 202, 'same idempotency key and content in another account is a new job');
    const jobA = createdA.body.jobId as string;
    const jobB = createdB.body.jobId as string;
    assert.notEqual(jobA, jobB);
    assert.equal(fx.store.getJob(jobA)?.ownerScope, ACCOUNT_A);
    assert.equal(fx.store.getJob(jobB)?.ownerScope, ACCOUNT_B);

    for (const [method, path] of [
      ['GET', `/v1/content-jobs/${jobA}`],
      ['DELETE', `/v1/content-jobs/${jobA}`],
      ['POST', `/v1/content-jobs/${jobA}/retry`]
    ] as const) {
      const res = await request(fx, method, path, { token: 'lca_token-b' });
      assert.equal(res.status, 404, `${method} ${path}`);
      assert.equal(res.body.error.code, 'JOB_NOT_FOUND');
    }
    assert.equal(fx.store.getJob(jobA)?.status, 'queued', 'foreign cancel had no effect');

    const lookup = await request(
      fx,
      'GET',
      `/v1/content-jobs:lookup?contentType=podcast_episode&contentKey=${encodeURIComponent(PODCAST_BODY.contentKey)}&targetLanguage=zh-Hans&translationQuality=quality`,
      { token: 'lca_token-b' }
    );
    assert.equal(lookup.body.job.jobId, jobB, 'lookup only sees the caller’s own job');
    assert.equal((await request(fx, 'GET', `/v1/content-jobs/${jobA}`, { token: 'lca_token-a' })).status, 200);
  } finally {
    await fx.close();
  }
});

test('artifacts, audio playback and video media URLs are owner scoped', async () => {
  const fx = await setup();
  try {
    const created = await request(fx, 'POST', '/v1/content-jobs', { token: 'lca_token-a', body: PODCAST_BODY });
    const jobId = created.body.jobId as string;
    const claimed = fx.store.claimNextJob('worker-test', 30_000);
    assert.equal(claimed?.jobId, jobId);
    const body = Buffer.from('{"segments":[]}');
    const artifactKey = fx.keys.forAccount(ACCOUNT_A).jobArtifact(jobId, 'segments.json');
    assert.ok(artifactKey.startsWith(fx.keys.accountPrefix(ACCOUNT_A)));
    await fx.objects.put(artifactKey, body, 'application/json');
    fx.store.completeJob(jobId, {
      files: [{ name: 'segments.json', role: 'segments', required: true, status: 'ready', mimeType: 'application/json', bytes: body.length, sha256: 'ab'.repeat(32) }]
    });

    const own = await request(fx, 'GET', `/v1/content-artifacts/${jobId}/segments.json`, { token: 'lca_token-a' });
    assert.equal(own.status, 200);
    assert.equal(own.text, body.toString());
    const foreign = await request(fx, 'GET', `/v1/content-artifacts/${jobId}/segments.json`, { token: 'lca_token-b' });
    assert.equal(foreign.status, 404);
    assert.equal(foreign.body.error.code, 'JOB_NOT_FOUND');
    const foreignAudio = await request(fx, 'POST', `/v1/content-jobs/${jobId}/audio-playback-url`, { token: 'lca_token-b' });
    assert.equal(foreignAudio.status, 404);

    await request(fx, 'POST', '/v1/content-jobs', { token: 'lca_token-a', body: VIDEO_BODY });
    const fingerprint = 'cd'.repeat(32);
    const promoting = fx.mediaStore.createPromoting({
      ownerScope: ACCOUNT_A,
      contentType: 'video',
      contentKey: VIDEO_BODY.contentKey,
      renditionKey: 'mp4-720-avc1-aac',
      fingerprint
    });
    const videoKey = fx.keys.forAccount(ACCOUNT_A).videoMedia(fingerprint);
    await fx.objects.put(videoKey, Buffer.alloc(64), 'video/mp4');
    fx.mediaStore.markReady({
      mediaId: promoting.mediaId,
      objectKey: videoKey,
      mimeType: 'video/mp4',
      bytes: 64,
      sha256: fingerprint,
      durationSeconds: 10,
      height: 720,
      videoCodec: 'avc1',
      audioCodec: 'aac',
      retainUntil: Date.now() + 86_400_000
    });
    const playbackBody = { contentType: 'video', contentKey: VIDEO_BODY.contentKey };
    const ownVideo = await request(fx, 'POST', '/v1/content-media/video-playback-url', { token: 'lca_token-a', body: playbackBody });
    assert.equal(ownVideo.status, 200);
    const foreignVideo = await request(fx, 'POST', '/v1/content-media/video-playback-url', { token: 'lca_token-b', body: playbackBody });
    assert.equal(foreignVideo.status, 404);
    assert.equal(foreignVideo.body.error.code, 'MEDIA_NOT_FOUND');
  } finally {
    await fx.close();
  }
});

test('public requests cannot carry an account context; internal callers need a valid one', async () => {
  const fx = await setup();
  try {
    const jobId = (await request(fx, 'POST', '/v1/content-jobs', { token: 'lca_token-a', body: PODCAST_BODY })).body.jobId;
    const path = `/v1/content-jobs/${jobId}`;

    const smuggled = await request(fx, 'GET', path, { token: 'lca_token-b', headers: { [ACCOUNT_CONTEXT_HEADER]: context(ACCOUNT_A) } });
    assert.equal(smuggled.status, 400);
    assert.equal(smuggled.body.error.code, 'INVALID_REQUEST');

    assert.equal((await request(fx, 'GET', path, { token: ASSISTANT_CALLER })).status, 401, 'internal token alone is not an identity');
    const asA = await request(fx, 'GET', path, { token: ASSISTANT_CALLER, headers: { [ACCOUNT_CONTEXT_HEADER]: context(ACCOUNT_A) } });
    assert.equal(asA.status, 200);
    const asB = await request(fx, 'GET', path, { token: ASSISTANT_CALLER, headers: { [ACCOUNT_CONTEXT_HEADER]: context(ACCOUNT_B) } });
    assert.equal(asB.status, 404);

    const [version, payload, signature] = context(ACCOUNT_B).split('.');
    const forged = `${version}.${Buffer.from(JSON.stringify({ ...JSON.parse(Buffer.from(payload!, 'base64url').toString()), accountId: ACCOUNT_A })).toString('base64url')}.${signature}`;
    for (const header of [forged, context(ACCOUNT_A, {}, `${SIGNING_KEY}-wrong`), context('selfhost'), context(ACCOUNT_A, { exp: Math.floor(Date.now() / 1000) - 120 })]) {
      const res = await request(fx, 'GET', path, { token: ASSISTANT_CALLER, headers: { [ACCOUNT_CONTEXT_HEADER]: header } });
      assert.equal(res.status, 401);
      assert.equal(res.body.error.code, 'AUTH_REQUIRED');
    }
  } finally {
    await fx.close();
  }
});

test('introspection outcomes map to contract errors and fail closed', async () => {
  const fx = await setup();
  try {
    const path = '/v1/content-jobs/cj_unknown';
    const cases: Array<[string | undefined, number, string]> = [
      [undefined, 401, 'AUTH_REQUIRED'],
      ['lca_never-issued', 401, 'AUTH_REQUIRED'],
      ['lca_expired', 401, 'ACCESS_TOKEN_EXPIRED'],
      ['lca_deleting', 403, 'ACCOUNT_DELETING']
    ];
    for (const [token, status, code] of cases) {
      const res = await request(fx, 'GET', path, { token });
      assert.equal(res.status, status, code);
      assert.equal(res.body.error.code, code);
    }
    for (const mode of ['network', 'server_error'] as const) {
      fx.introspection.mode = mode;
      const res = await request(fx, 'GET', path, { token: 'lca_token-a' });
      assert.equal(res.status, 503);
      assert.equal(res.body.error.code, 'ACCOUNT_SERVICE_UNAVAILABLE');
      assert.equal(res.body.error.retryable, true);
    }
  } finally {
    await fx.close();
  }
});

test('account purge is internal-only, waits for executing work and removes only that account', async () => {
  const fx = await setup();
  try {
    const jobA = (await request(fx, 'POST', '/v1/content-jobs', { token: 'lca_token-a', body: PODCAST_BODY })).body.jobId;
    const jobB = (await request(fx, 'POST', '/v1/content-jobs', { token: 'lca_token-b', body: PODCAST_BODY })).body.jobId;
    const keyA = fx.keys.forAccount(ACCOUNT_A).podcastAudio('aa'.repeat(32));
    const keyB = fx.keys.forAccount(ACCOUNT_B).podcastAudio('bb'.repeat(32));
    await fx.objects.put(keyA, Buffer.from('a'), 'audio/mpeg');
    await fx.objects.put(keyB, Buffer.from('b'), 'audio/mpeg');
    const purgePath = `/internal/v1/accounts/${ACCOUNT_A}/purge`;

    assert.equal((await request(fx, 'POST', purgePath, { token: 'lca_token-a' })).status, 401);
    assert.equal((await request(fx, 'POST', purgePath, { token: ASSISTANT_CALLER })).status, 401);
    assert.equal((await request(fx, 'POST', '/internal/v1/accounts/selfhost/purge', { token: ACCOUNT_CALLER })).status, 400);

    fx.activity.currentOwnerScope = ACCOUNT_A;
    const waiting = await request(fx, 'POST', purgePath, { token: ACCOUNT_CALLER });
    assert.equal(waiting.status, 202);
    assert.equal(waiting.body.status, 'in_progress');
    assert.equal(fx.activity.aborted, 1);
    assert.equal(fx.store.getJob(jobA)?.status, 'cancelled');

    fx.activity.currentOwnerScope = null;
    const done = await request(fx, 'POST', purgePath, { token: ACCOUNT_CALLER });
    assert.equal(done.status, 200);
    assert.equal(done.body.status, 'done');
    assert.equal(fx.store.getJob(jobA), null);
    assert.equal(await fx.objects.head(keyA), null);
    assert.equal(fx.store.getJob(jobB)?.status, 'queued', 'other account untouched');
    assert.ok(await fx.objects.head(keyB));

    const again = await request(fx, 'POST', purgePath, { token: ACCOUNT_CALLER });
    assert.deepEqual([again.status, again.body.status, again.body.deletedJobs], [200, 'done', 0]);
  } finally {
    await fx.close();
  }
});

test('object keys and media-service calls are namespaced per account', async () => {
  const keys = new KeyLayout({ prefix: 'content-pipeline', environment: 'prod' });
  assert.ok(keys.forAccount(ACCOUNT_A).podcastAudio('ff'.repeat(32)).startsWith(`content-pipeline/prod/accounts/${ACCOUNT_A}/podcast-audio/`));
  assert.equal(keys.forAccount('selfhost').podcastAudio('x'), 'content-pipeline/prod/podcast-audio/x.mp3');
  assert.equal(keys.forAccount('legacy-owner').podcastAudio('x'), 'content-pipeline/prod/podcast-audio/x.mp3');
  assert.notEqual(keys.forAccount(ACCOUNT_A).sourceTranscript('t'), keys.forAccount(ACCOUNT_B).sourceTranscript('t'));

  const seen: Array<string | null> = [];
  const fetchImpl = (async (_url: string | URL | Request, init?: RequestInit) => {
    seen.push(new Headers(init?.headers).get(ACCOUNT_CONTEXT_HEADER));
    return new Response(JSON.stringify({ jobId: 'job-1', status: 'queued' }), { status: 202 });
  }) as typeof fetch;
  const client = new HttpMediaServiceClient({ baseUrl: 'http://media.internal:3210', token: 'media-caller-token-0123456789', contextSigningKey: SIGNING_KEY, fetchImpl });
  await client.forAccount(ACCOUNT_A).prepare({ videoId: VIDEO_ID });
  await client.prepare({ videoId: VIDEO_ID });
  const verified = verifyAccountContext(seen[0]!, SIGNING_KEY);
  assert.ok(verified.ok && verified.payload.accountId === ACCOUNT_A && verified.payload.issuer === 'content-pipeline');
  assert.equal(seen[1], null, 'no owner, no context');

  const gate = new SingleFlightMediaGate(client);
  await gate.forAccount(ACCOUNT_A).prepare({ videoId: VIDEO_ID });
  await assert.rejects(gate.forAccount(ACCOUNT_B).prepare({ videoId: VIDEO_ID }), /already in flight/);
});

test('signed account context matches the shared contract vectors', () => {
  const vectors = JSON.parse(
    readFileSync(new URL('../../../docs/contracts/account-context-v1.vectors.json', import.meta.url), 'utf8')
  ) as {
    key: string;
    nowMs: number;
    valid: Array<{ name: string; payload: AccountContextPayload; token: string }>;
    invalid: Array<{ name: string; token: string; reason: string }>;
  };
  for (const vector of vectors.valid) {
    assert.equal(signAccountContext(vector.payload, vectors.key, vectors.nowMs), vector.token, vector.name);
    const result = verifyAccountContext(vector.token, vectors.key, vectors.nowMs);
    assert.ok(result.ok, vector.name);
    assert.deepEqual(result.payload, vector.payload);
  }
  for (const vector of vectors.invalid) {
    const result = verifyAccountContext(vector.token, vectors.key, vectors.nowMs);
    assert.equal(result.ok, false, vector.name);
    assert.equal(!result.ok && result.reason, vector.reason, vector.name);
  }
});
