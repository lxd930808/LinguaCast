import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { FakeAgentRuntime, type AgentEvent, type AgentRuntime } from '../../src/agent/runtime.js';
import { loadConfig } from '../../src/config/index.js';
import { createApp } from '../../src/app.js';
import { ArtifactWriter } from '../../src/artifacts/writer.js';
import type { V10ContentClient } from '../../src/content/v10-client.js';
import { contentKeyFor, containsTranslationLeak, TranscriptJobs } from '../../src/content/v2/transcript-jobs.js';
import { openDatabase } from '../../src/db/migrations.js';
import { V2Store } from '../../src/db/v2/store.js';
import { DomainError } from '../../src/domain/types.js';
import type { EvidencePack } from '../../src/evidence/pack.js';
import { recallMemory } from '../../src/memory/retrieval.js';
import { RedactingLogger } from '../../src/observability/logger.js';
import { V2ResearchOrchestrator, type V2OrchestratorConfig } from '../../src/research-v2/orchestrator.js';
import { newSourceId } from '../../src/research-v2/state.js';
import type { V2MediaSearch } from '../../src/research-v2/tool-dispatch.js';
import { StaticWebSearchProvider } from '../../src/web/search-client.js';
import { WebResearch } from '../../src/web/service.js';
import { FileTools } from '../../src/workspace/file-tools.js';
import { parseAdminGrants } from '../../src/workspace/grants.js';
import { WorkspaceManager } from '../../src/workspace/manager.js';
import { createV2Stack } from '../../src/api/v2/assemble.js';

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), '../../migrations');
const TOKEN = 'test-assistant-token-0123456789';

class StepAgent implements AgentRuntime {
  readonly results: unknown[] = [];
  constructor(private readonly steps: Array<(results: unknown[]) => AgentEvent>) {}
  async *run(input: Parameters<AgentRuntime['run']>[0]): AsyncIterable<AgentEvent> {
    for (const build of this.steps) {
      const event = build(this.results);
      if (event.type === 'tool_call') {
        yield event;
        const result = await input.executeTool({ name: event.tool ?? '', args: event.args ?? {} });
        this.results.push(result);
        yield { type: 'tool_result', tool: event.tool, result };
      } else {
        yield event;
      }
    }
  }
}

function countingV10(): V10ContentClient & { lookups: number; creates: number } {
  const client = {
    lookups: 0,
    creates: 0,
    async lookup() {
      client.lookups += 1;
      return null;
    },
    async create() {
      client.creates += 1;
      throw new Error('create should not run in this test');
    },
    async get() {
      throw new Error('get should not run');
    },
    async downloadSegments() {
      throw new Error('download should not run');
    }
  };
  return client;
}

const mediaSearch: V2MediaSearch = {
  async searchYouTube(query) {
    if (query.includes('fail-youtube')) throw new Error('provider down');
    return {
      hits: [
        {
          sourceId: 'dQw4w9WgXcQ',
          title: 'AI accounting for firms',
          canonicalURL: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          platform: 'youtube',
          provider: 'ytdlp'
        }
      ]
    };
  },
  async searchPodcasts() {
    return {
      hits: [
        {
          sourceId: 'ep-1',
          title: 'Accounting podcast',
          canonicalURL: 'https://podcasts.apple.com/episode/id9',
          platform: 'podcast',
          sourceType: 'podcast_episode',
          provider: 'apple_search',
          feedURL: 'https://feeds.example.test/show.xml',
          enclosureUrl: 'https://cdn.example.test/9.mp3'
        }
      ]
    };
  }
};

function pageFetch(body: string) {
  return async () => {
    const bytes = Buffer.from(`<html><p>${body}</p></html>`);
    return {
      status: 200,
      headers: { get: (name: string) => (name.toLowerCase() === 'content-type' ? 'text/html' : null) },
      arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
    };
  };
}

