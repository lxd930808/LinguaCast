import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { createApp, listen, type AppHandle } from '../src/app.js';
import { ACCOUNT_CONTEXT_HEADER, signAccountContext } from '../src/auth/account-context.js';
import { IdentityResolver } from '../src/auth/identity.js';
import { loadConfig, type ServiceConfig } from '../src/config.js';
import { podcastContentKey } from '../src/domain/content-key.js';
import { JobStore } from '../src/jobs/job-store.js';
import { openDatabase } from '../src/jobs/migrations.js';
import { RedactingLogger } from '../src/observability/logger.js';
import { DefaultDurationProber, estimateDuration, type DurationProber } from '../src/quota/duration-probe.js';
import { QuotaError, type QuotaClient, type ReserveRequest, type ReservationView } from '../src/quota/quota-client.js';
import { QuotaSettlementDispatcher } from '../src/quota/settlement-dispatcher.js';

const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url).pathname;
const SIGNING_KEY = 'content-quota-context-signing-key-012345';
const ASSISTANT_CALLER = 'assistant-caller-token-0123456789abcdef';
const ACCOUNT_A = `acc_${'A'.repeat(26)}`;
const ACCOUNT_B = `acc_${'B'.repeat(26)}`;
const TOKENS: Record<string, string> = { 'lca_token-a': ACCOUNT_A, 'lca_token-b': ACCOUNT_B };

function podcastBody(episode: string, quality: 'fast' | 'quality' = 'quality') {
  return {
    contentType: 'podcast_episode',
    contentKey: podcastContentKey('https://example.com/feed.xml', episode),
    source: { platform: 'rss', sourceId: episode, url: `https://media.example.com/${episode}.mp3`, feedUrl: 'https://example.com/feed.xml' },
    sourceLanguage: 'en',
    targetLanguage: 'zh-Hans',
    translationQuality: quality,
    clientArtifactSchemaVersion: 1
  };
}

/** In-memory account-service quota semantics (contract §3.1–§3.2). */
class FakeQuota implements QuotaClient {
  limit = 1800;
  down = false;
  readonly reserveCalls: ReserveRequest[] = [];
  readonly settlements: Array<[string, string, string]> = [];
  private readonly byKey = new Map<string, ReservationView & { accountId: string }>();
  private readonly byId = new Map<string, ReservationView & { accountId: string }>();
  private seq = 0;

  async reserve(request: ReserveRequest): Promise<ReservationView> {
    if (this.down) throw new QuotaError(503, 'ACCOUNT_SERVICE_UNAVAILABLE', 'down', true);
    this.reserveCalls.push(request);
    const key = `${request.accountId}|${request.operationKey}`;
    const existing = this.byKey.get(key);
    if (existing) {
      if (existing.amount !== request.amount) throw new QuotaError(409, 'IDEMPOTENCY_CONFLICT', 'conflict');
      return { ...existing };
    }
    if (request.amount > this.limit) throw new QuotaError(422, 'QUOTA_REQUEST_TOO_LARGE', 'too large', false, { limit: this.limit });
    const used = [...this.byId.values()]
      .filter((r) => r.accountId === request.accountId && r.status !== 'released')
      .reduce((sum, r) => sum + r.amount, 0);
    if (used + request.amount > this.limit) {
      throw new QuotaError(429, 'QUOTA_EXCEEDED', 'exhausted', false, { kind: 'media', remaining: this.limit - used, resetAt: '2026-09-14T16:00:00.000Z' }, 3600);
    }
    const row = {
      reservationId: `qr_${String(++this.seq).padStart(26, '0')}`,
      status: 'reserved' as const,
      amount: request.amount,
      operationKey: request.operationKey,
      accountId: request.accountId
    };
    this.byKey.set(key, row);
    this.byId.set(row.reservationId, row);
    return { ...row };
  }

