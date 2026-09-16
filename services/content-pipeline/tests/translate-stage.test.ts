import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { openDatabase } from '../src/jobs/migrations.js';
import { JobStore } from '../src/jobs/job-store.js';
import { PipelineJobError } from '../src/jobs/worker.js';
import { RedactingLogger } from '../src/observability/logger.js';
import { podcastContentKey } from '../src/domain/content-key.js';
import {
  TranslationProviderError,
  type TranslationChatCall,
  type TranslationProvider
} from '../src/providers/translation/types.js';
import { runTranslationStage } from '../src/pipeline/translation/translate-stage.js';
import { canonicalFingerprint } from '../src/pipeline/asr-stage.js';
import type { LearningSegment } from '../src/pipeline/segmentation/types.js';

// Translation stage tests (WP6): a scripted fake provider proves batch
// planning, content retries, per-line fallback, checkpoint resume and stable
// error mapping without any network. Handlers dispatch on prompt content
// (never call order) because batches run concurrently.

const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url).pathname;

const SEGMENTS: LearningSegment[] = Array.from({ length: 12 }, (_, i) => ({
  sequence: i + 1,
  startMS: i * 2000,
  endMS: i * 2000 + 1500,
  text: `Sentence number ${i + 1} about libraries.`,
  learningText: `Sentence number ${i + 1} about libraries.`,
  translation: '',
  notes: '',
  words: [],
  timingSource: 'wordTimeline'
}));

const SOURCE_FINGERPRINT = `audiofp0:${canonicalFingerprint(SEGMENTS)}`;

type CallKind = 'context' | 'batch' | 'single';

interface RecordedCall {
  kind: CallKind;
  systemPrompt: string;
  userPrompt: string;
}

function classify(call: TranslationChatCall): CallKind {
  if (call.systemPrompt.startsWith('You analyze an English podcast transcript')) return 'context';
  if (call.systemPrompt.startsWith('You are translating one English podcast transcript line')) {
    return 'single';
  }
  return 'batch';
}

type Handler = (call: TranslationChatCall) => string | Error | undefined | Promise<string | Error | undefined>;

/** Default behavior: context → JSON summary; batch/single → valid numbered JSON. */
class ScriptedProvider implements TranslationProvider {
  readonly name = 'fake';
  readonly model = 'fake-model';
  calls: RecordedCall[] = [];
  onContext: Handler | null = null;
  onBatch: Handler | null = null;
  onSingle: Handler | null = null;

  async chatCompletion(call: TranslationChatCall): Promise<string> {
    const kind = classify(call);
    this.calls.push({ kind, systemPrompt: call.systemPrompt, userPrompt: call.userPrompt });
    const handler =
      kind === 'context' ? this.onContext : kind === 'batch' ? this.onBatch : this.onSingle;
    const override = await handler?.(call);
    if (override instanceof Error) throw override;
    if (typeof override === 'string') return override;
    if (kind === 'context') {
      return JSON.stringify({
        summary: 'A show about libraries.',
        terms: [{ source: 'library', target: '图书馆', note: '' }]
      });
    }
    if (kind === 'single') {
      const { text } = JSON.parse(call.userPrompt) as { id: number; text: string };
      return JSON.stringify({ origin: text, direct: `译:${text}` });
    }
    const entries: Record<string, unknown> = {};
    for (const line of call.userPrompt.split('\n')) {
      const match = /^(\d+)\.\s(.*)$/.exec(line);
      if (match) entries[match[1]] = { origin: match[2], direct: `译:${match[2]}` };
    }
    return JSON.stringify(entries);
  }
}

interface Fixture {
  tempRoot: string;
  store: JobStore;
  jobId: string;
  cleanup: () => Promise<void>;
}

