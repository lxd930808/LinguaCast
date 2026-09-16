import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { openDatabase } from '../../../src/db/migrations.js';
import { reclaimExpiredTurnLeases, scanV2Recovery } from '../../../src/db/v2/recovery.js';
import { V2Store, v2RequestHash } from '../../../src/db/v2/store.js';
import { DomainError } from '../../../src/domain/types.js';
import { newId, nowIso } from '../../../src/domain/ids.js';
import {
  canArtifactTransition,
  canResearchTransition,
  canTurnTransition,
  newArtifactId,
  newCitationId,
  newLeaseId,
  newMemoryEntryId,
  newMemoryProposalId,
  newMessageId,
  newOperationId,
  newResearchId,
  newSourceId,
  newTranscriptJobId,
  newTurnId
} from '../../../src/research-v2/state.js';

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), '../../../migrations');

function openPair(): { db: ReturnType<typeof openDatabase>; v2: V2Store; path: string } {
  const dir = mkdtempSync(join(tmpdir(), 'assistant-v2-'));
  const path = join(dir, 'a.db');
  const db = openDatabase(path, MIGRATIONS);
  return { db, v2: new V2Store(db), path };
}

/** Legacy V1 rows stay in the 0001 tables; the V1 store itself was removed in V18. */
function readLegacySession(db: ReturnType<typeof openDatabase>, sessionId: string): { title: string; phase: string } | undefined {
  return db.prepare('SELECT title, phase FROM sessions WHERE session_id = ?').get(sessionId) as
    | { title: string; phase: string }
    | undefined;
}

function seedResearch(store: V2Store, overrides: Partial<{ status: 'creating' | 'ready' }> = {}) {
  const now = nowIso();
  const researchId = newResearchId();
  store.createResearch(
    {
      researchId,
      ownerScope: 'selfhost',
      title: 'AI and accounting',
      status: overrides.status ?? 'creating',
      workspaceStatus: 'pending',
      outputLanguage: 'zh-Hans',
      storefront: 'US',
      targetLanguage: 'zh-Hans',
      translationQuality: 'quality',
      activeTurnId: null,
      createdAt: now,
      updatedAt: now,
      deletedAt: null
    },
    {
      researchId,
      directoryId: researchId,
      manifestVersion: 1,
      manifestSha256: null,
      integrityStatus: 'pending',
      lastRecoveredAt: null,
      createdAt: now,
      updatedAt: now
    },
    [
      {
        researchId,
        alias: 'notes',
        permission: 'read',
        allowedExtensions: ['.md'],
        maxFileBytes: 2_097_152,
        status: 'ready',
        grantedAt: now
      }
    ]
  );
  return researchId;
}

test('V2 state machines reject illegal transitions', () => {
  assert.equal(canResearchTransition('creating', 'ready'), true);
  assert.equal(canResearchTransition('creating', 'deleted'), false);
  assert.equal(canTurnTransition('running', 'interrupted'), true);
  assert.equal(canTurnTransition('completed', 'running'), false);
  assert.equal(canArtifactTransition('pending', 'ready'), true);
  assert.equal(canArtifactTransition('ready', 'pending'), false);
});