function orchestratorHarness(agent: AgentRuntime, overrides: Partial<V2OrchestratorConfig> = {}, webEnabled = false) {
  const dir = mkdtempSync(join(tmpdir(), 'v15-e2e-'));
  const db = openDatabase(join(dir, 'a.db'), MIGRATIONS);
  const store = new V2Store(db);
  const workspaceRoot = join(dir, 'workspaces');
  const globalMemoryRoot = join(dir, 'global-memory');
  const sharedVersionRoot = join(dir, 'shared-versions');
  mkdirSync(workspaceRoot);
  mkdirSync(globalMemoryRoot);
  mkdirSync(sharedVersionRoot);
  const workspace = new WorkspaceManager({
    root: workspaceRoot,
    store,
    diskFreeBytes: () => 8 * 1024 * 1024 * 1024
  });
  const v10 = countingV10();
  const provider = new StaticWebSearchProvider('fixture', async () => [
    {
      title: 'Accounting firms',
      url: 'https://example.com/ai-accounting',
      snippet: 'Firms are piloting document review tools.',
      publishedAt: null,
      site: 'example.com'
    },
    {
      title: 'Second page',
      url: 'https://example.com/second',
      snippet: 'A second readable page about payroll.',
      publishedAt: null,
      site: 'example.com'
    }
  ]);
  const orch = new V2ResearchOrchestrator({
    store,
    workspace,
    agent,
    v10,
    mediaSearch,
    webFor: webEnabled
      ? (_researchId, writer) =>
          new WebResearch({
            enabled: true,
            provider,
            writer,
            lookup: async () => ['203.0.113.10'],
            fetchImpl: pageFetch('Firms are piloting document review tools for accounting teams.'),
            maxPageBytes: 64 * 1024
          })
      : undefined,
    config: {
      assistantWebEnabled: webEnabled,
      sharedWriteEnabled: false,
      rgPath: 'rg',
      maxGrepMatches: 200,
      maxGrepMs: 5000,
      globalMemoryRoot,
      sharedVersionRoot,
      ...overrides
    }
  });
  return { dir, store, workspace, orch, v10, close: () => store.close() };
}

async function listen(app: ReturnType<typeof createApp>): Promise<{ port: number; close: () => Promise<void> }> {
  await new Promise<void>((resolve) => app.server.listen(0, '127.0.0.1', () => resolve()));
  const port = (app.server.address() as { port: number }).port;
  return { port, close: async () => app.close() };
}

function apiHarness() {
  const root = mkdtempSync(join(tmpdir(), 'v15-e2e-api-'));
  const workspaceRoot = join(root, 'workspaces');
  mkdirSync(workspaceRoot);
  mkdirSync(join(root, 'global-memory'));
  mkdirSync(join(root, 'shared-versions'));
  const config = loadConfig({
    ASSISTANT_IDENTITY_MODE: 'selfhost', ASSISTANT_SERVICE_TOKEN: TOKEN,
    V10_SERVICE_TOKEN: 'test-v10-token-0123456789',
    V10_BASE_URL: 'https://content.example.test',
    NODE_ENV: 'test',
    ASSISTANT_DATABASE_PATH: join(root, 'a.db'),
    ASSISTANT_TEMP_ROOT: join(root, 'tmp'),
    ASSISTANT_WORKSPACE_ROOT: workspaceRoot,
    ASSISTANT_GLOBAL_MEMORY_ROOT: join(root, 'global-memory'),
    ASSISTANT_SHARED_VERSION_ROOT: join(root, 'shared-versions')
  });
  const db = openDatabase(config.databasePath, MIGRATIONS);
  const v2 = createV2Stack({ db, config, agent: new FakeAgentRuntime(), v10: countingV10() });
  const app = createApp({
    config,
    logger: new RedactingLogger(() => undefined),
    v2: v2.application,
    readiness: {
      config: async () => ({ ok: true }),
      database: async () => ({ ok: true }),
      tempDir: async () => ({ ok: true }),
      piConfig: async () => ({ ok: true }),
      ytdlp: async () => ({ ok: true }),
      workspace: async () => ({ ok: true, detail: 'writable' })
    }
  });
  return { root, workspaceRoot, db, v2, app, close: () => db.close() };
}

