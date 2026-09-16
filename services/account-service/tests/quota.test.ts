import assert from 'node:assert/strict';
import { test } from 'node:test';

import { nextResetAt, periodKey } from '../src/quota/period.js';
import type { QuotaKind } from '../src/quota/quota-store.js';
import { INTERNAL_TOKEN, call, signIn, startHarness, type Harness } from './support/harness.js';

async function reserve(h: Harness, accountId: string, operationKey: string, amount: number, kind: QuotaKind = 'media') {
  return call(h, 'POST', '/internal/v1/quota/reservations', {
    token: INTERNAL_TOKEN,
    body: { accountId, kind, operationKey, amount, service: 'content-pipeline', subjectRef: `job:${operationKey}` }
  });
}

async function settle(h: Harness, reservationId: string, outcome: 'consumed' | 'released', reason = 'succeeded') {
  return call(h, 'POST', `/internal/v1/quota/reservations/${reservationId}/settle`, {
    token: INTERNAL_TOKEN,
    body: { outcome, reason }
  });
}

function assertLedgerMatches(h: Harness, accountId: string, kind: QuotaKind, period: string): void {
  assert.deepEqual(h.quota.ledgerTotals(accountId, kind, period), h.quota.totals(accountId, kind, period), 'ledger and reservations agree');
}

test('Asia/Shanghai periods and reset times', () => {
  assert.equal(periodKey(Date.parse('2026-09-14T15:59:59Z')), '2026-09-14');
  assert.equal(periodKey(Date.parse('2026-09-14T16:00:00Z')), '2026-09-15');
  assert.equal(new Date(nextResetAt(Date.parse('2026-09-14T08:00:00Z'))).toISOString(), '2026-09-14T16:00:00.000Z');
  assert.equal(new Date(nextResetAt(Date.parse('2026-09-14T16:00:00Z'))).toISOString(), '2026-09-15T16:00:00.000Z');
});

test('media quota boundary: 1800 seconds per day, whole-request rejection above the limit', async () => {
  const h = await startHarness();
  try {
    const accountId = (await signIn(h)).account.accountId as string;
    assert.equal((await reserve(h, accountId, 'content-job:a', 1000)).status, 201);
    const second = await reserve(h, accountId, 'content-job:b', 800);
    assert.equal(second.status, 201);
    assert.match(second.body.reservationId, /^qr_/);
    assert.equal(second.body.periodKey, '2026-09-14');

    const over = await reserve(h, accountId, 'content-job:c', 1);
    assert.equal(over.status, 429);
    assert.equal(over.body.error.code, 'QUOTA_EXCEEDED');
    assert.deepEqual(
      { ...over.body.error.params },
      { kind: 'media', limit: 1800, used: 0, reserved: 1800, remaining: 0, requested: 1, resetAt: '2026-09-14T16:00:00.000Z' }
    );
    assert.equal(Number(over.headers.get('retry-after')), 8 * 3600);

    const tooLarge = await reserve(h, accountId, 'content-job:long', 1801);
    assert.equal(tooLarge.status, 422);
    assert.equal(tooLarge.body.error.code, 'QUOTA_REQUEST_TOO_LARGE');
    assertLedgerMatches(h, accountId, 'media', '2026-09-14');
  } finally {
    await h.close();
  }
});

test('assistant quota: 20 turns per day, independent of media', async () => {
  const h = await startHarness();
  try {
    const accountId = (await signIn(h)).account.accountId as string;
    for (let i = 0; i < 20; i += 1) {
      assert.equal((await reserve(h, accountId, `assistant-turn:${i}`, 1, 'assistant')).status, 201);
    }
    const over = await reserve(h, accountId, 'assistant-turn:20', 1, 'assistant');
    assert.equal(over.status, 429);
    assert.equal(over.body.error.params.kind, 'assistant');
    assert.equal((await reserve(h, accountId, 'content-job:x', 1800)).status, 201, 'media bucket is separate');
  } finally {
    await h.close();
  }
});

