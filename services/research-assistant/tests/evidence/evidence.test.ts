import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { ArtifactWriter } from '../../src/artifacts/writer.js';
import { openDatabase } from '../../src/db/migrations.js';
import { V2Store } from '../../src/db/v2/store.js';
import { DomainError } from '../../src/domain/types.js';
import { validateCitations } from '../../src/evidence/citations.js';
import { EvidenceService } from '../../src/evidence/index.js';
import { GlobalMemory } from '../../src/memory/global-memory.js';
import { MemoryProposals } from '../../src/memory/proposals.js';
import { FileTools } from '../../src/workspace/file-tools.js';
import { parseAdminGrants } from '../../src/workspace/grants.js';
import { WorkspaceManager } from '../../src/workspace/manager.js';

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), '../../migrations');

function harness() {
  const dir = mkdtempSync(join(tmpdir(), 'evidence-v15-'));
  const db = openDatabase(join(dir, 'a.db'), MIGRATIONS);
  const store = new V2Store(db);
  const workspaceRoot = join(dir, 'workspaces');
  const shared = join(dir, 'shared');
  const versions = join(dir, 'shared-versions');
  const notes = join(shared, 'notes');
  mkdirSync(workspaceRoot);
  mkdirSync(shared);
  mkdirSync(versions);
  mkdirSync(notes);
  writeFileSync(join(notes, 'inbox.md'), 'The town library budget increased this year.\n');
  const adminGrants = parseAdminGrants({
    grants: [
      {
        alias: 'notes',
        root: notes,
        permission: 'read',
        allowedExtensions: ['.md', '.txt'],
        maxFileBytes: 2097152
      }
    ]
  });
  const manager = new WorkspaceManager({
    root: workspaceRoot,
    store,
    diskFreeBytes: () => 8 * 1024 * 1024 * 1024
  });
  const a = manager.create({
    ownerScope: 'selfhost',
    title: 'evidence-a',
    outputLanguage: 'zh-Hans',
    storefront: 'US',
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    grants: [{ alias: 'notes', permission: 'read', allowedExtensions: ['.md', '.txt'], maxFileBytes: 2097152 }]
  });
  const b = manager.create({
    ownerScope: 'selfhost',
    title: 'evidence-b',
    outputLanguage: 'zh-Hans',
    storefront: 'US',
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality'
  });
  const writerA = new ArtifactWriter(store, a.researchId, manager.internalPath(a.researchId));
  const writerB = new ArtifactWriter(store, b.researchId, manager.internalPath(b.researchId));
  const toolsA = new FileTools({
    store,
    researchId: a.researchId,
    workspaceDir: manager.internalPath(a.researchId),
    adminGrants,
    sharedWriteEnabled: false,
    sharedVersionRoot: versions
  });
  const toolsB = new FileTools({
    store,
    researchId: b.researchId,
    workspaceDir: manager.internalPath(b.researchId),
    adminGrants,
    sharedWriteEnabled: false,
    sharedVersionRoot: versions
  });
  const evidence = new EvidenceService({
    store,
    writerFor: (id) => (id === a.researchId ? writerA : id === b.researchId ? writerB : null),
    fileToolsFor: (id) => (id === a.researchId ? toolsA : id === b.researchId ? toolsB : null)
  });
  return { dir, store, a, b, writerA, writerB, evidence, manager, close: () => store.close() };
}

test('retrieval ranks primary content over search metadata and keeps conflicts', async () => {
  const { a, writerA, evidence, close } = harness();
  const pageOne = writerA.save({
    kind: 'web_page',
    producer: 'fetch_web_page',
    evidenceLevel: 'primary_content',
    sourceURL: 'https://example.com/library-open',
    contents: 'The library will stay open on weekends for students.\n',
    passages: [{ passageId: 'p001', text: 'The library will stay open on weekends for students.' }]
  });
  const pageTwo = writerA.save({
    kind: 'web_page',
    producer: 'fetch_web_page',
    evidenceLevel: 'primary_content',
    sourceURL: 'https://example.test/library-closed',
    contents: 'The library is closed on weekends after budget cuts.\n',
    passages: [{ passageId: 'p002', text: 'The library is closed on weekends after budget cuts.' }]
  });
  writerA.save({
    kind: 'youtube_search',
    producer: 'search_youtube',
    evidenceLevel: 'search_metadata',
    contents: `${JSON.stringify({
      query: 'library weekends',
      results: [{ sourceId: 'vid1', title: 'Library weekends', canonicalURL: 'https://youtu.be/vid1' }]
    })}\n`
  });
  const pack = await evidence.retrieve({ researchId: a.researchId, query: 'library weekends' });
  assert.equal(pack.items[0]?.evidenceLevel, 'primary_content');
  assert.equal(pack.items.some((item) => item.evidenceLevel === 'search_metadata'), true);
  assert.equal(
    pack.items.find((item) => item.kind === 'youtube_search')?.evidenceLevel,
    'search_metadata'
  );
  assert.ok(pack.conflicts.length >= 1);
  assert.equal(pack.items.some((item) => item.artifactId === pageOne.artifactId), true);
  assert.equal(pack.items.some((item) => item.artifactId === pageTwo.artifactId), true);
  close();
});

