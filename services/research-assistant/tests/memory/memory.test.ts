import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { ArtifactWriter } from '../../src/artifacts/writer.js';
import { openDatabase } from '../../src/db/migrations.js';
import { V2Store } from '../../src/db/v2/store.js';
import { DomainError } from '../../src/domain/types.js';
import { GlobalMemory } from '../../src/memory/global-memory.js';
import { MemoryProposals } from '../../src/memory/proposals.js';
import { encodeResearchMemory, parseResearchMemory, ResearchMemory } from '../../src/memory/research-memory.js';
import { recallMemory } from '../../src/memory/retrieval.js';
import { WorkspaceManager } from '../../src/workspace/manager.js';

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), '../../migrations');

function harness() {
  const dir = mkdtempSync(join(tmpdir(), 'memory-v15-'));
  const db = openDatabase(join(dir, 'a.db'), MIGRATIONS);
  const store = new V2Store(db);
  const workspaceRoot = join(dir, 'workspaces');
  mkdirSync(workspaceRoot);
  const manager = new WorkspaceManager({
    root: workspaceRoot,
    store,
    diskFreeBytes: () => 8 * 1024 * 1024 * 1024
  });
  const create = (title: string) =>
    manager.create({
      ownerScope: 'selfhost',
      title,
      outputLanguage: 'zh-Hans',
      storefront: 'US',
      targetLanguage: 'zh-Hans',
      translationQuality: 'quality'
    });
  const a = create('memory-a');
  const b = create('memory-b');
  const writerA = new ArtifactWriter(store, a.researchId, manager.internalPath(a.researchId));
  const writerB = new ArtifactWriter(store, b.researchId, manager.internalPath(b.researchId));
  const globalRoot = join(dir, 'global-memory');
  mkdirSync(globalRoot);
  const global = new GlobalMemory(store, globalRoot);
  const research = new ResearchMemory({
    store,
    writerFor: (id) => (id === a.researchId ? writerA : id === b.researchId ? writerB : null)
  });
  const proposals = new MemoryProposals(store, global);
  return {
    dir,
    store,
    a,
    b,
    writerA,
    global,
    globalRoot,
    research,
    proposals,
    close: () => store.close()
  };
}

test('research memory encode round-trips ids types sources and hypothesis', () => {
  const encoded = encodeResearchMemory(
    '01ARZ3NDEKTSV4RRFFQ69G5FAV',
    [
      {
        memoryEntryId: 'me_01ARZ3NDEKTSV4RRFFQ69G5FJ0',
        scope: 'research',
        type: 'finding',
        content: 'Search metadata discusses AI tooling in accounting firms.',
        status: 'active',
        sourceArtifactId: '01ARZ3NDEKTSV4RRFFQ69G5FD1',
        hypothesis: false,
        createdAt: '2026-09-03T01:08:00Z',
        confirmedAt: '2026-09-03T01:08:00Z'
      }
    ],
    '2026-09-03T01:08:00Z'
  );
  const parsed = parseResearchMemory(encoded);
  assert.equal(parsed[0]?.memoryEntryId, 'me_01ARZ3NDEKTSV4RRFFQ69G5FJ0');
  assert.equal(parsed[0]?.type, 'finding');
  assert.equal(parsed[0]?.sourceArtifactId, '01ARZ3NDEKTSV4RRFFQ69G5FD1');
  assert.equal(parsed[0]?.hypothesis, false);
});

test('research memory is isolated and unsourced notes are hypotheses', async () => {
  const { store, a, b, writerA, research, close } = harness();
  const sourced = research.upsert(a.researchId, {
    type: 'finding',
    content: 'Search metadata discusses AI tooling in accounting firms.',
    sourceArtifactId: '01ARZ3NDEKTSV4RRFFQ69G5FD1',
    hypothesis: false
  });
  assert.equal(sourced.hypothesis, false);
  const hypo = research.upsert(a.researchId, {
    type: 'open_question',
    content: 'Whether the firms deployed tools in production is unknown.'
  });
  assert.equal(hypo.hypothesis, true);
  research.upsert(b.researchId, {
    type: 'finding',
    content: 'Unrelated note about podcast discovery.'
  });
  const snapshot = research.snapshot(a.researchId);
  assert.equal(snapshot.entries.length, 2);
  assert.equal(snapshot.entries.some((entry) => entry.content.includes('podcast')), false);
  const body = writerA.get(store.listArtifacts(a.researchId, 'research_memory').find((item) => item.status === 'ready')!.artifactId);
  assert.match(body.text, /accounting firms/);
  assert.equal(body.evidenceLevel, 'research_note');
  const hits = await recallMemory(store, { query: 'accounting firms', researchId: a.researchId });
  assert.equal(hits.some((hit) => hit.memoryEntryId === sourced.memoryEntryId), true);
  assert.equal(hits.some((hit) => hit.content.includes('podcast')), false);
  close();
});