async function setup(options?: { quality?: 'fast' | 'quality' }): Promise<Fixture> {
  const tempRoot = await mkdtemp(join(tmpdir(), 'translate-stage-test-'));
  const db = openDatabase(join(tempRoot, 'content.db'), MIGRATIONS_DIR);
  const store = new JobStore(db);
  const { job } = store.createJob({
    ownerScope: 'test-owner',
    contentType: 'podcast_episode',
    contentKey: podcastContentKey('https://example.com/feed.xml', 'ep-300'),
    source: { platform: 'rss', sourceId: 'ep-300', url: 'https://media.example.com/ep.mp3' },
    sourceLanguage: 'en',
    targetLanguage: 'zh-Hans',
    translationQuality: options?.quality ?? 'fast',
    pipelineVersion: 'v10.1',
    clientArtifactSchemaVersion: 1
  });
  // Seed the upstream ASR checkpoint the stage consumes.
  store.recordCheckpoint(job.jobId, {
    stage: 'transcribing',
    inputFingerprint: 'audiofp',
    output: {
      sourceFingerprint: SOURCE_FINGERPRINT,
      rawTranscriptKey: null,
      segments: SEGMENTS
    },
    schemaVersion: 1,
    reusable: true
  });
  return {
    tempRoot,
    store,
    jobId: job.jobId,
    cleanup: async () => {
      store.close();
      await rm(tempRoot, { recursive: true, force: true });
    }
  };
}

function makeHooks(store: JobStore, jobId: string) {
  return {
    updateProgress: (u: Parameters<JobStore['updateProgress']>[1]) => store.updateProgress(jobId, u),
    heartbeat: () => {},
    signal: new AbortController().signal
  };
}

function claimedJob(store: JobStore) {
  const job = store.claimNextJob('test-worker', 60_000);
  assert.ok(job, 'expected a claimable job');
  return job;
}

test('happy path: context once, batches planned, translations merged', async () => {
  const fx = await setup();
  try {
    const job = claimedJob(fx.store);
    const provider = new ScriptedProvider();
    const result = await runTranslationStage(
      job,
      { store: fx.store, logger: new RedactingLogger(), provider },
      makeHooks(fx.store, fx.jobId)
    );
    assert.equal(result.translatedCount, 12);
    assert.equal(result.segments.length, 12);
    assert.equal(result.segments[0].translation, '译:Sentence number 1 about libraries.');
    assert.equal(result.context.topicSummary, 'A show about libraries.');
    // 12 short segments: batches of 10 + 2 (item cap).
    const batchCalls = provider.calls.filter((c) => c.kind === 'batch');
    assert.equal(batchCalls.length, 2);
    assert.equal(provider.calls.filter((c) => c.kind === 'context').length, 1);
    // Durable checkpoint holds every translation.
    const checkpoints = fx.store.reusableCheckpoints(fx.jobId);
    const translating = checkpoints.find((c) => c.stage === 'translating');
    const output = translating?.output as { translations: Record<string, string>; context: unknown };
    assert.equal(Object.keys(output.translations).length, 12);
    assert.ok(output.context);
  } finally {
    await fx.cleanup();
  }
});

test('quality mode publishes the final reflective field', async () => {
  const fx = await setup({ quality: 'quality' });
  try {
    const job = claimedJob(fx.store);
    const provider = new ScriptedProvider();
    provider.onBatch = (call) => {
      const entries: Record<string, unknown> = {};
      for (const line of call.userPrompt.split('\n')) {
        const match = /^(\d+)\.\s(.*)$/.exec(line);
        if (match) {
          entries[match[1]] = {
            origin: match[2],
            direct: 'direct-ignored',
            reflection: 'note',
            final: `终译:${match[1]}`
          };
        }
      }
      return JSON.stringify(entries);
    };
    const result = await runTranslationStage(
      job,
      { store: fx.store, logger: new RedactingLogger(), provider },
      makeHooks(fx.store, fx.jobId)
    );
    assert.equal(result.segments[0].translation, '终译:1');
    assert.equal(result.segments[10].translation, '终译:11');
  } finally {
    await fx.cleanup();
  }
});

test('a batch that never validates falls back to per-line translation', async () => {
  const fx = await setup();
  try {
    const job = claimedJob(fx.store);
    const provider = new ScriptedProvider();
    // Batch 0 (starts at sequence 1) is malformed on every attempt; the
    // strict key-set check rejects it, so all 10 lines go through the
    // per-line fallback (which the default handler answers).
    provider.onBatch = (call) => (call.userPrompt.startsWith('1.') ? 'not json at all' : undefined);
    const result = await runTranslationStage(
      job,
      { store: fx.store, logger: new RedactingLogger(), provider },
      makeHooks(fx.store, fx.jobId)
    );
    assert.equal(result.segments[0].translation, '译:Sentence number 1 about libraries.');
    assert.equal(result.segments[9].translation, '译:Sentence number 10 about libraries.');
    const singleCalls = provider.calls.filter((c) => c.kind === 'single');
    assert.equal(singleCalls.length, 10);
    assert.deepEqual(JSON.parse(singleCalls[0].userPrompt), { id: 1, text: SEGMENTS[0].text });
    // Batch 0 retried 3 times; batch 1 succeeded on the first attempt.
    assert.equal(provider.calls.filter((c) => c.kind === 'batch').length, 4);
  } finally {
    await fx.cleanup();
  }
});