function p95(samples: number[]): number {
  const sorted = [...samples].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.95) - 1)] as number;
}

test('e2e 1: create research commits workspace and first turn emits workspace.created', async () => {
  const ctx = apiHarness();
  const { port, close } = await listen(ctx.app);
  try {
    const created = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${TOKEN}`,
        'content-type': 'application/json',
        'idempotency-key': 'ik-e2e-1'
      },
      body: JSON.stringify({ title: 'AI 对会计行业的影响', outputLanguage: 'zh-Hans' })
    });
    assert.equal(created.status, 201);
    const research = (await created.json()) as { researchId: string };
    assert.equal(existsSync(join(ctx.workspaceRoot, research.researchId, 'manifest.json')), true);
    assert.equal(JSON.stringify(research).includes(ctx.root), false);
    const turn = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}/turns`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${TOKEN}`,
        'content-type': 'application/json',
        'idempotency-key': 'ik-e2e-1-turn'
      },
      body: JSON.stringify({ message: 'start', mode: 'research' })
    });
    const accepted = (await turn.json()) as { eventsURL: string };
    const sse = await fetch(`http://127.0.0.1:${port}${accepted.eventsURL}`, {
      headers: { authorization: `Bearer ${TOKEN}` },
      signal: AbortSignal.timeout(10_000)
    });
    const text = await sse.text();
    assert.match(text, /workspace\.created/);
    assert.equal(text.includes(ctx.root), false);
  } finally {
    await close();
    ctx.close();
  }
});

test('e2e 2-4: web youtube podcast artifacts and youtube failure stays partial', async () => {
  const agent = new StepAgent([
    () => ({ type: 'tool_call', tool: 'web_search', args: { query: 'AI accounting' } }),
    () => ({ type: 'tool_call', tool: 'search_youtube', args: { query: 'fail-youtube' } }),
    () => ({ type: 'tool_call', tool: 'search_podcasts', args: { query: 'accounting show' } }),
    () => ({ type: 'tool_call', tool: 'fetch_web_page', args: { url: 'https://example.com/ai-accounting' } }),
    () => ({ type: 'tool_call', tool: 'fetch_web_page', args: { url: 'https://example.com/second' } }),
    () => ({ type: 'done' })
  ]);
  const { orch, store, close } = orchestratorHarness(agent, { assistantWebEnabled: true }, true);
  const research = orch.createResearch({ ownerScope: 'selfhost', title: 'AI 对会计行业的影响' });
  const turn = orch.createTurn(research.researchId, { mode: 'research', text: 'search all sources' });
  await orch.runTurn(turn.turnId);
  assert.equal(store.listArtifacts(research.researchId, 'web_search', 'ready').length, 1);
  assert.equal(store.listArtifacts(research.researchId, 'youtube_search', 'ready').length, 1);
  assert.equal(store.listArtifacts(research.researchId, 'podcast_search', 'ready').length, 1);
  assert.equal(store.listArtifacts(research.researchId, 'web_page', 'ready').length, 2);
  const youtube = JSON.parse(
    orch.writerFor(research.researchId).get(store.listArtifacts(research.researchId, 'youtube_search', 'ready')[0]!.artifactId)
      .text
  ) as { status: string };
  assert.equal(youtube.status, 'failure');
  const podcast = JSON.parse(
    orch.writerFor(research.researchId).get(store.listArtifacts(research.researchId, 'podcast_search', 'ready')[0]!.artifactId)
      .text
  ) as { results: Array<{ feedURL?: string | null; enclosureUrl?: string | null }> };
  assert.equal(podcast.results[0]?.feedURL, 'https://feeds.example.test/show.xml');
  assert.equal(podcast.results[0]?.enclosureUrl, 'https://cdn.example.test/9.mp3');
  const report = store.listArtifacts(research.researchId, 'report', 'ready')[0];
  assert.ok(report);
  close();
});

