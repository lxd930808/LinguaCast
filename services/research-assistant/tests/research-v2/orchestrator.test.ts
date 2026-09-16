import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { RESEARCH_TOOLS, QA_TOOLS, FORBIDDEN_DEFAULT_TOOLS, type AgentEvent, type AgentRuntime } from '../../src/agent/runtime.js';
import { openDatabase } from '../../src/db/migrations.js';
import { V2Store } from '../../src/db/v2/store.js';
import { DomainError } from '../../src/domain/types.js';
import type { V10ContentClient } from '../../src/content/v10-client.js';
import type { EvidencePack } from '../../src/evidence/pack.js';
import { V2ResearchOrchestrator, type V2OrchestratorConfig } from '../../src/research-v2/orchestrator.js';
import type { V2MediaSearch } from '../../src/research-v2/tool-dispatch.js';
import { provisionalTitle, type SessionTitleGenerator } from '../../src/research-v2/session-title.js';
import { WorkspaceManager } from '../../src/workspace/manager.js';

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), '../../migrations');

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
      throw new Error('v10 create should not run without confirmation');
    },
    async get() {
      throw new Error('v10 get should not run');
    },
    async downloadSegments() {
      throw new Error('v10 download should not run');
    }
  };
  return client;
}

const mediaSearch: V2MediaSearch = {
  async searchYouTube() {
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
    return { hits: [] };
  }
};

