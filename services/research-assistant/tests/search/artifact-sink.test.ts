import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { ArtifactWriterSearchSink } from '../../src/artifacts/search-sink.js';
import { ArtifactWriter } from '../../src/artifacts/writer.js';
import { openDatabase } from '../../src/db/migrations.js';
import { V2Store } from '../../src/db/v2/store.js';
import { isId } from '../../src/domain/ids.js';
import { DomainError } from '../../src/domain/types.js';
import { MemorySearchCache } from '../../src/search/cache.js';
import type { NormalizedSearchHit, SearchPlan } from '../../src/search/contracts.js';
import { SearchOrchestrator } from '../../src/search/orchestrator.js';
import type { SearchArtifactSink, SearchRunDocument } from '../../src/search/artifact-sink.js';
import type { PodcastSearchOrchestrator } from '../../src/search/podcast/orchestrator.js';
import type { YouTubeDataApiProvider } from '../../src/search/youtube/data-api.js';
import type { YtDlpSearchProvider } from '../../src/search/youtube/ytdlp-discovery.js';
import { WorkspaceManager } from '../../src/workspace/manager.js';

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), '../../migrations');

function youtubeHit(id: string, title: string): NormalizedSearchHit {
  return {
    platform: 'youtube',
    sourceType: 'video',
    sourceId: id,
    canonicalURL: `https://www.youtube.com/watch?v=${id}`,
    title,
    publisher: 'Channel',
    publishedAt: '2026-01-15T00:00:00Z',
    durationSeconds: 600,
    description: 'provider secret KEY-123 must not be persisted',
    provider: 'ytdlp',
    provenance: { title: 'ytdlp', apiKey: 'KEY-123' },
    deepResearchAvailability: 'available',
    warnings: []
  };
}

function podcastHit(): NormalizedSearchHit {
  return {
    platform: 'podcast',
    sourceType: 'podcast_episode',
    sourceId: 'ep-1',
    canonicalURL: 'https://podcasts.apple.com/episode/id9',
    title: 'Episode 9',
    publishedAt: '2026-01-15T00:00:00Z',
    provider: 'apple_search',
    provenance: { title: 'apple_search' },
    deepResearchAvailability: 'available',
    warnings: [],
    feedURL: 'https://feeds.example.test/show.xml',
    enclosureUrl: 'https://cdn.example.test/9.mp3'
  };
}

function plan(overrides: Partial<SearchPlan> = {}): SearchPlan {
  return {
    intent: 'topic',
    media: ['youtube'],
    queries: ['accounting'],
    person: null,
    showOrChannel: null,
    language: 'en',
    region: 'US',
    publishedAfter: null,
    publishedBefore: null,
    duration: 'any',
    clean: true,
    ...overrides
  };
}

function fakeYoutube(handler: () => Promise<NormalizedSearchHit[]>): YtDlpSearchProvider {
  return {
    name: 'ytdlp',
    discover: async () => handler(),
    search: async () => handler(),
    details: async () => null
  } as unknown as YtDlpSearchProvider;
}

function recordingSink(): { sink: SearchArtifactSink; documents: SearchRunDocument[] } {
  const documents: SearchRunDocument[] = [];
  return {
    documents,
    sink: {
      persist(document) {
        documents.push(document);
        return { artifactId: document.runId };
      }
    }
  };
}

function orchestrator(input: {
  youtube?: YtDlpSearchProvider;
  youtubeApi?: YouTubeDataApiProvider | null;
  podcast?: PodcastSearchOrchestrator | null;
  artifactSink?: SearchArtifactSink;
}): SearchOrchestrator {
  return new SearchOrchestrator({
    youtube: input.youtube ?? fakeYoutube(async () => [youtubeHit('dQw4w9WgXcQ', 'AI accounting')]),
    youtubeApi: input.youtubeApi ?? null,
    podcast: input.podcast ?? null,
    cache: new MemorySearchCache(),
    searchV2: false,
    hydrationEnabled: false,
    successTtlMs: 30 * 60 * 1000,
    emptyTtlMs: 5 * 60 * 1000,
    artifactSink: input.artifactSink
  });
}

function workspaceHarness() {
  const dir = mkdtempSync(join(tmpdir(), 'search-sink-'));
  const db = openDatabase(join(dir, 'a.db'), MIGRATIONS);
  const store = new V2Store(db);
  const workspaceRoot = join(dir, 'workspaces');
  mkdirSync(workspaceRoot);
  const manager = new WorkspaceManager({
    root: workspaceRoot,
    store,
    diskFreeBytes: () => 8 * 1024 * 1024 * 1024
  });
  const research = manager.create({
    ownerScope: 'selfhost',
    title: 'search sink',
    outputLanguage: 'zh-Hans',
    storefront: 'US',
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality'
  });
  const writer = new ArtifactWriter(store, research.researchId, manager.internalPath(research.researchId));
  return { store, research, writer, close: () => store.close() };
}

test('omitted sink leaves V1 search behavior unchanged', async () => {
  const { documents, sink } = recordingSink();
  const withoutSink = orchestrator({});
  const outcome = await withoutSink.search(plan(), 5);
  assert.equal(outcome.hits.length, 1);
  assert.equal(outcome.hits[0]?.sourceId, 'dQw4w9WgXcQ');
  assert.equal(outcome.providerStatus[0]?.provider, 'ytdlp');
  const withSinkNoContext = orchestrator({ artifactSink: sink });
  await withSinkNoContext.search(plan(), 5);
  assert.equal(documents.length, 0);
});