test('idempotent reservation and exactly-once settlement', async () => {
  const h = await startHarness();
  try {
    const accountId = (await signIn(h)).account.accountId as string;
    const first = await reserve(h, accountId, 'content-job:retry', 600);
    const retry = await reserve(h, accountId, 'content-job:retry', 600);
    assert.deepEqual([first.status, retry.status], [201, 200]);
    assert.equal(retry.body.reservationId, first.body.reservationId);
    assert.equal(h.quota.totals(accountId, 'media', '2026-09-14').reserved, 600, 'retries never double-reserve');
    const conflict = await reserve(h, accountId, 'content-job:retry', 601);
    assert.equal(conflict.status, 409);
    assert.equal(conflict.body.error.code, 'IDEMPOTENCY_CONFLICT');

    const id = first.body.reservationId as string;
    assert.equal((await settle(h, id, 'consumed')).body.status, 'consumed');
    assert.equal((await settle(h, id, 'consumed')).status, 200, 'same outcome is a no-op');
    const late = await settle(h, id, 'released', 'cancelled');
    assert.equal(late.status, 409);
    assert.equal(late.body.error.code, 'RESERVATION_ALREADY_SETTLED');
    assert.equal(late.body.error.params.status, 'consumed');
    assert.deepEqual(h.quota.totals(accountId, 'media', '2026-09-14'), { used: 600, reserved: 0 });

    const released = await reserve(h, accountId, 'content-job:failed', 1200);
    await settle(h, released.body.reservationId, 'released', 'failed');
    assert.equal((await reserve(h, accountId, 'content-job:after-release', 1200)).status, 201, 'released quota is available again');
    assert.equal((await call(h, 'GET', `/internal/v1/quota/reservations/${id}`, { token: INTERNAL_TOKEN })).body.status, 'consumed');
    assert.equal((await settle(h, 'qr_01ARZ3NDEKTSV4RRFFQ69G5FAV', 'released', 'failed')).body.error.code, 'RESERVATION_NOT_FOUND');
    assertLedgerMatches(h, accountId, 'media', '2026-09-14');
  } finally {
    await h.close();
  }
});

test('reservations keep their period across midnight', async () => {
  const h = await startHarness();
  try {
    const accountId = (await signIn(h)).account.accountId as string;
    h.clock.current = Date.parse('2026-09-14T15:59:30Z');
    const lateNight = await reserve(h, accountId, 'content-job:late', 1800);
    assert.equal(lateNight.body.periodKey, '2026-09-14');
    h.clock.advance(60_000);
    const nextDay = await reserve(h, accountId, 'content-job:next', 1800);
    assert.equal(nextDay.status, 201, 'new Shanghai day has a fresh bucket');
    assert.equal(nextDay.body.periodKey, '2026-09-15');
    await settle(h, lateNight.body.reservationId, 'consumed');
    assert.deepEqual(h.quota.totals(accountId, 'media', '2026-09-14'), { used: 1800, reserved: 0 });
    assert.deepEqual(h.quota.totals(accountId, 'media', '2026-09-15'), { used: 0, reserved: 1800 });
    const snapshot = await call(h, 'GET', '/v1/me/quota', { token: (await signIn(h)).accessToken });
    assert.equal(snapshot.body.periodKey, '2026-09-15');
  } finally {
    await h.close();
  }
});

test('concurrent reservations never oversell a period', async () => {
  const h = await startHarness();
  try {
    const accountId = (await signIn(h)).account.accountId as string;
    const results = await Promise.all(
      Array.from({ length: 12 }, (_, i) => reserve(h, accountId, `content-job:race-${i}`, 300))
    );
    const statuses = results.map((r) => r.status).sort();
    assert.equal(statuses.filter((s) => s === 201).length, 6);
    assert.equal(statuses.filter((s) => s === 429).length, 6);
    assert.deepEqual(h.quota.totals(accountId, 'media', '2026-09-14'), { used: 0, reserved: 1800 });
    assertLedgerMatches(h, accountId, 'media', '2026-09-14');
  } finally {
    await h.close();
  }
});