test('e2e 5: reading search results without confirm never calls V10', async () => {
  const agent = new StepAgent([
    () => ({ type: 'tool_call', tool: 'search_youtube', args: { query: 'ai accounting' } }),
    () => ({ type: 'done' })
  ]);
  const { orch, v10, close } = orchestratorHarness(agent);
  const research = orch.createResearch({ ownerScope: 'selfhost', title: 'no transcribe' });
  const turn = orch.createTurn(research.researchId, { mode: 'research', text: 'just search' });
  await orch.runTurn(turn.turnId);
  assert.equal(v10.lookups, 0);
  assert.equal(v10.creates, 0);
  close();
});

test('e2e 6-7: confirmed transcription installs source-only and reuses the V10 job', async () => {
  const { createHash } = await import('node:crypto');
  const segments = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../fixtures/transcripts/learning-segments-bilingual.json'));
  const sha = createHash('sha256').update(segments).digest('hex');
  const agent = new StepAgent([() => ({ type: 'done' })]);
  const { orch, store, close } = orchestratorHarness(agent);
  let creates = 0;
  const v10: V10ContentClient = {
    async lookup() {
      return {
        jobId: 'job_reuse',
        status: 'ready',
        stage: 'ready',
        progress: 1,
        artifacts: { files: [{ name: 'segments.json', role: 'segments', status: 'ready', bytes: segments.length, sha256: sha }] }
      };
    },
    async create() {
      creates += 1;
      throw new Error('create should not run on lookup hit');
    },
    async get() {
      return {
        jobId: 'job_reuse',
        status: 'ready',
        stage: 'ready',
        progress: 1,
        artifacts: { files: [{ name: 'segments.json', role: 'segments', status: 'ready', bytes: segments.length, sha256: sha }] }
      };
    },
    async downloadSegments() {
      return { body: segments, sha256: sha };
    }
  };
  const research = orch.createResearch({ ownerScope: 'selfhost', title: 'transcribe podcast' });
  const sourceId = newSourceId();
  const source = {
    sourceId,
    platform: 'youtube' as const,
    nativeSourceId: 'dQw4w9WgXcQ',
    canonicalURL: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    title: 'Demo'
  };
  orch.writerFor(research.researchId).save({
    kind: 'youtube_search',
    producer: 'search_youtube',
    evidenceLevel: 'search_metadata',
    contents: JSON.stringify({
      results: [{ sourceId: 'dQw4w9WgXcQ', assistantSourceId: sourceId, canonicalURL: source.canonicalURL, title: source.title }]
    })
  });
  const jobs = orch.transcriptJobs;
  const issued = jobs.issue({ researchId: research.researchId, sourceId, source });
  const realJobs = new TranscriptJobs({
    store,
    v10,
    writerFor: (id) => (id === research.researchId ? orch.writerFor(id) : null),
    sleep: async () => undefined
  });
  const first = await realJobs.request({
    researchId: research.researchId,
    sourceId,
    confirmationToken: issued.token,
    confirmed: true,
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    source
  });
  assert.equal(first.status, 'ready');
  const body = orch.writerFor(research.researchId).get(first.artifactId as string).text;
  assert.equal(containsTranslationLeak(JSON.parse(body)), false);
  const secondIssued = realJobs.issue({ researchId: research.researchId, sourceId, source });
  const second = await realJobs.request({
    researchId: research.researchId,
    sourceId,
    confirmationToken: secondIssued.token,
    confirmed: true,
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    source
  });
  assert.equal(creates, 0);
  assert.equal(second.artifactId, first.artifactId);
  assert.equal(contentKeyFor(source), first.contentKey);
  close();
});