test('cross-research, corrupt, and unauthorized shared files stay out of the pack', async () => {
  const { a, b, store, writerA, writerB, evidence, close } = harness();
  writerB.save({
    kind: 'web_page',
    producer: 'fetch_web_page',
    evidenceLevel: 'primary_content',
    sourceURL: 'https://example.net/other',
    contents: 'Secret accounting notes from another research.\n'
  });
  const corrupt = writerA.save({
    kind: 'web_page',
    producer: 'fetch_web_page',
    evidenceLevel: 'primary_content',
    sourceURL: 'https://example.com/broken',
    contents: 'Broken library page that should leave the index.\n'
  });
  store.setArtifactStatus(corrupt.artifactId, 'ready', 'corrupt');
  store.removePassagesForArtifact(corrupt.artifactId);
  const packA = await evidence.retrieve({ researchId: a.researchId, query: 'library accounting' });
  assert.equal(packA.items.some((item) => item.excerpt.includes('Secret accounting')), false);
  assert.equal(packA.items.some((item) => item.artifactId === corrupt.artifactId), false);
  const packB = await evidence.retrieve({ researchId: b.researchId, query: 'library budget' });
  assert.equal(packB.items.some((item) => item.kind === 'shared_file'), false);
  const packShared = await evidence.retrieve({ researchId: a.researchId, query: 'library budget' });
  assert.equal(packShared.items.some((item) => item.kind === 'shared_file'), true);
  close();
});

test('no evidence returns a structured gap and preferences are not facts', async () => {
  const { dir, store, a, evidence, close } = harness();
  const globalRoot = join(dir, 'global-memory');
  mkdirSync(globalRoot);
  const global = new GlobalMemory(store, globalRoot);
  const proposals = new MemoryProposals(store, global);
  const proposal = proposals.propose({
    researchId: a.researchId,
    content: 'Prefer short citations and Simplified Chinese.',
    reason: 'User asked for brief sourced answers.'
  });
  proposals.confirm(proposal.proposalId);
  const empty = await evidence.retrieve({ researchId: a.researchId, query: 'unrelated fusion reactor' });
  assert.equal(empty.items.length, 0);
  assert.equal(empty.gaps[0]?.code, 'EVIDENCE_NOT_FOUND');
  assert.ok(empty.gaps[0]?.suggestions.includes('request_transcription'));
  const prefs = await evidence.retrieve({ researchId: a.researchId, query: 'Simplified Chinese citations' });
  assert.equal(prefs.items.some((item) => item.evidenceLevel === 'user_preference'), false);
  assert.equal(prefs.preferences.some((item) => item.evidenceLevel === 'user_preference'), true);
  close();
});

test('citation validator locates web, transcript, and search metadata correctly', () => {
  const { a, store, writerA, close } = harness();
  const page = writerA.save({
    kind: 'web_page',
    producer: 'fetch_web_page',
    evidenceLevel: 'primary_content',
    sourceURL: 'https://example.com/ai-accounting',
    contents: 'Accounting firms adopted AI tooling this year.\n',
    passages: [{ passageId: 'p001', text: 'Accounting firms adopted AI tooling this year.' }]
  });
  const transcript = writerA.save({
    kind: 'transcript',
    producer: 'transcript-installer',
    evidenceLevel: 'transcript',
    mediaType: 'application/json',
    relativePath: 'transcripts/youtube/clip1/transcript.json',
    contentKey: 'video:youtube:dQw4w9WgXcQ',
    sourceURL: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    contents: '{"schemaVersion":1,"segments":[]}\n',
    passages: [
      {
        passageId: 'p-0042',
        text: 'A small library matters to the town.',
        startMs: 1112000,
        endMs: 1144000
      }
    ]
  });
  const search = writerA.save({
    kind: 'youtube_search',
    producer: 'search_youtube',
    evidenceLevel: 'search_metadata',
    contents: '{"query":"library","results":[]}\n'
  });
  const web = validateCitations(store, a.researchId, [
    {
      artifactId: page.artifactId,
      evidenceLevel: 'primary_content',
      passageId: 'p001',
      sourceURL: 'https://example.com/ai-accounting',
      quote: 'Accounting firms adopted AI tooling this year.',
      sha256: page.sha256
    }
  ]);
  assert.equal(web.ok, true);
  const spoken = validateCitations(store, a.researchId, [
    {
      artifactId: transcript.artifactId,
      evidenceLevel: 'transcript',
      passageId: 'p-0042',
      contentKey: 'video:youtube:dQw4w9WgXcQ',
      startMilliseconds: 1112000,
      endMilliseconds: 1144000,
      quote: 'A small library matters to the town.',
      sha256: transcript.sha256
    }
  ]);
  assert.equal(spoken.ok, true);
  const disguised = validateCitations(store, a.researchId, [
    {
      artifactId: search.artifactId,
      evidenceLevel: 'primary_content',
      quote: 'library',
      sha256: search.sha256
    }
  ]);
  assert.equal(disguised.ok, false);
  const otherResearch = validateCitations(store, a.researchId, [
    {
      artifactId: '01ARZ3NDEKTSV4RRFFQ69G5FZZ',
      evidenceLevel: 'primary_content',
      passageId: 'p001',
      sourceURL: 'https://example.com/ai-accounting',
      quote: 'Accounting firms adopted AI tooling this year.'
    }
  ]);
  assert.equal(otherResearch.ok, false);
  close();
});

test('unknown research cannot retrieve evidence', async () => {
  const { evidence, close } = harness();
  await assert.rejects(
    () => evidence.retrieve({ researchId: '01ARZ3NDEKTSV4RRFFQ69G5FAV', query: 'library' }),
    (error: unknown) => error instanceof DomainError && error.code === 'RESEARCH_NOT_FOUND'
  );
  close();
});