function orchestratorHarness(
  agent: AgentRuntime,
  overrides: Partial<V2OrchestratorConfig> = {},
  extraDeps: { titleGenerator?: SessionTitleGenerator | null } = {}
) {
  const dir = mkdtempSync(join(tmpdir(), 'v2-orch-'));
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
  const orch = new V2ResearchOrchestrator({
    store,
    workspace,
    agent,
    v10,
    mediaSearch,
    titleGenerator: extraDeps.titleGenerator ?? null,
    config: {
      assistantWebEnabled: false,
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

test('V1 business tool sets stay frozen when V2 orchestration exists', () => {
  assert.deepEqual([...RESEARCH_TOOLS], [
    'search_youtube',
    'search_apple_podcasts',
    'get_podcast_feed_episodes',
    'read_search_results',
    'save_research_report'
  ]);
  assert.deepEqual([...QA_TOOLS], [
    'get_selected_source',
    'get_content_preparation_status',
    'search_current_transcript',
    'read_transcript_evidence',
    'save_grounded_answer'
  ]);
  assert.equal(FORBIDDEN_DEFAULT_TOOLS.includes('bash'), true);
});

test('research turns expose fetch, evidence, and report tools even from planning', async () => {
  let seen: string[] = [];
  const agent: AgentRuntime = {
    async *run(input) {
      seen = [...input.tools];
      yield { type: 'done' };
    }
  };
  const { orch, close } = orchestratorHarness(agent);
  const research = orch.createResearch({ ownerScope: 'selfhost', title: 'tool exposure' });
  const turn = orch.createTurn(research.researchId, { mode: 'research', text: 'OpenAI GPT6' });
  await orch.runTurn(turn.turnId);
  assert.equal(seen.includes('retrieve_evidence'), true);
  assert.equal(seen.includes('save_research_report'), true);
  assert.equal(seen.includes('search_youtube'), true);
  assert.equal(seen.includes('web_search'), false);
  assert.equal(seen.includes('fetch_web_page'), false);
  close();
});

test('research turns expose web tools when web research is enabled', async () => {
  let seen: string[] = [];
  const agent: AgentRuntime = {
    async *run(input) {
      seen = [...input.tools];
      yield { type: 'done' };
    }
  };
  const { orch, close } = orchestratorHarness(agent, { assistantWebEnabled: true });
  const research = orch.createResearch({ ownerScope: 'selfhost', title: 'web tools' });
  const turn = orch.createTurn(research.researchId, { mode: 'research', text: 'OpenAI GPT6' });
  await orch.runTurn(turn.turnId);
  assert.equal(seen.includes('web_search'), true);
  assert.equal(seen.includes('fetch_web_page'), true);
  assert.equal(seen.includes('retrieve_evidence'), true);
  assert.equal(seen.includes('save_research_report'), true);
  close();
});

test('tool whitelist is enforced during a turn and bash never runs', async () => {
  const agent = new StepAgent([
    () => ({ type: 'tool_call', tool: 'retrieve_evidence', args: { query: 'library weekends' } }),
    () => ({ type: 'tool_call', tool: 'web_search', args: { query: 'should be blocked' } }),
    () => ({ type: 'tool_call', tool: 'bash', args: { command: 'ls' } }),
    (results) => {
      const pack = results[0] as EvidencePack;
      const item = pack.items.find((row) => row.evidenceLevel === 'primary_content');
      assert.ok(item);
      return {
        type: 'tool_call',
        tool: 'save_research_report',
        args: {
          title: 'Library hours',
          markdown:
            'The library will stay open on weekends for students. This is grounded in the saved web page.',
          citations: [
            {
              artifactId: item.artifactId,
              evidenceLevel: item.evidenceLevel,
              passageId: item.passageId,
              sourceURL: item.locator.sourceURL,
              quote: item.excerpt,
              sha256: item.sha256
            }
          ]
        }
      };
    },
    () => ({ type: 'done' })
  ]);
  const { orch, store, close } = orchestratorHarness(agent);
  const research = orch.createResearch({ ownerScope: 'selfhost', title: 'whitelist' });
  orch.writerFor(research.researchId).save({
    kind: 'web_page',
    producer: 'fetch_web_page',
    evidenceLevel: 'primary_content',
    sourceURL: 'https://example.com/library-open',
    contents: 'The library will stay open on weekends for students.\n',
    passages: [{ passageId: 'p001', text: 'The library will stay open on weekends for students.' }]
  });
  const turn = orch.createTurn(research.researchId, { mode: 'research', text: 'library weekends' });
  const finished = await orch.runTurn(turn.turnId);
  assert.equal(finished.status, 'completed');
  const web = agent.results[1] as { ok?: boolean; error?: { code: string } };
  const bash = agent.results[2] as { ok?: boolean; error?: { code: string } };
  assert.equal(web.ok, false);
  assert.equal(web.error?.code, 'TOOL_NOT_ALLOWED');
  assert.equal(bash.ok, false);
  assert.equal(bash.error?.code, 'TOOL_NOT_ALLOWED');
  const report = store.listArtifacts(research.researchId, 'report', 'ready');
  assert.equal(report.length, 1);
  assert.ok(store.listCitations(research.researchId).length >= 1);
  close();
});

async function waitForTitle(
  store: V2Store,
  researchId: string,
  expected: string,
  timeoutMs = 500
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const title = store.getResearch(researchId)?.title ?? '';
    if (title === expected) return title;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  return store.getResearch(researchId)?.title ?? '';
}

test('first V2 research turn sets a provisional title from the user text', async () => {
  const agent = new StepAgent([() => ({ type: 'done' })]);
  const { orch, store, close } = orchestratorHarness(agent);
  const research = orch.createResearch({ ownerScope: 'selfhost' });
  assert.equal(research.title, 'Untitled research');
  const turn = orch.createTurn(research.researchId, { mode: 'research', text: '大模型的自进化' });
  await orch.runTurn(turn.turnId);
  assert.equal(store.getResearch(research.researchId)?.title, provisionalTitle('大模型的自进化'));
  const titled = store.listEvents(research.researchId).some((event) => event.type === 'research.title_updated');
  assert.equal(titled, true);
  close();
});

test('LLM title overwrites the provisional title on the first V2 turn', async () => {
  const agent = new StepAgent([() => ({ type: 'done' })]);
  const generator: SessionTitleGenerator = async () => '大模型自进化研究';
  const { orch, store, close } = orchestratorHarness(agent, {}, { titleGenerator: generator });
  const research = orch.createResearch({ ownerScope: 'selfhost' });
  const turn = orch.createTurn(research.researchId, { mode: 'research', text: '大模型的自进化怎么做' });
  await orch.runTurn(turn.turnId);
  assert.equal(await waitForTitle(store, research.researchId, '大模型自进化研究'), '大模型自进化研究');
  close();
});

test('auto-title never overwrites a user-provided research title', async () => {
  const agent = new StepAgent([() => ({ type: 'done' })]);
  const generator: SessionTitleGenerator = async () => 'Generated Title';
  const { orch, store, close } = orchestratorHarness(agent, {}, { titleGenerator: generator });
  const research = orch.createResearch({ ownerScope: 'selfhost', title: 'My Custom Title' });
  const turn = orch.createTurn(research.researchId, { mode: 'research', text: 'anything at all' });
  await orch.runTurn(turn.turnId);
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(store.getResearch(research.researchId)?.title, 'My Custom Title');
  close();
});

test('content_qa turns cannot call web or youtube search tools', async () => {
  const agent = new StepAgent([
    () => ({ type: 'tool_call', tool: 'search_youtube', args: { query: 'nope' } }),
    () => ({ type: 'tool_call', tool: 'web_search', args: { query: 'nope' } }),
    () => ({ type: 'done' })
  ]);
  const { orch, close } = orchestratorHarness(agent);
  const research = orch.createResearch({ ownerScope: 'selfhost', title: 'qa isolation' });
  const turn = orch.createTurn(research.researchId, { mode: 'content_qa', text: 'what did the source say?' });
  const finished = await orch.runTurn(turn.turnId);
  assert.equal(finished.status, 'completed');
  const youtube = agent.results[0] as { error?: { code: string } };
  const web = agent.results[1] as { error?: { code: string } };
  assert.equal(youtube.error?.code, 'TOOL_NOT_ALLOWED');
  assert.equal(web.error?.code, 'TOOL_NOT_ALLOWED');
  close();
});

test('request_transcription without a user confirmation token never calls V10', async () => {
  const agent = new StepAgent([
    () => ({ type: 'tool_call', tool: 'search_youtube', args: { query: 'ai accounting' } }),
    (results) => {
      const search = results[0] as { results: Array<{ sourceId: string }> };
      return {
        type: 'tool_call',
        tool: 'request_transcription',
        args: { sourceId: search.results[0]?.sourceId, confirmationToken: 'ct_forged_by_model' }
      };
    },
    () => ({ type: 'done' })
  ]);
  const { orch, v10, store, close } = orchestratorHarness(agent);
  const research = orch.createResearch({ ownerScope: 'selfhost', title: 'transcript confirm' });
  const turn = orch.createTurn(research.researchId, { mode: 'research', text: 'transcribe this' });
  await orch.runTurn(turn.turnId);
  const transcribe = agent.results[1] as { error?: { code: string } };
  assert.equal(transcribe.error?.code, 'TRANSCRIPT_CONFIRMATION_REQUIRED');
  assert.equal(v10.lookups, 0);
  assert.equal(v10.creates, 0);
  assert.equal(store.listTranscriptJobs(research.researchId).length, 0);
  close();
});

test('evidence pack citations are required for a completed report', async () => {
  const agent = new StepAgent([
    () => ({ type: 'tool_call', tool: 'retrieve_evidence', args: { query: 'library weekends' } }),
    (results) => {
      const pack = results[0] as EvidencePack;
      assert.ok(pack.items.length > 0);
      const item = pack.items[0]!;
      return {
        type: 'tool_call',
        tool: 'save_research_report',
        args: {
          title: 'Library',
          markdown: `${item.excerpt} The saved page is the locatable evidence for this claim.`,
          citations: [
            {
              artifactId: item.artifactId,
              evidenceLevel: item.evidenceLevel,
              passageId: item.passageId,
              sourceURL: item.locator.sourceURL,
              contentKey: item.locator.contentKey,
              quote: item.excerpt,
              sha256: item.sha256
            }
          ]
        }
      };
    },
    () => ({ type: 'done' })
  ]);
  const { orch, store, close } = orchestratorHarness(agent);
  const research = orch.createResearch({ ownerScope: 'selfhost', title: 'evidence report' });
  orch.writerFor(research.researchId).save({
    kind: 'web_page',
    producer: 'fetch_web_page',
    evidenceLevel: 'primary_content',
    sourceURL: 'https://example.com/library-open',
    contents: 'The library will stay open on weekends for students.\n',
    passages: [{ passageId: 'p001', text: 'The library will stay open on weekends for students.' }]
  });
  const turn = orch.createTurn(research.researchId, { mode: 'research', text: 'library weekends' });
  await orch.runTurn(turn.turnId);
  const events = store.eventsSince(turn.turnId, 0);
  const completed = events.filter((event) => event.type === 'report.completed');
  const deltas = events.filter((event) => event.type === 'report.delta');
  assert.equal(completed.length, 1);
  const report = store.listArtifacts(research.researchId, 'report', 'ready')[0];
  assert.ok(report);
  assert.equal(report.status, 'ready');
  const payload = completed[0]?.payload as { artifactId: string; citationCount: number };
  assert.equal(payload.artifactId, report.artifactId);
  assert.ok(payload.citationCount >= 1);
  assert.equal(store.listCitations(research.researchId).length, payload.citationCount);
  const snapshot = orch.snapshot(research.researchId);
  assert.equal(snapshot.artifacts.some((item) => item.artifactId === report.artifactId && item.kind === 'report'), true);
  assert.equal(
    snapshot.messages.some((message) => message.role === 'assistant' && message.markdown.includes('library')),
    true
  );
  assert.ok(deltas.every((event) => event.type === 'report.delta'));
  close();
});

test('research memory written in one research is not recalled in another', async () => {
  const agentA = new StepAgent([
    () => ({
      type: 'tool_call',
      tool: 'write_research_memory',
      args: { type: 'finding', content: 'Secret accounting notes unique to research A.' }
    }),
    () => ({ type: 'done' })
  ]);
  const { orch, store, workspace, close } = orchestratorHarness(agentA);
  const a = orch.createResearch({ ownerScope: 'selfhost', title: 'memory-a' });
  const b = orch.createResearch({ ownerScope: 'selfhost', title: 'memory-b' });
  const turnA = orch.createTurn(a.researchId, { mode: 'research', text: 'remember this' });
  await orch.runTurn(turnA.turnId);
  assert.ok(store.listMemoryEntries(a.researchId).some((entry) => entry.content.includes('Secret accounting')));

  const agentB = new StepAgent([
    () => ({ type: 'tool_call', tool: 'retrieve_evidence', args: { query: 'Secret accounting notes' } }),
    () => ({ type: 'done' })
  ]);
  const orchB = new V2ResearchOrchestrator({
    store,
    workspace,
    agent: agentB,
    v10: countingV10(),
    mediaSearch,
    config: {
      assistantWebEnabled: false,
      sharedWriteEnabled: false,
      rgPath: 'rg',
      maxGrepMatches: 200,
      maxGrepMs: 5000,
      globalMemoryRoot: join(workspace.root, '..', 'global-memory'),
      sharedVersionRoot: join(workspace.root, '..', 'shared-versions')
    }
  });
  const turnB = orchB.createTurn(b.researchId, { mode: 'research', text: 'what do we know?' });
  await orchB.runTurn(turnB.turnId);
  const pack = agentB.results[0] as EvidencePack;
  assert.equal(pack.items.some((item) => item.excerpt.includes('Secret accounting')), false);
  assert.equal(store.listMemoryEntries(b.researchId).length, 0);
  close();
});

test('single active turn, cancel, interrupted retry, and delete keep global memory', async () => {
  const agent = new StepAgent([() => ({ type: 'done' })]);
  const { orch, store, close } = orchestratorHarness(agent);
  const research = orch.createResearch({ ownerScope: 'selfhost', title: 'lifecycle' });
  const first = orch.createTurn(research.researchId, { mode: 'research', text: 'first' });
  assert.throws(
    () => orch.createTurn(research.researchId, { mode: 'research', text: 'second' }),
    (error: unknown) => error instanceof DomainError && error.code === 'TURN_ALREADY_RUNNING'
  );
  const cancelled = orch.cancelTurn(first.turnId);
  assert.equal(cancelled.status, 'cancelled');

  const queued = orch.createTurn(research.researchId, { mode: 'research', text: 'retry me' });
  store.setTurnStatus(queued.turnId, 'queued', 'running');
  const interrupted = orch.interruptTurn(queued.turnId);
  assert.equal(interrupted.status, 'interrupted');
  const retried = orch.retryTurn(queued.turnId);
  assert.equal(retried.status, 'queued');
  await orch.runTurn(retried.turnId);

  const other = orch.createResearch({ ownerScope: 'selfhost', title: 'keep-global' });
  const proposal = orch.memoryProposals.propose({
    researchId: research.researchId,
    content: 'Prefer slow-speech sources',
    reason: 'user preference'
  });
  const confirmed = orch.memoryProposals.confirm(proposal.proposalId);
  orch.deleteResearch(research.researchId);
  assert.equal(store.getResearch(research.researchId), null);
  assert.equal(store.getResearch(other.researchId)?.status, 'ready');
  assert.equal(store.getMemoryEntry(confirmed.memoryEntryId)?.scope, 'global');
  assert.equal(store.getMemoryEntry(confirmed.memoryEntryId)?.status, 'confirmed');
  close();
});

test('YouTube search during a V2 turn persists a search artifact for the same research only', async () => {
  const agent = new StepAgent([
    () => ({ type: 'tool_call', tool: 'search_youtube', args: { query: 'ai accounting' } }),
    () => ({ type: 'done' })
  ]);
  const { orch, store, close } = orchestratorHarness(agent);
  const a = orch.createResearch({ ownerScope: 'selfhost', title: 'search-a' });
  const b = orch.createResearch({ ownerScope: 'selfhost', title: 'search-b' });
  const turn = orch.createTurn(a.researchId, { mode: 'research', text: 'find videos' });
  await orch.runTurn(turn.turnId);
  const searchA = store.listArtifacts(a.researchId, 'youtube_search', 'ready');
  const searchB = store.listArtifacts(b.researchId, 'youtube_search', 'ready');
  assert.equal(searchA.length, 1);
  assert.equal(searchB.length, 0);
  const events = store.eventsSince(turn.turnId, 0);
  assert.equal(events.some((event) => event.type === 'source.saved'), true);
  assert.equal(events.some((event) => event.type === 'workspace.created'), true);
  const body = JSON.parse(orch.writerFor(a.researchId).get(searchA[0]!.artifactId).text) as {
    results: Array<{ sourceId: string; assistantSourceId?: string; nativeSourceId?: string }>;
  };
  assert.match(body.results[0]?.assistantSourceId ?? '', /^so_[0-9A-HJKMNP-TV-Z]{26}$/);
  assert.equal(body.results[0]?.nativeSourceId ?? body.results[0]?.sourceId, 'dQw4w9WgXcQ');
  close();
});

test('thinking streams and tool.started precedes source.saved for a search tool', async () => {
  const agent = new StepAgent([
    () => ({ type: 'thinking', thinking: { stage: 'start', blockId: 'th_0' } }),
    () => ({ type: 'thinking', thinking: { stage: 'delta', blockId: 'th_0', text: 'I should search YouTube first.' } }),
    () => ({ type: 'thinking', thinking: { stage: 'end', blockId: 'th_0', durationMs: 1500 } }),
    () => ({ type: 'tool_call', tool: 'search_youtube', args: { query: 'ai accounting' } }),
    () => ({ type: 'done' })
  ]);
  const { orch, store, close } = orchestratorHarness(agent);
  const research = orch.createResearch({ ownerScope: 'selfhost', title: 'thinking order' });
  const turn = orch.createTurn(research.researchId, { mode: 'research', text: 'find videos' });
  await orch.runTurn(turn.turnId);
  const types = store.eventsSince(turn.turnId, 0).map((event) => event.type);
  assert.equal(types.indexOf('thinking.started') < types.indexOf('thinking.delta'), true);
  assert.equal(types.indexOf('thinking.delta') < types.indexOf('thinking.completed'), true);
  assert.equal(types.indexOf('tool.started') < types.indexOf('source.saved'), true);
  assert.equal(types.indexOf('source.saved') < types.indexOf('tool.completed'), true);
  const toolStarted = store
    .eventsSince(turn.turnId, 0)
    .find((event) => event.type === 'tool.started') as unknown as { payload: Record<string, unknown> };
  assert.equal(toolStarted.payload.tool, 'search_youtube');
  assert.equal(toolStarted.payload.query, 'ai accounting');
  close();
});