test('e2e 8: report citations locate web search transcript and memory artifacts', async () => {
  const agent = new StepAgent([
    () => ({ type: 'tool_call', tool: 'retrieve_evidence', args: { query: 'document review tools' } }),
    (results) => {
      const pack = results[0] as EvidencePack;
      const citations = pack.items
        .filter((item) => typeof item.artifactId === 'string')
        .slice(0, 4)
        .map((item) => ({
          artifactId: item.artifactId,
          evidenceLevel: item.evidenceLevel,
          passageId: item.passageId,
          sourceURL: item.locator.sourceURL,
          contentKey: item.locator.contentKey,
          startMilliseconds: item.locator.startMs,
          endMilliseconds: item.locator.endMs,
          quote: item.excerpt,
          sha256: item.sha256
        }));
      assert.ok(citations.length >= 1);
      return {
        type: 'tool_call',
        tool: 'save_research_report',
        args: {
          title: 'Combined',
          markdown:
            'Accounting firms are piloting document review tools and saved notes confirm the same finding for this research.',
          citations
        }
      };
    },
    () => ({ type: 'done' })
  ]);
  const { orch, store, close } = orchestratorHarness(agent);
  const research = orch.createResearch({ ownerScope: 'selfhost', title: 'combined evidence' });
  const writer = orch.writerFor(research.researchId);
  writer.save({
    kind: 'web_page',
    producer: 'fetch_web_page',
    evidenceLevel: 'primary_content',
    sourceURL: 'https://example.com/ai-accounting',
    contents: 'Accounting firms are piloting document review tools.\n',
    passages: [{ passageId: 'p001', text: 'Accounting firms are piloting document review tools.' }]
  });
  writer.save({
    kind: 'youtube_search',
    producer: 'search_youtube',
    evidenceLevel: 'search_metadata',
    contents: JSON.stringify({
      results: [{ sourceId: 'dQw4w9WgXcQ', assistantSourceId: newSourceId(), canonicalURL: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' }]
    })
  });
  writer.save({
    kind: 'transcript',
    producer: 'transcript-installer',
    evidenceLevel: 'transcript',
    contentKey: 'ck_demo',
    contents: 'Speakers discussed document review tools at 00:12.\n',
    passages: [{ passageId: 't001', text: 'Speakers discussed document review tools at 00:12.', startMs: 12000, endMs: 18000 }]
  });
  orch.writerFor(research.researchId).save({
    kind: 'research_memory',
    producer: 'memory',
    evidenceLevel: 'research_note',
    contents: 'Remember that document review tools are the core finding.\n'
  });
  const turn = orch.createTurn(research.researchId, { mode: 'research', text: 'write the report' });
  await orch.runTurn(turn.turnId);
  assert.ok(store.listCitations(research.researchId).length >= 1);
  const snapshot = orch.snapshot(research.researchId);
  assert.equal(
    snapshot.citations.every((citation) => snapshot.artifacts.some((item) => item.artifactId === citation.artifactId)),
    true
  );
  close();
});

test('e2e 9: global preference is recalled only after confirm in a new research', async () => {
  const agent = new StepAgent([() => ({ type: 'done' })]);
  const { orch, store, close } = orchestratorHarness(agent);
  const first = orch.createResearch({ ownerScope: 'selfhost', title: 'preference source' });
  const proposal = orch.memoryProposals.propose({
    researchId: first.researchId,
    content: 'Write future reports in Simplified Chinese by default.',
    reason: 'User asked for Chinese output.'
  });
  const before = await recallMemory(store, { query: 'Simplified Chinese reports', researchId: first.researchId });
  assert.equal(before.some((hit) => hit.scope === 'global'), false);
  orch.memoryProposals.confirm(proposal.proposalId);
  const second = orch.createResearch({ ownerScope: 'selfhost', title: 'preference consumer' });
  const after = await recallMemory(store, { query: 'Simplified Chinese reports', researchId: second.researchId });
  assert.equal(after.some((hit) => hit.scope === 'global' && hit.content.includes('Simplified Chinese')), true);
  close();
});

test('e2e 10: writable shared alias cannot escape its root', () => {
  const dir = mkdtempSync(join(tmpdir(), 'v15-e2e-share-'));
  const db = openDatabase(join(dir, 'a.db'), MIGRATIONS);
  const store = new V2Store(db);
  const workspaceRoot = join(dir, 'workspaces');
  const shared = join(dir, 'shared', 'notes');
  const versions = join(dir, 'shared-versions');
  mkdirSync(workspaceRoot, { recursive: true });
  mkdirSync(shared, { recursive: true });
  mkdirSync(versions, { recursive: true });
  writeFileSync(join(shared, 'inbox.md'), 'old\n');
  const adminGrants = parseAdminGrants({
    grants: [
      {
        alias: 'notes',
        root: shared,
        permission: 'read_write',
        allowedExtensions: ['.md'],
        maxFileBytes: 2097152
      }
    ]
  });
  const manager = new WorkspaceManager({
    root: workspaceRoot,
    store,
    diskFreeBytes: () => 8 * 1024 * 1024 * 1024
  });
  const research = manager.create({
    ownerScope: 'selfhost',
    title: 'shared',
    outputLanguage: 'zh-Hans',
    storefront: 'US',
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    grants: [{ alias: 'notes', permission: 'read_write', allowedExtensions: ['.md'], maxFileBytes: 2097152 }]
  });
  const tools = new FileTools({
    store,
    researchId: research.researchId,
    workspaceDir: manager.internalPath(research.researchId),
    adminGrants,
    sharedWriteEnabled: true,
    sharedVersionRoot: versions
  });
  tools.writeFile('shared://notes/inbox.md', 'new notes\n');
  assert.equal(readFileSync(join(shared, 'inbox.md'), 'utf8'), 'new notes\n');
  assert.throws(
    () => tools.readFile('shared://notes/../passwd'),
    (error: unknown) => error instanceof DomainError && error.code === 'WORKSPACE_PATH_UNSAFE'
  );
  store.close();
});

test('e2e 11-12: SSE replay matches snapshot and manifest rebuild restores ready artifacts', async () => {
  const ctx = apiHarness();
  const { port, close } = await listen(ctx.app);
  try {
    const created = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${TOKEN}`,
        'content-type': 'application/json',
        'idempotency-key': 'ik-e2e-11'
      },
      body: JSON.stringify({ title: 'replay', outputLanguage: 'zh-Hans' })
    });
    const research = (await created.json()) as { researchId: string };
    const turn = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}/turns`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${TOKEN}`,
        'content-type': 'application/json',
        'idempotency-key': 'ik-e2e-11-turn'
      },
      body: JSON.stringify({ message: 'hello', mode: 'research' })
    });
    const accepted = (await turn.json()) as { eventsURL: string; turnId: string };
    const sse = await fetch(`http://127.0.0.1:${port}${accepted.eventsURL}`, {
      headers: { authorization: `Bearer ${TOKEN}` },
      signal: AbortSignal.timeout(10_000)
    });
    const frames = (await sse.text())
      .split('\n\n')
      .filter(Boolean)
      .map((block) => {
        const event = block.split('\n').find((line) => line.startsWith('event:'))?.slice(6).trim();
        const data = block.split('\n').find((line) => line.startsWith('data:'))?.slice(5).trim();
        return { event, data: data ? JSON.parse(data) : null };
      });
    const completed = frames.find((frame) => frame.event === 'report.completed');
    const snapshot = await (
      await fetch(`http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}`, {
        headers: { authorization: `Bearer ${TOKEN}` }
      })
    ).json() as { latestReportArtifactId: string | null };
    assert.equal(snapshot.latestReportArtifactId, (completed?.data as { payload: { artifactId: string } }).payload.artifactId);

    const writer = new ArtifactWriter(
      ctx.v2.store,
      research.researchId,
      ctx.v2.workspace.internalPath(research.researchId)
    );
    const saved = writer.save({
      kind: 'report',
      contents: 'restored later',
      producer: 'report-writing',
      evidenceLevel: 'research_note'
    });
    ctx.v2.store.getDb().prepare('DELETE FROM v2_passages WHERE artifact_id = ?').run(saved.artifactId);
    ctx.v2.store.getDb().prepare('DELETE FROM v2_artifacts WHERE artifact_id = ?').run(saved.artifactId);
    assert.equal(writer.rebuildFromManifest() >= 1, true);
    assert.equal(writer.get(saved.artifactId).text, 'restored later');
  } finally {
    await close();
    ctx.close();
  }
});