test('global proposals stay out of recall until confirmed', async () => {
  const { store, a, globalRoot, research, proposals, global, close } = harness();
  research.upsert(a.researchId, {
    type: 'finding',
    content: 'Accounting firms are piloting document tools.',
    sourceArtifactId: '01ARZ3NDEKTSV4RRFFQ69G5FD1'
  });
  const pending = proposals.propose({
    researchId: a.researchId,
    content: 'Write future reports in Simplified Chinese by default.',
    reason: 'User asked for Chinese output in this research.'
  });
  const before = await recallMemory(store, { query: 'Chinese reports', researchId: a.researchId });
  assert.equal(before.some((hit) => hit.scope === 'global'), false);
  const confirmed = proposals.confirm(pending.proposalId);
  assert.equal(confirmed.scope, 'global');
  assert.equal(proposals.confirm(pending.proposalId).memoryEntryId, confirmed.memoryEntryId);
  const after = await recallMemory(store, { query: 'Chinese reports', researchId: a.researchId });
  assert.equal(after.some((hit) => hit.memoryEntryId === confirmed.memoryEntryId && hit.scope === 'global'), true);
  const disk = readFileSync(join(globalRoot, 'preferences.json'), 'utf8');
  assert.match(disk, /Simplified Chinese/);
  assert.equal(disk.includes(globalRoot), false);
  global.forget(confirmed.memoryEntryId);
  const forgotten = await recallMemory(store, { query: 'Chinese reports', researchId: a.researchId });
  assert.equal(forgotten.some((hit) => hit.memoryEntryId === confirmed.memoryEntryId), false);
  global.restore(confirmed.memoryEntryId);
  const restored = await recallMemory(store, { query: 'Chinese reports', researchId: a.researchId });
  assert.equal(restored.some((hit) => hit.memoryEntryId === confirmed.memoryEntryId), true);
  close();
});

test('rejected and expired proposals cannot be confirmed into context', async () => {
  const { store, a, proposals, close } = harness();
  const rejected = proposals.propose({
    researchId: a.researchId,
    content: 'Always cite Wikipedia.',
    reason: 'Not a user preference.'
  });
  proposals.reject(rejected.proposalId);
  assert.equal(proposals.reject(rejected.proposalId).status, 'rejected');
  const expired = proposals.propose({
    researchId: a.researchId,
    content: 'Use informal tone.',
    reason: 'Stale suggestion.',
    expiresAt: '2020-01-01T00:00:00Z'
  });
  assert.throws(
    () => proposals.confirm(expired.proposalId),
    (error: unknown) => error instanceof DomainError && error.code === 'MEMORY_PROPOSAL_EXPIRED'
  );
  const hits = await recallMemory(store, { query: 'Wikipedia informal', researchId: a.researchId });
  assert.equal(hits.some((hit) => hit.scope === 'global'), false);
  close();
});

test('deleting research drops research memory but keeps confirmed global prefs', async () => {
  const { store, a, research, proposals, close } = harness();
  research.upsert(a.researchId, {
    type: 'finding',
    content: 'Local accounting note.',
    sourceArtifactId: '01ARZ3NDEKTSV4RRFFQ69G5FD1'
  });
  const proposal = proposals.propose({
    researchId: a.researchId,
    content: 'Write future reports in Simplified Chinese by default.',
    reason: 'User asked for Chinese output in this research.'
  });
  const confirmed = proposals.confirm(proposal.proposalId);
  store.markDeleting(a.researchId);
  store.finalizeDeleted(a.researchId);
  assert.equal(store.listMemoryEntries(a.researchId).length, 0);
  assert.equal(store.listConfirmedGlobalMemory('selfhost')[0]?.memoryEntryId, confirmed.memoryEntryId);
  close();
});

test('qmd adapter failure falls back to keyword retrieval', async () => {
  const { store, a, research, close } = harness();
  research.upsert(a.researchId, {
    type: 'finding',
    content: 'Accounting firms are piloting document tools.',
    sourceArtifactId: '01ARZ3NDEKTSV4RRFFQ69G5FD1'
  });
  const hits = await recallMemory(store, {
    query: 'accounting',
    researchId: a.researchId,
    qmd: {
      async search() {
        throw new Error('qmd unavailable');
      }
    }
  });
  assert.equal(hits.some((hit) => hit.content.includes('Accounting') && hit.mode !== 'qmd'), true);
  close();
});