test('a batch that never validates fails TRANSLATION_FAILED retryable', async () => {
  const fx = await setup();
  try {
    const job = claimedJob(fx.store);
    const provider = new ScriptedProvider();
    provider.onBatch = () => '{"1":{"origin":"wrong","direct":"x"}}';
    provider.onSingle = () => '{"origin":"wrong","direct":"x"}';
    await assert.rejects(
      runTranslationStage(
        job,
        { store: fx.store, logger: new RedactingLogger(), provider },
        makeHooks(fx.store, fx.jobId)
      ),
      (error: unknown) => {
        assert.ok(error instanceof PipelineJobError);
        assert.equal(error.jobError.code, 'TRANSLATION_FAILED');
        assert.equal(error.jobError.retryable, true);
        assert.equal(error.jobError.failedStage, 'translating');
        return true;
      }
    );
  } finally {
    await fx.cleanup();
  }
});

test('provider errors map to TRANSLATION_FAILED with retryAfterSeconds', async () => {
  const fx = await setup();
  try {
    const job = claimedJob(fx.store);
    const provider = new ScriptedProvider();
    provider.onBatch = () =>
      new TranslationProviderError('rate limited', {
        retryable: true,
        status: 429,
        retryAfterSeconds: 42
      });
    await assert.rejects(
      runTranslationStage(
        job,
        { store: fx.store, logger: new RedactingLogger(), provider },
        makeHooks(fx.store, fx.jobId)
      ),
      (error: unknown) => {
        assert.ok(error instanceof PipelineJobError);
        assert.equal(error.jobError.code, 'TRANSLATION_FAILED');
        assert.equal(error.jobError.retryAfterSeconds, 42);
        return true;
      }
    );
  } finally {
    await fx.cleanup();
  }
});

test('context extraction failure degrades to empty context', async () => {
  const fx = await setup();
  try {
    const job = claimedJob(fx.store);
    const provider = new ScriptedProvider();
    provider.onContext = () => new TranslationProviderError('boom', { retryable: true });
    const result = await runTranslationStage(
      job,
      { store: fx.store, logger: new RedactingLogger(), provider },
      makeHooks(fx.store, fx.jobId)
    );
    assert.equal(result.context.topicSummary, '');
    assert.equal(result.translatedCount, 12);
  } finally {
    await fx.cleanup();
  }
});

test('restart resumes from checkpoint: only missing batches re-run', async () => {
  const fx = await setup();
  try {
    const job = claimedJob(fx.store);
    // Simulate a crash after the first batch: checkpoint with translations
    // for sequences 1-10 plus the extracted context.
    const translations: Record<string, string> = {};
    for (let i = 1; i <= 10; i += 1) translations[String(i)] = `旧译:${i}`;
    fx.store.recordCheckpoint(fx.jobId, {
      stage: 'translating',
      inputFingerprint: SOURCE_FINGERPRINT,
      output: {
        schemaVersion: 1,
        sourceFingerprint: SOURCE_FINGERPRINT,
        context: { topicSummary: 'cached topic', terms: [] },
        translations
      },
      schemaVersion: 1,
      reusable: true
    });
    const provider = new ScriptedProvider();
    const result = await runTranslationStage(
      job,
      { store: fx.store, logger: new RedactingLogger(), provider },
      makeHooks(fx.store, fx.jobId)
    );
    // Sequences 1-10 keep the checkpointed translations; 11-12 are new.
    assert.equal(result.segments[0].translation, '旧译:1');
    assert.equal(result.segments[10].translation, '译:Sentence number 11 about libraries.');
    // Context came from the checkpoint — no extraction call, one batch only.
    assert.equal(provider.calls.filter((c) => c.kind === 'context').length, 0);
    assert.equal(provider.calls.filter((c) => c.kind === 'batch').length, 1);
  } finally {
    await fx.cleanup();
  }
});