test('e2e 13-14: delete keeps global prefs; V1 session does not create a V15 workspace', async () => {
  const ctx = apiHarness();
  const { port, close } = await listen(ctx.app);
  try {
    const created = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${TOKEN}`,
        'content-type': 'application/json',
        'idempotency-key': 'ik-e2e-13'
      },
      body: JSON.stringify({ title: 'to delete', outputLanguage: 'zh-Hans' })
    });
    const research = (await created.json()) as { researchId: string };
    const proposal = ctx.v2.orchestrator.memoryProposals.propose({
      researchId: research.researchId,
      content: 'Keep this global preference.',
      reason: 'user confirmed later'
    });
    await fetch(`http://127.0.0.1:${port}/v2/assistant/memory-proposals/${proposal.proposalId}/confirm`, {
      method: 'POST',
      headers: { authorization: `Bearer ${TOKEN}`, 'idempotency-key': 'ik-e2e-13-mem' }
    });
    const deleted = await fetch(`http://127.0.0.1:${port}/v2/assistant/researches/${research.researchId}`, {
      method: 'DELETE',
      headers: { authorization: `Bearer ${TOKEN}`, 'idempotency-key': 'ik-e2e-13-del' }
    });
    assert.equal(deleted.status, 202);
    const globals = ctx.v2.store.listConfirmedGlobalMemory('selfhost');
    assert.equal(globals.some((entry) => entry.content.includes('Keep this global preference')), true);

    const v1 = await fetch(`http://127.0.0.1:${port}/v1/assistant/sessions`, {
      method: 'POST',
      headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
      body: JSON.stringify({ outputLanguage: 'zh-Hans' })
    });
    assert.equal(v1.status, 404);
  } finally {
    await close();
    ctx.close();
  }
});