  async settle(reservationId: string, outcome: 'consumed' | 'released', reason: string): Promise<'settled' | 'conflict'> {
    if (this.down) throw new QuotaError(503, 'ACCOUNT_SERVICE_UNAVAILABLE', 'down', true);
    const row = this.byId.get(reservationId);
    if (!row) return 'conflict';
    if (row.status === outcome) return 'settled';
    if (row.status !== 'reserved') return 'conflict';
    row.status = outcome;
    this.settlements.push([reservationId, outcome, reason]);
    return 'settled';
  }

  status(reservationId: string): string | undefined {
    return this.byId.get(reservationId)?.status;
  }
}

class FakeProber implements DurationProber {
  value: number | null = 600.4;
  calls = 0;
  async probe(): Promise<number | null> {
    this.calls += 1;
    return this.value;
  }
}

interface Fixture {
  base: string;
  dbPath: string;
  config: ServiceConfig;
  store: JobStore;
  quota: FakeQuota;
  prober: FakeProber;
  close(): Promise<void>;
}

async function setup(): Promise<Fixture> {
  const tempRoot = await mkdtemp(join(tmpdir(), 'content-quota-'));
  const config: ServiceConfig = {
    ...loadConfig({
      CONTENT_IDENTITY_MODE: 'account',
      ACCOUNT_SERVICE_URL: 'http://account.internal:3240',
      CONTENT_ACCOUNT_TOKEN: 'content-introspection-token-0123456789ab',
      ACCOUNT_CONTEXT_SIGNING_KEY: SIGNING_KEY,
      CONTENT_INTERNAL_CALLERS: `research-assistant:${ASSISTANT_CALLER}`,
      MEDIA_API_TOKEN: 'test-media-token-0123456789',
      DASHSCOPE_API_KEY: 'test-dashscope-key-0123456789',
      TRANSLATION_API_KEY: 'test-translation-key-0123456789',
      TRANSLATION_MODEL: 'test-model',
      R2_ACCOUNT_ID: 'acct',
      R2_ACCESS_KEY_ID: 'r2-access',
      R2_SECRET_ACCESS_KEY: 'r2-secret-0123456789',
      R2_BUCKET: 'linguacast',
      CONTENT_TEMP_ROOT: tempRoot,
      CONTENT_MAX_MEDIA_DURATION_SECONDS: '3600'
    }),
    port: 0
  };
  const identity = new IdentityResolver({
    mode: 'account',
    selfhostToken: null,
    accountServiceUrl: config.identity.accountServiceUrl,
    introspectionToken: config.identity.introspectionToken,
    internalCallers: config.identity.internalCallers,
    contextSigningKey: SIGNING_KEY,
    fetchImpl: (async (_url: string | URL | Request, init?: RequestInit) => {
      const { token } = JSON.parse(String(init?.body)) as { token: string };
      const accountId = TOKENS[token];
      return new Response(
        JSON.stringify(accountId ? { active: true, identity: { accountId, authMode: 'apple', sessionId: 'ses' } } : { active: false }),
        { status: 200 }
      );
    }) as typeof fetch
  });
  const dbPath = join(tempRoot, 'content.db');
  const store = new JobStore(openDatabase(dbPath, MIGRATIONS_DIR));
  const quota = new FakeQuota();
  const prober = new FakeProber();
  const logger = new RedactingLogger(() => {});
  const app: AppHandle = createApp({ config, logger, jobRoutes: { config, store, identity, quota: { client: quota, prober } } });
  await listen(app, config, logger);
  return {
    base: `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`,
    dbPath,
    config,
    store,
    quota,
    prober,
    close: async () => {
      await app.close();
      store.close();
      await rm(tempRoot, { recursive: true, force: true });
    }
  };
}

async function submit(fx: Fixture, body: unknown, token = 'lca_token-a', headers: Record<string, string> = {}) {
  const response = await fetch(`${fx.base}/v1/content-jobs`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', ...headers },
    body: JSON.stringify(body)
  });
  return { status: response.status, body: (await response.json()) as any, headers: response.headers };
}