test('fully checkpointed translation skips the provider entirely', async () => {
  const fx = await setup();
  try {
    const job = claimedJob(fx.store);
    const translations: Record<string, string> = {};
    for (let i = 1; i <= 12; i += 1) translations[String(i)] = `旧译:${i}`;
    fx.store.recordCheckpoint(fx.jobId, {
      stage: 'translating',
      inputFingerprint: SOURCE_FINGERPRINT,
      output: {
        schemaVersion: 1,
        sourceFingerprint: SOURCE_FINGERPRINT,
        context: { topicSummary: 'cached', terms: [] },
        translations
      },
      schemaVersion: 1,
      reusable: true
    });
    const provider = new ScriptedProvider();
    const result = await runTranslationStage(
      job,
      { store: fx.store, logger: new RedactingLogger(), provider },
      makeHooks(fx.store, fx.jobId)
    );
    assert.equal(result.reusedCheckpoint, true);
    assert.equal(provider.calls.length, 0);
    assert.equal(result.segments[11].translation, '旧译:12');
  } finally {
    await fx.cleanup();
  }
});

test('missing ASR checkpoint is an internal error', async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), 'translate-stage-test-'));
  const db = openDatabase(join(tempRoot, 'content.db'), MIGRATIONS_DIR);
  const store = new JobStore(db);
  try {
    store.createJob({
      ownerScope: 'test-owner',
      contentType: 'podcast_episode',
      contentKey: podcastContentKey('https://example.com/feed.xml', 'ep-301'),
      source: { platform: 'rss', sourceId: 'ep-301', url: 'https://media.example.com/ep.mp3' },
      sourceLanguage: 'en',
      targetLanguage: 'zh-Hans',
      translationQuality: 'fast',
      pipelineVersion: 'v10.1',
      clientArtifactSchemaVersion: 1
    });
    const claimed = store.claimNextJob('test-worker', 60_000);
    assert.ok(claimed);
    await assert.rejects(
      runTranslationStage(
        claimed,
        { store, logger: new RedactingLogger(), provider: new ScriptedProvider() },
        makeHooks(store, claimed.jobId)
      ),
      (error: unknown) => {
        assert.ok(error instanceof PipelineJobError);
        assert.equal(error.jobError.code, 'INTERNAL_ERROR');
        return true;
      }
    );
  } finally {
    store.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});


test('partial batch retries only rejected rows and preserves good translations', async () => {
  const fx = await setup();
  try {
    const provider = new ScriptedProvider();
    const logs: string[] = [];
    provider.onBatch = (call) => {
      const entries: Record<string, unknown> = {};
      for (const line of call.userPrompt.split('\n')) {
        const match = /^(\d+)\.\s(.*)$/.exec(line)!;
        entries[match[1]] = { origin: match[1] === '2' ? 'wrong' : match[2], direct: `batch:${match[1]}` };
      }
      return JSON.stringify(entries);
    };
    const result = await runTranslationStage(claimedJob(fx.store), {
      store: fx.store, logger: new RedactingLogger((line) => logs.push(line)), provider, concurrency: 1
    }, makeHooks(fx.store, fx.jobId));
    assert.equal(result.segments[0].translation, 'batch:1');
    assert.equal(result.segments[1].translation, `译:${SEGMENTS[1].text}`);
    const batches = provider.calls.filter((c) => c.kind === 'batch');
    assert.equal(batches.length, 4);
    assert.equal(batches[1].userPrompt, `2. ${SEGMENTS[1].text}`);
    assert.equal(batches[2].userPrompt, `2. ${SEGMENTS[1].text}`);
    const singles = provider.calls.filter((c) => c.kind === 'single');
    assert.equal(singles.length, 1);
    assert.deepEqual(JSON.parse(singles[0].userPrompt), { id: 2, text: SEGMENTS[1].text });
    assert.ok(logs.some((l) => l.includes('originMismatch')));
    assert.ok(logs.every((l) => !l.includes(SEGMENTS[1].text)));
  } finally { await fx.cleanup(); }
});