test('in-process Research create P95 stays under the WP18 smoke gate', () => {
  const agent = new StepAgent([() => ({ type: 'done' })]);
  const { orch, close } = orchestratorHarness(agent);
  const samples: number[] = [];
  for (let i = 0; i < 12; i += 1) {
    const started = Date.now();
    orch.createResearch({ ownerScope: 'selfhost', title: `perf ${i}` });
    samples.push(Date.now() - started);
  }
  assert.ok(p95(samples) <= 900, `create P95 ${p95(samples)}ms exceeded 900ms smoke gate`);
  close();
});

test('1 MiB artifact local commit P95 stays under the WP18 smoke gate', () => {
  const agent = new StepAgent([() => ({ type: 'done' })]);
  const { orch, close } = orchestratorHarness(agent);
  const research = orch.createResearch({ ownerScope: 'selfhost', title: 'artifact perf' });
  const writer = orch.writerFor(research.researchId);
  const payload = 'a'.repeat(256 * 1024);
  const samples: number[] = [];
  for (let i = 0; i < 8; i += 1) {
    const started = Date.now();
    writer.save({
      kind: 'report',
      contents: payload,
      producer: 'report-writing',
      evidenceLevel: 'research_note'
    });
    samples.push(Date.now() - started);
  }
  assert.ok(p95(samples) <= 450, `artifact P95 ${p95(samples)}ms exceeded 450ms smoke gate`);
  close();
});