test('0003 applies on empty db and on a V1/V14 snapshot without rewriting V1 rows', () => {
  const { db, v2, path } = openPair();
  const now = nowIso();
  const sessionId = newId('as');
  db.prepare(
    `INSERT INTO sessions (session_id, title, phase, output_language, storefront, target_language, translation_quality,
       active_turn_id, created_at, updated_at, deleted_at)
     VALUES (?, 'legacy', 'researching', 'zh-Hans', 'US', 'zh-Hans', 'quality', NULL, ?, ?, NULL)`
  ).run(sessionId, now, now);
  const before = readLegacySession(db, sessionId);
  assert.equal(v2.listResearches('selfhost', 20, null).length, 0);
  db.close();
  const again = openDatabase(path, MIGRATIONS);
  const versions = again.prepare('SELECT version FROM schema_migrations ORDER BY version').all() as Array<{
    version: number;
  }>;
  assert.deepEqual(
    versions.map((row) => Number(row.version)),
    [1, 2, 3, 4, 5, 6]
  );
  const after = readLegacySession(again, sessionId);
  assert.equal(after?.title, 'legacy');
  assert.equal(after?.phase, before?.phase);
  const v1Tables = again
    .prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name IN ('sessions', 'v2_researches')`)
    .all() as Array<{ name: string }>;
  assert.deepEqual(
    v1Tables.map((row) => row.name).sort(),
    ['sessions', 'v2_researches']
  );
  again.close();
});

test('research create, pagination, and status machine', () => {
  const { v2 } = openPair();
  const first = seedResearch(v2);
  v2.setResearchStatus(first, 'creating', 'ready');
  const ready = v2.getResearch(first);
  assert.equal(ready?.status, 'ready');
  assert.equal(ready?.workspaceStatus, 'ready');
  const second = seedResearch(v2);
  v2.setResearchStatus(second, 'creating', 'ready');
  const page = v2.listResearches('selfhost', 1, null);
  assert.equal(page.length, 1);
  const rest = v2.listResearches('selfhost', 10, { updatedAt: page[0]!.updatedAt, researchId: page[0]!.researchId });
  assert.equal(rest.length, 1);
  assert.notEqual(rest[0]?.researchId, page[0]?.researchId);
  assert.throws(() => v2.setResearchStatus(first, 'ready', 'deleted'), DomainError);
  v2.close();
});

test('idempotency is scoped by owner and route', () => {
  const { v2 } = openPair();
  v2.putIdempotency('selfhost', 'POST /v2/assistant/researches', 'k1', v2RequestHash({ a: 1 }), 201, { ok: true });
  const hit = v2.getIdempotency('selfhost', 'POST /v2/assistant/researches', 'k1');
  assert.equal(hit?.hash, v2RequestHash({ a: 1 }));
  assert.equal(v2.getIdempotency('selfhost', 'POST /v2/assistant/researches/x/turns', 'k1'), null);
  assert.notEqual(v2RequestHash({ a: 1 }), v2RequestHash({ a: 2 }));
  v2.close();
});

test('worker lease reclaim interrupts a running turn', () => {
  const { v2 } = openPair();
  const researchId = seedResearch(v2);
  v2.setResearchStatus(researchId, 'creating', 'ready');
  const turnId = newTurnId();
  const now = nowIso();
  v2.insertTurn({
    turnId,
    researchId,
    mode: 'research',
    status: 'queued',
    userText: 'research AI',
    skillName: 'topic-research',
    skillVersion: '1',
    skillSha256: 'aa'.repeat(32),
    errorCode: null,
    errorMessage: null,
    createdAt: now,
    startedAt: null,
    finishedAt: null
  });
  v2.setTurnStatus(turnId, 'queued', 'running');
  assert.equal(v2.claimTurnLease(turnId, 'worker-a', 60_000, newLeaseId()), true);
  assert.equal(v2.claimTurnLease(turnId, 'worker-b', 60_000, newLeaseId()), false);
  v2.getDb().prepare('UPDATE v2_worker_leases SET expires_at = 1 WHERE turn_id = ?').run(turnId);
  const interrupted = reclaimExpiredTurnLeases(v2);
  assert.deepEqual(interrupted, [turnId]);
  assert.equal(v2.getTurn(turnId)?.status, 'interrupted');
  assert.equal(v2.claimTurnLease(turnId, 'worker-b', 60_000, newLeaseId()), true);
  v2.close();
});

test('delete uses tombstone then removes V2 children but keeps confirmed global memory', () => {
  const { v2 } = openPair();
  const researchId = seedResearch(v2);
  v2.setResearchStatus(researchId, 'creating', 'ready');
  const now = nowIso();
  const turnId = newTurnId();
  v2.insertTurn({
    turnId,
    researchId,
    mode: 'research',
    status: 'completed',
    userText: 'hello',
    skillName: null,
    skillVersion: null,
    skillSha256: null,
    errorCode: null,
    errorMessage: null,
    createdAt: now,
    startedAt: now,
    finishedAt: now
  });
  v2.insertMessage({
    messageId: newMessageId(),
    researchId,
    turnId,
    role: 'user',
    markdown: 'hello',
    createdAt: now
  });
  const artifactId = newArtifactId();
  v2.insertArtifact({
    artifactId,
    researchId,
    kind: 'web_page',
    status: 'ready',
    relativePath: 'sources/web/pages/page.md',
    mediaType: 'text/markdown',
    bytes: 12,
    sha256: 'bb'.repeat(32),
    producer: 'fetch_web_page',
    evidenceLevel: 'primary_content',
    sourceReference: { platform: 'web', sourceId: 'p', canonicalURL: 'https://example.com' },
    createdAt: now,
    updatedAt: now
  });
  v2.insertPassage({
    passageId: 'p-1',
    researchId,
    artifactId,
    ordinal: 1,
    text: 'accounting firms pilot document tools',
    startMs: null,
    endMs: null,
    createdAt: now
  });
  v2.insertMemoryEntry({
    memoryEntryId: newMemoryEntryId(),
    researchId,
    sourceResearchId: researchId,
    scope: 'research',
    type: 'finding',
    content: 'local note',
    status: 'active',
    sourceArtifactId: artifactId,
    hypothesis: false,
    createdAt: now,
    confirmedAt: now
  });
  const globalId = newMemoryEntryId();
  v2.insertMemoryEntry({
    memoryEntryId: globalId,
    researchId: null,
    sourceResearchId: researchId,
    scope: 'global',
    type: 'preference',
    content: 'Write reports in Chinese',
    status: 'confirmed',
    sourceArtifactId: null,
    hypothesis: false,
    createdAt: now,
    confirmedAt: now
  });
  v2.insertCitation({
    citationId: newCitationId(),
    researchId,
    messageId: null,
    artifactId,
    evidenceLevel: 'primary_content',
    label: 'example',
    passageId: 'p-1',
    startMs: null,
    endMs: null,
    sourceUrl: 'https://example.com',
    contentKey: null,
    quote: 'accounting firms',
    sha256: 'bb'.repeat(32)
  });
  const hits = v2.searchPassages(researchId, 'accounting');
  assert.equal(hits.length, 1);
  v2.markDeleting(researchId);
  assert.equal(v2.getResearch(researchId), null);
  assert.equal(v2.getResearch(researchId, true)?.status, 'deleting');
  v2.finalizeDeleted(researchId);
  assert.equal(v2.getResearch(researchId), null);
  assert.equal(v2.getResearch(researchId, true)?.status, 'deleted');
  assert.equal(v2.listMessages(researchId).length, 0);
  assert.equal(v2.listMemoryEntries(researchId).length, 0);
  assert.equal(v2.listConfirmedGlobalMemory('selfhost')[0]?.memoryEntryId, globalId);
  v2.close();
});

test('artifact and transcript uniqueness plus recovery scan', () => {
  const { v2 } = openPair();
  const researchId = seedResearch(v2);
  v2.setResearchStatus(researchId, 'creating', 'ready');
  const now = nowIso();
  const artifactId = newArtifactId();
  v2.insertArtifact({
    artifactId,
    researchId,
    kind: 'transcript',
    status: 'pending',
    relativePath: 'transcripts/youtube/so/transcript.json',
    mediaType: 'application/json',
    bytes: 0,
    sha256: 'cc'.repeat(32),
    producer: 'transcript-installer',
    evidenceLevel: 'transcript',
    sourceReference: null,
    createdAt: now,
    updatedAt: now
  });
  v2.setArtifactStatus(artifactId, 'pending', 'ready');
  const sourceId = newSourceId();
  v2.insertTranscriptJob({
    transcriptJobId: newTranscriptJobId(),
    researchId,
    sourceId,
    contentKey: 'video:youtube:dQw4w9WgXcQ',
    v10JobId: 'v10-1',
    status: 'requested',
    installStatus: 'requested',
    progress: 0,
    artifactId,
    error: null,
    confirmationTokenHash: 'hash',
    createdAt: now,
    updatedAt: now
  });
  assert.equal(v2.findTranscriptJobBySource(researchId, sourceId, 'video:youtube:dQw4w9WgXcQ')?.v10JobId, 'v10-1');
  v2.insertOperation({
    operationId: newOperationId(),
    researchId,
    artifactId,
    tempName: 'tmp-1',
    targetRelativePath: 'transcripts/youtube/so/transcript.json',
    expectedSha256: 'cc'.repeat(32),
    stage: 'pending_file',
    errorCode: null,
    createdAt: now,
    updatedAt: now
  });
  const scan = scanV2Recovery(v2);
  assert.equal(scan.pendingOperations, 1);
  assert.equal(scan.creatingResearches, 0);
  const proposal = v2.insertMemoryProposal({
    proposalId: newMemoryProposalId(),
    researchId,
    content: 'Prefer Chinese reports',
    reason: 'User asked in this research',
    status: 'pending',
    createdAt: now,
    expiresAt: '2026-09-10T00:00:00Z',
    confirmedAt: null,
    rejectedAt: null,
    memoryEntryId: null
  });
  v2.setMemoryProposalStatus(proposal.proposalId, 'pending', 'confirmed');
  assert.equal(v2.getMemoryProposal(proposal.proposalId)?.status, 'confirmed');
  assert.throws(() => v2.setMemoryProposalStatus(proposal.proposalId, 'confirmed', 'rejected'), DomainError);
  v2.close();
});