test('good rows survive exhausted fallback and are reused on restart', async () => {
  const fx = await setup();
  try {
    const job = claimedJob(fx.store);
    const provider = new ScriptedProvider();
    provider.onBatch = (call) => {
      const entries: Record<string, unknown> = {};
      for (const line of call.userPrompt.split('\n')) {
        const match = /^(\d+)\.\s(.*)$/.exec(line)!;
        if (match[1] !== '2') entries[match[1]] = { origin: match[2], direct: `saved:${match[1]}` };
      }
      return JSON.stringify(entries);
    };
    provider.onSingle = () => '{"origin":"wrong","direct":"x"}';
    await assert.rejects(runTranslationStage(job, {
      store: fx.store, logger: new RedactingLogger(() => {}), provider, concurrency: 1
    }, makeHooks(fx.store, fx.jobId)), PipelineJobError);
    const checkpoint = fx.store.reusableCheckpoints(fx.jobId).find((c) => c.stage === 'translating')!;
    const saved = (checkpoint.output as { translations: Record<string, string> }).translations;
    assert.equal(Object.keys(saved).length, 9);
    assert.equal(saved['1'], 'saved:1');
    assert.equal(saved['2'], undefined);
    const resumed = new ScriptedProvider();
    const result = await runTranslationStage(job, {
      store: fx.store, logger: new RedactingLogger(() => {}), provider: resumed
    }, makeHooks(fx.store, fx.jobId));
    assert.equal(result.segments[0].translation, 'saved:1');
    assert.equal(result.segments[1].translation, `译:${SEGMENTS[1].text}`);
    assert.deepEqual(resumed.calls.filter((c) => c.kind === 'batch').map((c) => c.userPrompt), [
      [2, 11, 12].map((id) => `${id}. ${SEGMENTS[id - 1].text}`).join('\n')
    ]);
  } finally { await fx.cleanup(); }
});

test('JSON single input preserves source numbering, quotes and newlines in quality mode', async () => {
  const fx = await setup({ quality: 'quality' });
  try {
    const text = '1. How do "visualizations" work?\nKeep this line.';
    fx.store.recordCheckpoint(fx.jobId, {
      stage: 'transcribing', inputFingerprint: 'audiofp', schemaVersion: 1, reusable: true,
      output: { sourceFingerprint: 'single-json', segments: [{ ...SEGMENTS[0], sequence: 141, text }] }
    });
    const provider = new ScriptedProvider();
    provider.onBatch = () => 'invalid';
    provider.onSingle = (call) => {
      assert.deepEqual(JSON.parse(call.userPrompt), { id: 141, text });
      assert.ok(call.systemPrompt.includes('Translate only the decoded `text` value'));
      return JSON.stringify({ origin: text, direct: '直译', final: '最终译文' });
    };
    const result = await runTranslationStage(claimedJob(fx.store), {
      store: fx.store, logger: new RedactingLogger(() => {}), provider
    }, makeHooks(fx.store, fx.jobId));
    assert.equal(result.segments[0].translation, '最终译文');
    assert.equal(result.segments[0].sequence, 141);
  } finally { await fx.cleanup(); }
});


test('stage drains in-flight checkpoint writes before surfacing a concurrent failure', async () => {
  const fx = await setup();
  try {
    let release!: () => void;
    const pending = new Promise<void>((resolve) => { release = resolve; });
    const provider = new ScriptedProvider();
    provider.onBatch = async (call) => {
      if (call.userPrompt.startsWith('1.')) return new TranslationProviderError('failed', { retryable: true });
      await pending;
      return undefined;
    };
    let settled = false;
    const run = runTranslationStage(claimedJob(fx.store), {
      store: fx.store, logger: new RedactingLogger(() => {}), provider, concurrency: 2
    }, makeHooks(fx.store, fx.jobId));
    const checked = assert.rejects(run, PipelineJobError).then(() => { settled = true; });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(settled, false);
    release();
    await checked;
    const checkpoint = fx.store.reusableCheckpoints(fx.jobId).find((c) => c.stage === 'translating')!;
    const saved = (checkpoint.output as { translations: Record<string, string> }).translations;
    assert.deepEqual(Object.keys(saved), ['11', '12']);
  } finally { await fx.cleanup(); }
});