function intentCount(fx: Fixture): number {
  return fx.store.listIntents(Number.MAX_SAFE_INTEGER).length;
}

test('duration estimation picks header, scaled CBR or unknown', () => {
  assert.equal(estimateDuration({ probedSeconds: 42, bitrate: 64_000, partialBytes: 100, totalBytes: 100, complete: true }), 42);
  // ffprobe estimated 8 s from 64 KiB at 64 kbps: scale to the 1.6 MiB total.
  assert.equal(
    Math.round(estimateDuration({ probedSeconds: 8.192, bitrate: 64_000, partialBytes: 65_536, totalBytes: 1_638_400, complete: false })!),
    205
  );
  assert.equal(estimateDuration({ probedSeconds: 1800, bitrate: 64_000, partialBytes: 65_536, totalBytes: 1_638_400, complete: false }), 1800);
  assert.equal(estimateDuration({ probedSeconds: 8.192, bitrate: 64_000, partialBytes: 65_536, totalBytes: null, complete: false }), null);
  assert.equal(estimateDuration({ probedSeconds: null, bitrate: null, partialBytes: 10, totalBytes: 10, complete: true }), null);
});

test('probe reads the head of real audio over HTTP and refuses unsafe redirects', async (t) => {
  const dir = await mkdtemp(join(tmpdir(), 'probe-audio-'));
  const encode = (name: string, args: string[]) => {
    const out = join(dir, name);
    const result = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=40', ...args, out]);
    return result.status === 0 ? readFileSync(out) : null;
  };
  const files: Record<string, Buffer | null> = {
    'cbr.mp3': encode('cbr.mp3', ['-c:a', 'libmp3lame', '-b:a', '64k', '-write_xing', '0']),
    'vbr.mp3': encode('vbr.mp3', ['-c:a', 'libmp3lame', '-q:a', '6']),
    'fast.m4a': encode('fast.m4a', ['-c:a', 'aac', '-b:a', '64k', '-movflags', '+faststart'])
  };
  if (Object.values(files).some((file) => file === null)) {
    t.skip('ffmpeg encoders unavailable');
    await rm(dir, { recursive: true, force: true });
    return;
  }
  const server: Server = createServer((req, res) => {
    const name = req.url?.slice(1) ?? '';
    if (name === 'redirect-private') {
      res.writeHead(302, { location: 'http://10.0.0.5/secret.mp3' }).end();
      return;
    }
    if (name === 'page.html') {
      res.writeHead(200, { 'content-type': 'text/html', 'content-length': '20' }).end('<html>not audio</html>');
      return;
    }
    const file = files[name];
    if (!file) {
      res.writeHead(404).end();
      return;
    }
    const range = /bytes=(\d+)-(\d+)/.exec(req.headers.range ?? '');
    if (range) {
      const start = Number(range[1]);
      const end = Math.min(Number(range[2]), file.length - 1);
      res.writeHead(206, { 'content-range': `bytes ${start}-${end}/${file.length}`, 'content-length': String(end - start + 1) });
      res.end(file.subarray(start, end + 1));
      return;
    }
    res.writeHead(200, { 'content-length': String(file.length) }).end(file);
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', () => resolve()));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const prober = new DefaultDurationProber({
    tempRoot: dir,
    headBytes: 64 * 1024,
    ssrf: { allowAddress: (address) => address === '127.0.0.1' }
  });
  const probe = (name: string) =>
    prober.probe({ contentType: 'podcast_episode', source: { platform: 'rss', sourceId: name, url: `${base}/${name}` } });
  try {
    for (const name of ['cbr.mp3', 'vbr.mp3', 'fast.m4a']) {
      const seconds = await probe(name);
      assert.ok(seconds !== null && Math.abs(seconds - 40) < 1.5, `${name} → ${seconds}`);
    }
    assert.equal(await probe('redirect-private'), null, 'redirect to a private address is not followed');
    assert.equal(await probe('page.html'), null);
    assert.equal(await probe('missing.mp3'), null);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await rm(dir, { recursive: true, force: true });
  }
});