test('quota snapshot for the signed-in account', async () => {
  const h = await startHarness();
  try {
    const session = await signIn(h);
    const accountId = session.account.accountId as string;
    await reserve(h, accountId, 'content-job:one', 900);
    const consumed = await reserve(h, accountId, 'content-job:two', 300);
    await settle(h, consumed.body.reservationId, 'consumed');
    await reserve(h, accountId, 'assistant-turn:one', 1, 'assistant');

    assert.equal((await call(h, 'GET', '/v1/me/quota')).status, 401);
    const res = await call(h, 'GET', '/v1/me/quota', { token: session.accessToken });
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, {
      timezone: 'Asia/Shanghai',
      periodKey: '2026-09-14',
      resetAt: '2026-09-14T16:00:00.000Z',
      enforced: true,
      buckets: [
        { kind: 'media', unit: 'seconds', limit: 1800, used: 300, reserved: 900, remaining: 600 },
        { kind: 'assistant', unit: 'turns', limit: 20, used: 0, reserved: 1, remaining: 19 }
      ],
      concurrency: [
        { kind: 'media', limit: 1, running: 1, queued: 0 },
        { kind: 'assistant', limit: 1, running: 1, queued: 0 }
      ]
    });
  } finally {
    await h.close();
  }
});

test('only trusted services reserve, and only in their own name', async () => {
  const h = await startHarness();
  try {
    const session = await signIn(h);
    const accountId = session.account.accountId as string;
    const body = { accountId, kind: 'media', operationKey: 'content-job:x', amount: 60, service: 'content-pipeline' };
    assert.equal((await call(h, 'POST', '/internal/v1/quota/reservations', { token: session.accessToken, body })).status, 401);
    const impersonate = await call(h, 'POST', '/internal/v1/quota/reservations', {
      token: INTERNAL_TOKEN,
      body: { ...body, service: 'research-assistant' }
    });
    assert.equal(impersonate.status, 403);
    for (const bad of [{ amount: 0 }, { amount: 1.5 }, { kind: 'storage' }, { operationKey: 'has space' }, { accountId: 'admin' }]) {
      const res = await call(h, 'POST', '/internal/v1/quota/reservations', { token: INTERNAL_TOKEN, body: { ...body, ...bad } });
      assert.equal(res.status, 400, JSON.stringify(bad));
    }
    assert.equal((await reserve(h, 'acc_01ARZ3NDEKTSV4RRFFQ69G5FAV', 'content-job:ghost', 60)).status, 404);
  } finally {
    await h.close();
  }
});

test('account deletion blocks new reservations, then releases and anonymizes quota history', async () => {
  const h = await startHarness();
  try {
    const session = await signIn(h, { sub: 'quota-delete' });
    const accountId = session.account.accountId as string;
    const open = await reserve(h, accountId, 'content-job:open', 600);
    const done = await reserve(h, accountId, 'content-job:done', 300);
    await settle(h, done.body.reservationId, 'consumed');
    await call(h, 'DELETE', '/v1/me', { token: session.accessToken });

    const blocked = await reserve(h, accountId, 'content-job:new', 60);
    assert.equal(blocked.status, 403);
    assert.equal(blocked.body.error.code, 'ACCOUNT_DELETING');
    assert.equal((await reserve(h, accountId, 'content-job:open', 600)).status, 200, 'retry of an earlier operation still returns it');

    assert.equal(await h.deletion.runOnce(), 1);
    const deletion = h.store.getDeletionForAccount(accountId)!;
    const tombstone = `deleted:${deletion.deletionId}`;
    assert.equal(h.quota.get(open.body.reservationId)?.status, 'released');
    assert.equal(h.quota.get(open.body.reservationId)?.reason, 'account_deleted');
    assert.equal(h.quota.get(open.body.reservationId)?.accountId, tombstone);
    const remaining = h.db.prepare('SELECT COUNT(*) AS n FROM quota_ledger WHERE account_id = ?').get(accountId) as { n: number };
    assert.equal(Number(remaining.n), 0);
    assertLedgerMatches(h, tombstone, 'media', '2026-09-14');
  } finally {
    await h.close();
  }
});

test('selfhost deployments record reservations without enforcing limits', async () => {
  const h = await startHarness({ mode: 'selfhost' });
  try {
    const big = await reserve(h, 'selfhost', 'content-job:big', 20_000);
    assert.equal(big.status, 201);
    const again = await reserve(h, 'selfhost', 'content-job:bigger', 20_000);
    assert.equal(again.status, 201);
    const snapshot = await call(h, 'GET', '/v1/me/quota', { token: 'selfhost-deploy-token-0123456789abcdef' });
    assert.equal(snapshot.body.enforced, false);
    assert.equal(snapshot.body.buckets[0].reserved, 40_000);
  } finally {
    await h.close();
  }
});