test('youtube success empty and failure each persist one run document', async () => {
  const { documents, sink } = recordingSink();
  const context = { researchId: '01ARZ3NDEKTSV4RRFFQ69G5FAV', turnId: 'vt_01ARZ3NDEKTSV4RRFFQ69G5FB0' };
  const success = orchestrator({
    youtube: fakeYoutube(async () => [youtubeHit('dQw4w9WgXcQ', 'AI accounting')]),
    artifactSink: sink
  });
  await success.search(plan(), 5, undefined, context);
  const empty = orchestrator({
    youtube: fakeYoutube(async () => []),
    artifactSink: sink
  });
  await empty.search(plan({ queries: ['empty'] }), 5, undefined, context);
  const failure = orchestrator({
    youtube: fakeYoutube(async () => {
      throw new DomainError('YTDLP_INVALID_OUTPUT', 'provider secret KEY-123', true, 503);
    }),
    artifactSink: sink
  });
  await failure.search(plan({ queries: ['boom'] }), 5, undefined, context);
  assert.equal(documents.length, 3);
  assert.equal(documents[0]?.status, 'success');
  assert.equal(documents[0]?.platform, 'youtube');
  assert.equal(documents[0]?.query, 'accounting');
  assert.equal(isId('srun', documents[0]!.runId), true);
  assert.equal(documents[0]?.results[0]?.sourceId, 'dQw4w9WgXcQ');
  assert.equal(documents[0]?.error, null);
  assert.equal(JSON.stringify(documents[0]).includes('KEY-123'), false);
  assert.equal(documents[1]?.status, 'empty');
  assert.equal(documents[1]?.results.length, 0);
  assert.equal(documents[2]?.status, 'failure');
  assert.equal(documents[2]?.error?.code, 'YTDLP_INVALID_OUTPUT');
});

test('unavailable provider with hits is partial and parent run is recorded', async () => {
  const { documents, sink } = recordingSink();
  const api = {
    searchWithPlan: async () => {
      throw new DomainError('YOUTUBE_QUOTA_EXCEEDED', 'quota KEY-123', true, 429);
    }
  } as unknown as YouTubeDataApiProvider;
  const search = orchestrator({
    youtube: fakeYoutube(async () => [youtubeHit('dQw4w9WgXcQ', 'AI accounting')]),
    youtubeApi: api,
    artifactSink: sink
  });
  const dated = plan({ publishedAfter: '2026-01-01T00:00:00Z' });
  await search.search(dated, 5, undefined, {
    researchId: '01ARZ3NDEKTSV4RRFFQ69G5FAV',
    turnId: 'vt_01ARZ3NDEKTSV4RRFFQ69G5FB0',
    parentRunId: 'srun_01ARZ3NDEKTSV4RRFFQ69G5FC0'
  });
  assert.equal(documents.length, 1);
  assert.equal(documents[0]?.status, 'partial');
  assert.equal(documents[0]?.parentRunId, 'srun_01ARZ3NDEKTSV4RRFFQ69G5FC0');
  assert.equal(documents[0]?.providerStatus.some((row) => row.status === 'rate_limited'), true);
  assert.equal(documents[0]?.results.length, 1);
});

test('writer sink stores youtube and podcast artifacts as search_metadata', async () => {
  const { store, research, writer, close } = workspaceHarness();
  const sink = new ArtifactWriterSearchSink((researchId) => (researchId === research.researchId ? writer : null));
  const podcast = {
    search: async () => ({
      hits: [podcastHit()],
      ranked: [],
      providerStatus: [{ provider: 'apple_search', status: 'success' as const, acceptedCount: 1 }],
      warnings: []
    })
  } as unknown as PodcastSearchOrchestrator;
  const search = orchestrator({
    youtube: fakeYoutube(async () => [youtubeHit('dQw4w9WgXcQ', 'AI accounting')]),
    podcast,
    artifactSink: sink
  });
  const both = plan({ media: ['youtube', 'podcast'] });
  await search.search(both, 5, undefined, { researchId: research.researchId, turnId: null });
  const youtubeRuns = store.listArtifacts(research.researchId, 'youtube_search');
  const podcastRuns = store.listArtifacts(research.researchId, 'podcast_search');
  assert.equal(youtubeRuns.length, 1);
  assert.equal(podcastRuns.length, 1);
  assert.equal(youtubeRuns[0]?.evidenceLevel, 'search_metadata');
  assert.equal(podcastRuns[0]?.evidenceLevel, 'search_metadata');
  const body = writer.get(youtubeRuns[0]!.artifactId);
  assert.match(body.text, /dQw4w9WgXcQ/);
  assert.equal(body.text.includes('KEY-123'), false);
  assert.equal(body.evidenceLevel, 'search_metadata');
  const podcastBody = JSON.parse(writer.get(podcastRuns[0]!.artifactId).text) as {
    results: Array<{ feedURL?: string | null; enclosureUrl?: string | null; sourceType?: string }>;
  };
  assert.equal(podcastBody.results[0]?.sourceType, 'podcast_episode');
  assert.equal(podcastBody.results[0]?.feedURL, 'https://feeds.example.test/show.xml');
  assert.equal(podcastBody.results[0]?.enclosureUrl, 'https://cdn.example.test/9.mp3');
  close();
});