test('unknown or over-long duration rejects before any reservation', async () => {
  const fx = await setup();
  try {
    fx.prober.value = null;
    const unknown = await submit(fx, podcastBody('ep-unknown'));
    assert.equal(unknown.status, 422);
    assert.equal(unknown.body.error.code, 'MEDIA_DURATION_UNKNOWN');
    fx.prober.value = 3601;
    const long = await submit(fx, podcastBody('ep-long'));
    assert.equal(long.status, 422);
    assert.equal(long.body.error.code, 'MEDIA_TOO_LONG');
    assert.equal(fx.quota.reserveCalls.length, 0);
    assert.equal(intentCount(fx), 0);
  } finally {
    await fx.close();
  }
});

test('quota exhaustion returns 429 with reset details and creates no job', async () => {
  const fx = await setup();
  try {
    fx.prober.value = 1500;
    assert.equal((await submit(fx, podcastBody('ep-1'))).status, 202);
    const over = await submit(fx, podcastBody('ep-2'));
    assert.equal(over.status, 429);
    assert.equal(over.body.error.code, 'QUOTA_EXCEEDED');
    assert.equal(over.body.error.params.resetAt, '2026-09-14T16:00:00.000Z');
    assert.equal(over.body.error.retryAfterSeconds, 3600);
    const lookup = await fetch(
      `${fx.base}/v1/content-jobs:lookup?contentType=podcast_episode&contentKey=${encodeURIComponent(podcastBody('ep-2').contentKey)}&targetLanguage=zh-Hans&translationQuality=quality`,
      { headers: { authorization: 'Bearer lca_token-a' } }
    );
    assert.equal(((await lookup.json()) as { job: unknown }).job, null);
    assert.equal(intentCount(fx), 0);
    fx.quota.down = true;
    const down = await submit(fx, podcastBody('ep-3'));
    assert.equal(down.status, 503);
    assert.equal(down.body.error.code, 'ACCOUNT_SERVICE_UNAVAILABLE');
  } finally {
    await fx.close();
  }
});

test('reserve then queue; duplicates and ready artifacts are reused free of charge', async () => {
  const fx = await setup();
  try {
    const first = await submit(fx, podcastBody('ep-reuse'));
    assert.equal(first.status, 202);
    const job = fx.store.getJob(first.body.jobId)!;
    assert.equal(job.quotaSeconds, 601, 'ceil of the probed duration');
    assert.equal(job.operationKey, `content-job:${job.jobId}`);
    assert.equal(fx.quota.status(job.reservationId!), 'reserved', 'queued work already holds its reservation');
    assert.equal(intentCount(fx), 0);

    const duplicate = await submit(fx, podcastBody('ep-reuse'));
    assert.deepEqual([duplicate.status, duplicate.body.jobId, duplicate.body.reused], [200, job.jobId, true]);
    assert.equal(fx.quota.reserveCalls.length, 1);
    assert.equal(fx.prober.calls, 1, 'reuse is decided before probing');

    fx.store.claimNextJob('w1', 30_000);
    fx.store.completeJob(job.jobId, { files: [] });
    const afterReady = await submit(fx, podcastBody('ep-reuse'));
    assert.deepEqual([afterReady.status, afterReady.body.jobId, afterReady.body.status], [200, job.jobId, 'ready']);
    assert.equal(fx.quota.reserveCalls.length, 1, 'ready artifact reuse is free');

    const otherQuality = await submit(fx, podcastBody('ep-reuse', 'fast'));
    assert.equal(otherQuality.status, 202, 'a different quality is a new operation');
    assert.equal(fx.quota.reserveCalls.length, 2);
  } finally {
    await fx.close();
  }
});

