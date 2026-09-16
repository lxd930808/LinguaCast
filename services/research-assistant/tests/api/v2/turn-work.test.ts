import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { V2EventRecord } from '../../../src/db/v2/store.js';
import { projectTurnWork } from '../../../src/api/v2/turn-work.js';

function event(
  turnId: string,
  type: string,
  payload: Record<string, unknown>,
  occurredAt = '2026-09-03T01:00:00Z'
): V2EventRecord {
  return {
    eventId: 0,
    researchId: '01ARZ3NDEKTSV4RRFFQ69G5FAV',
    turnId,
    type,
    sequence: 0,
    payload,
    occurredAt
  };
}

test('turnWork folds thinking deltas and truncates at 4096 chars', () => {
  const chunk = 'x'.repeat(512);
  const events: V2EventRecord[] = [
    event('vt_a', 'thinking.started', { blockId: 'th_0' }),
    event('vt_a', 'thinking.delta', { blockId: 'th_0', text: chunk }, '2026-09-03T01:00:01Z'),
    event('vt_a', 'thinking.delta', { blockId: 'th_0', text: chunk }, '2026-09-03T01:00:02Z'),
    event('vt_a', 'thinking.delta', { blockId: 'th_0', text: chunk }, '2026-09-03T01:00:03Z'),
    event('vt_a', 'thinking.delta', { blockId: 'th_0', text: chunk }, '2026-09-03T01:00:04Z'),
    event('vt_a', 'thinking.delta', { blockId: 'th_0', text: chunk }, '2026-09-03T01:00:05Z'),
    event('vt_a', 'thinking.delta', { blockId: 'th_0', text: chunk }, '2026-09-03T01:00:06Z'),
    event('vt_a', 'thinking.delta', { blockId: 'th_0', text: chunk }, '2026-09-03T01:00:07Z'),
    event('vt_a', 'thinking.delta', { blockId: 'th_0', text: chunk }, '2026-09-03T01:00:08Z'),
    event('vt_a', 'thinking.delta', { blockId: 'th_0', text: chunk }, '2026-09-03T01:00:09Z'),
    event('vt_a', 'thinking.completed', { blockId: 'th_0', durationMs: 9000 }, '2026-09-03T01:00:10Z')
  ];
  const work = projectTurnWork(events, []);
  assert.equal(work.length, 1);
  assert.equal(work[0].turnId, 'vt_a');
  assert.equal(work[0].thinking?.status, 'done');
  assert.equal(work[0].thinking?.text.length, 4096);
  assert.equal(work[0].thinking?.truncated, true);
  assert.equal(work[0].thinking?.durationMs, 9000);
  assert.equal(work[0].thinking?.redacted, false);
  assert.deepEqual(work[0].tools, []);
});

test('redacted thinking keeps no text and running tools fold by callId', () => {
  const events: V2EventRecord[] = [
    event('vt_a', 'thinking.started', { blockId: 'th_0' }),
    event('vt_a', 'thinking.completed', { blockId: 'th_0', redacted: true }),
    event('vt_a', 'tool.started', { callId: 'call_1', tool: 'search_youtube', query: 'ai accounting' }),
    event('vt_a', 'tool.started', { callId: 'call_2', tool: 'retrieve_evidence' }),
    event('vt_a', 'tool.completed', { callId: 'call_1', tool: 'search_youtube', ok: true })
  ];
  const work = projectTurnWork(events, []);
  assert.equal(work[0].thinking?.status, 'redacted');
  assert.equal(work[0].thinking?.text, '');
  assert.equal(work[0].thinking?.redacted, true);
  assert.equal(work[0].tools.length, 2);
  assert.equal(work[0].tools[0].status, 'completed');
  assert.equal(work[0].tools[0].labelKey, 'search_youtube');
  assert.equal(work[0].tools[0].query, 'ai accounting');
  assert.equal(work[0].tools[1].status, 'running');
});

test('turns without thinking or tool events are omitted and duration comes from the turn record', () => {
  const events: V2EventRecord[] = [
    event('vt_a', 'turn.started', { mode: 'research' }),
    event('vt_b', 'tool.started', { callId: 'call_1', tool: 'web_search' })
  ];
  const turns = [
    {
      turnId: 'vt_b',
      researchId: '01ARZ3NDEKTSV4RRFFQ69G5FAV',
      mode: 'research' as const,
      status: 'completed' as const,
      userText: 'hi',
      skillName: null,
      skillVersion: null,
      skillSha256: null,
      errorCode: null,
      errorMessage: null,
      createdAt: '2026-09-03T01:00:00Z',
      startedAt: '2026-09-03T01:00:01Z',
      finishedAt: '2026-09-03T01:00:04Z'
    }
  ];
  const work = projectTurnWork(events, turns);
  assert.equal(work.length, 1);
  assert.equal(work[0].turnId, 'vt_b');
  assert.equal(work[0].durationMs, 3000);
});