test('terminal states write one durable settlement each; success wins over late cancel', async () => {
  const fx = await setup();
  try {
    const succeeded = fx.store.getJob((await submit(fx, podcastBody('ep-ok'))).body.jobId)!;
    const failed = fx.store.getJob((await submit(fx, podcastBody('ep-fail'), 'lca_token-b')).body.jobId)!;
    fx.quota.limit = 10_000;
    const cancelled = fx.store.getJob((await submit(fx, podcastBody('ep-cancel'), 'lca_token-b')).body.jobId)!;

    fx.store.claimNextJob('w1', 30_000);
    fx.store.completeJob(succeeded.jobId, { files: [] });
    fx.store.claimNextJob('w2', 30_000);
    fx.store.failJob(failed.jobId, { code: 'ASR_FAILED', message: 'x', retryable: true, traceId: 't' });
    const cancel = await fetch(`${fx.base}/v1/content-jobs/${cancelled.jobId}`, { method: 'DELETE', headers: { authorization: 'Bearer lca_token-b' } });
    assert.equal(cancel.status, 200);
    await fetch(`${fx.base}/v1/content-jobs/${cancelled.jobId}`, { method: 'DELETE', headers: { authorization: 'Bearer lca_token-b' } });
    const lateCancel = await fetch(`${fx.base}/v1/content-jobs/${succeeded.jobId}`, { method: 'DELETE', headers: { authorization: 'Bearer lca_token-a' } });
    assert.equal(lateCancel.status, 409);

    assert.deepEqual(
      [succeeded, failed, cancelled].map((job) => {
        const row = fx.store.settlementFor(job.reservationId!);
        return [row?.outcome, row?.reason];
      }),
      [
        ['consumed', 'succeeded'],
        ['released', 'failed'],
        ['released', 'cancelled']
      ]
    );
    const dispatcher = new QuotaSettlementDispatcher({ store: fx.store, client: fx.quota, logger: new RedactingLogger(() => {}) });
    assert.deepEqual(await dispatcher.runOnce(), { delivered: 3, failed: 0, intents: 0 });
    assert.equal(fx.quota.settlements.length, 3);
    assert.deepEqual(await dispatcher.runOnce(), { delivered: 0, failed: 0, intents: 0 });
  } finally {
    await fx.close();
  }
});

test('settlements survive account-service outages and a process restart', async () => {
  const fx = await setup();
  try {
    const job = fx.store.getJob((await submit(fx, podcastBody('ep-restart'))).body.jobId)!;
    fx.store.claimNextJob('w1', 30_000);
    fx.store.completeJob(job.jobId, { files: [] });
    fx.quota.down = true;
    const logger = new RedactingLogger(() => {});
    assert.deepEqual(await new QuotaSettlementDispatcher({ store: fx.store, client: fx.quota, logger }).runOnce(), { delivered: 0, failed: 1, intents: 0 });

    const reopened = new JobStore(openDatabase(fx.dbPath, MIGRATIONS_DIR));
    fx.quota.down = false;
    const result = await new QuotaSettlementDispatcher({ store: reopened, client: fx.quota, logger }).runOnce();
    assert.equal(result.delivered, 1);
    assert.equal(fx.quota.status(job.reservationId!), 'consumed');
    assert.ok(reopened.settlementFor(job.reservationId!)?.deliveredAt);
    reopened.close();
  } finally {
    await fx.close();
  }
});

test('a crash between reserving and inserting is repaired by releasing the reservation', async () => {
  const fx = await setup();
  try {
    const now = Date.now();
    fx.store.recordIntent('content-job:cj_crashed', ACCOUNT_A, 'cj_crashed', 300, now - 120_000);
    fx.store.recordIntent('content-job:cj_inflight', ACCOUNT_A, 'cj_inflight', 300, now);
    const dispatcher = new QuotaSettlementDispatcher({ store: fx.store, client: fx.quota, logger: new RedactingLogger(() => {}) });
    const result = await dispatcher.runOnce();
    assert.equal(result.intents, 1, 'young intents may belong to an in-flight request');
    const crashed = fx.quota.reserveCalls.find((call) => call.operationKey === 'content-job:cj_crashed')!;
    assert.ok(crashed);
    await dispatcher.runOnce();
    assert.deepEqual(fx.quota.settlements.map(([, outcome, reason]) => [outcome, reason]), [['released', 'rejected_before_start']]);
    assert.deepEqual(fx.store.listIntents(Number.MAX_SAFE_INTEGER).map((intent) => intent.jobId), ['cj_inflight']);
  } finally {
    await fx.close();
  }
});

test('assistant-derived jobs reuse the transcript operation key; settled keys start a new attempt', async () => {
  const fx = await setup();
  try {
    const context = signAccountContext(
      { accountId: ACCOUNT_A, authMode: 'apple', sessionId: null, operationKey: 'assistant-transcript:tj_1', issuer: 'research-assistant' },
      SIGNING_KEY
    );
    const first = await submit(fx, podcastBody('ep-assistant'), ASSISTANT_CALLER, { [ACCOUNT_CONTEXT_HEADER]: context });
    assert.equal(first.status, 202);
    assert.equal(fx.store.getJob(first.body.jobId)?.operationKey, 'assistant-transcript:tj_1');

    fx.store.claimNextJob('w1', 30_000);
    fx.store.failJob(first.body.jobId, { code: 'ASR_FAILED', message: 'x', retryable: false, traceId: 't' });
    await new QuotaSettlementDispatcher({ store: fx.store, client: fx.quota, logger: new RedactingLogger(() => {}) }).runOnce();
    const again = await submit(fx, podcastBody('ep-assistant'), ASSISTANT_CALLER, { [ACCOUNT_CONTEXT_HEADER]: context });
    assert.equal(again.status, 202);
    const second = fx.store.getJob(again.body.jobId)!;
    assert.equal(second.operationKey, `assistant-transcript:tj_1#${second.jobId}`);
    assert.equal(fx.quota.status(second.reservationId!), 'reserved');
  } finally {
    await fx.close();
  }
});

test('queue claims are FIFO within per-account and global running limits', async () => {
  const fx = await setup();
  try {
    fx.quota.limit = 100_000;
    const a1 = (await submit(fx, podcastBody('ep-a1'))).body.jobId;
    const a2 = (await submit(fx, podcastBody('ep-a2'))).body.jobId;
    const b1 = (await submit(fx, podcastBody('ep-b1'), 'lca_token-b')).body.jobId;
    const limits = { perOwner: 1, global: 2 };
    assert.equal(fx.store.claimNextJob('w1', 30_000, Date.now(), limits)?.jobId, a1);
    assert.equal(fx.store.claimNextJob('w2', 30_000, Date.now(), limits)?.jobId, b1, 'A2 waits for A1');
    assert.equal(fx.store.claimNextJob('w3', 30_000, Date.now(), limits), null, 'global limit reached');
    fx.store.completeJob(a1, { files: [] });
    assert.equal(fx.store.claimNextJob('w1', 30_000, Date.now(), limits)?.jobId, a2);
    assert.equal(fx.store.getJob(a2)?.status, 'running');
  } finally {
    await fx.close();
  }
});

test('retrying a failed job reserves quota again under a new attempt key', async () => {
  const fx = await setup();
  try {
    const jobId = (await submit(fx, podcastBody('ep-retry'))).body.jobId as string;
    fx.store.claimNextJob('w1', 30_000);
    fx.store.failJob(jobId, { code: 'AUDIO_DOWNLOAD_FAILED', message: 'x', retryable: true, traceId: 't' });
    const retry = await fetch(`${fx.base}/v1/content-jobs/${jobId}/retry`, { method: 'POST', headers: { authorization: 'Bearer lca_token-a' } });
    assert.equal(retry.status, 202);
    const job = fx.store.getJob(jobId)!;
    assert.equal(job.status, 'queued');
    assert.equal(job.operationKey, `content-job:${jobId}#retry1`);
    assert.equal(fx.quota.status(job.reservationId!), 'reserved');
    assert.equal(fx.quota.reserveCalls.length, 2);
  } finally {
    await fx.close();
  }
});
