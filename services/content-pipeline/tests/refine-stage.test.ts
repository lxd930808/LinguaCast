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
import type {
  TranslationChatCall,
  TranslationProvider
} from '../src/providers/translation/types.js';
import { runRefinementStage } from '../src/pipeline/refinement/refine-stage.js';
import {
  assembleRefined,
  isRefinementCandidate,
  requiresDisplaySplit
} from '../src/pipeline/refinement/display-policy.js';
import { canonicalFingerprint } from '../src/pipeline/asr-stage.js';
import type { LearningSegment, TranscriptWord } from '../src/pipeline/segmentation/types.js';

// Display refinement tests (WP6): candidate detection, recursive sub-clause
// splitting with a fake split provider, per-candidate checkpoints and resume.

const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url).pathname;

function words(count: number, startMS: number, stepMS: number): TranscriptWord[] {
  return Array.from({ length: count }, (_, i) => ({
    text: `w${i + 1}`,
    startMS: startMS + i * stepMS,
    endMS: startMS + i * stepMS + stepMS - 20
  }));
}

/** A long candidate: >75 source chars with a word stream, CJK translation. */
function longSegment(sequence: number): LearningSegment {
  const text =
    `Word${sequence} ` + 'alpha beta gamma delta epsilon zeta eta theta '.repeat(3).trim();
  const wordList = words(24, sequence * 10000, 300);
  // Align word texts with renderText-based splitting.
  const pieces = text.split(' ');
  wordList.forEach((w, i) => {
    w.text = pieces[i % pieces.length];
  });
  return {
    sequence,
    startMS: wordList[0].startMS,
    endMS: wordList[wordList.length - 1].endMS,
    text,
    learningText: text,
    translation: '这是一段很长的中文翻译用来触发显示子句拆分的预算规则并且继续变长',
    notes: '',
    words: wordList,
    timingSource: 'wordTimeline'
  };
}

function shortSegment(sequence: number): LearningSegment {
  return {
    sequence,
    startMS: sequence * 1000,
    endMS: sequence * 1000 + 500,
    text: 'Short line.',
    learningText: 'Short line.',
    translation: '短句。',
    notes: '',
    words: [],
    timingSource: 'wordTimeline'
  };
}

class SplitProvider implements TranslationProvider {
  readonly name = 'fake';
  readonly model = 'fake-model';
  calls: TranslationChatCall[] = [];
  fail = false;

  async chatCompletion(call: TranslationChatCall): Promise<string> {
    this.calls.push(call);
    if (this.fail) throw new Error('provider exploded');
    const count = Number(/exactly (\d+)/.exec(call.systemPrompt)?.[1] ?? '2');
    return JSON.stringify({
      parts: Array.from({ length: count }, (_, i) => `部分${i + 1}`)
    });
  }
}

interface Fixture {
  tempRoot: string;
  store: JobStore;
  jobId: string;
  sourceFingerprint: string;
  cleanup: () => Promise<void>;
}

async function setup(segments: LearningSegment[]): Promise<Fixture> {
  const tempRoot = await mkdtemp(join(tmpdir(), 'refine-stage-test-'));
  const db = openDatabase(join(tempRoot, 'content.db'), MIGRATIONS_DIR);
  const store = new JobStore(db);
  const { job } = store.createJob({
    ownerScope: 'test-owner',
    contentType: 'podcast_episode',
    contentKey: podcastContentKey('https://example.com/feed.xml', 'ep-400'),
    source: { platform: 'rss', sourceId: 'ep-400', url: 'https://media.example.com/ep.mp3' },
    sourceLanguage: 'en',
    targetLanguage: 'zh-Hans',
    translationQuality: 'fast',
    pipelineVersion: 'v10.1',
    clientArtifactSchemaVersion: 1
  });
  const sourceFingerprint = `audiofp0:${canonicalFingerprint(segments)}`;
  store.recordCheckpoint(job.jobId, {
    stage: 'transcribing',
    inputFingerprint: 'audiofp',
    output: { sourceFingerprint, rawTranscriptKey: null, segments },
    schemaVersion: 1,
    reusable: true
  });
  const translations: Record<string, string> = {};
  for (const segment of segments) translations[String(segment.sequence)] = segment.translation;
  store.recordCheckpoint(job.jobId, {
    stage: 'translating',
    inputFingerprint: sourceFingerprint,
    output: {
      schemaVersion: 1,
      sourceFingerprint,
      context: { topicSummary: '', terms: [] },
      translations
    },
    schemaVersion: 1,
    reusable: true
  });
  return {
    tempRoot,
    store,
    jobId: job.jobId,
    sourceFingerprint,
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

test('requiresDisplaySplit follows the character budget and CJK weighting', () => {
  assert.ok(requiresDisplaySplit('x'.repeat(76), '短'));
  assert.ok(!requiresDisplaySplit('x'.repeat(75), '短'));
  // 37 CJK chars × 1.75 × 1.2 = 77.7 > 75 → split.
  assert.ok(requiresDisplaySplit('short', '汉'.repeat(37)));
  assert.ok(!requiresDisplaySplit('short', '汉'.repeat(30)));
  assert.ok(isRefinementCandidate(longSegment(1)));
  assert.ok(!isRefinementCandidate(shortSegment(1)));
  // No word stream → not a candidate even when too long.
  const noWords = { ...longSegment(2), words: [] };
  assert.ok(!isRefinementCandidate(noWords));
});

test('no candidates: passthrough writes the completion marker', async () => {
  const fx = await setup([shortSegment(1), shortSegment(2)]);
  try {
    const job = claimedJob(fx.store);
    const provider = new SplitProvider();
    const result = await runRefinementStage(
      job,
      { store: fx.store, logger: new RedactingLogger(), provider },
      makeHooks(fx.store, fx.jobId)
    );
    assert.equal(result.totalCandidates, 0);
    assert.equal(result.segments.length, 2);
    assert.equal(provider.calls.length, 0);
    const checkpoint = fx.store
      .reusableCheckpoints(fx.jobId)
      .find((c) => c.stage === 'refining_subtitles');
    const output = checkpoint?.output as { segments: LearningSegment[] };
    assert.ok(Array.isArray(output.segments));
    assert.equal(output.segments.length, 2);
  } finally {
    await fx.cleanup();
  }
});

test('long sentence splits into sub-clauses with shared playback sentence', async () => {
  const fx = await setup([shortSegment(1), longSegment(2), shortSegment(3)]);
  try {
    const job = claimedJob(fx.store);
    const provider = new SplitProvider();
    const result = await runRefinementStage(
      job,
      { store: fx.store, logger: new RedactingLogger(), provider },
      makeHooks(fx.store, fx.jobId)
    );
    assert.equal(result.totalCandidates, 1);
    assert.ok(result.segments.length > 3, 'expected the candidate to split');
    // Resequenced from 1.
    result.segments.forEach((s, i) => assert.equal(s.sequence, i + 1));
    // Sub-clauses share the original playback sentence timing and id.
    const subs = result.segments.filter((s) => s.playbackSentence);
    assert.ok(subs.length >= 2);
    const groupIds = new Set(subs.map((s) => s.playbackSentence!.id));
    assert.deepEqual([...groupIds], [2]);
    for (const sub of subs) {
      assert.equal(sub.playbackSentence!.startMS, 20000);
      assert.equal(sub.timingSource, 'wordTimeline');
      assert.ok(sub.translation.startsWith('部分'));
      assert.ok(sub.words.length > 0);
    }
    // Non-candidates keep identity.
    assert.equal(result.segments[0].text, 'Short line.');
  } finally {
    await fx.cleanup();
  }
});

test('split provider failure keeps the whole sentence', async () => {
  const fx = await setup([longSegment(1)]);
  try {
    const job = claimedJob(fx.store);
    const provider = new SplitProvider();
    provider.fail = true;
    const result = await runRefinementStage(
      job,
      { store: fx.store, logger: new RedactingLogger(), provider },
      makeHooks(fx.store, fx.jobId)
    );
    assert.equal(result.segments.length, 1);
    assert.equal(result.segments[0].sequence, 1);
    assert.ok(!result.segments[0].playbackSentence);
  } finally {
    await fx.cleanup();
  }
});

test('resume: completed candidates are not re-split', async () => {
  const segments = [longSegment(1), longSegment(2)];
  const fx = await setup(segments);
  try {
    const job = claimedJob(fx.store);
    // Pre-seed a checkpoint where candidate 1 is already refined.
    const refined1: LearningSegment[] = [
      { ...segments[0], sequence: 1, text: 'first half', translation: '前半' },
      { ...segments[0], sequence: 1, text: 'second half', translation: '后半' }
    ];
    fx.store.recordCheckpoint(fx.jobId, {
      stage: 'refining_subtitles',
      inputFingerprint: fx.sourceFingerprint,
      output: {
        schemaVersion: 1,
        sourceFingerprint: fx.sourceFingerprint,
        entries: [{ originalSequence: 1, segments: refined1 }]
      },
      schemaVersion: 1,
      reusable: true
    });
    const provider = new SplitProvider();
    const result = await runRefinementStage(
      job,
      { store: fx.store, logger: new RedactingLogger(), provider },
      makeHooks(fx.store, fx.jobId)
    );
    assert.equal(result.refinedCandidateCount, 1);
    // Final: 2 halves from candidate 1 + fresh splits of candidate 2.
    assert.equal(result.segments[0].text, 'first half');
    assert.equal(result.segments[1].text, 'second half');
    assert.ok(result.segments.length > 3);
    result.segments.forEach((s, i) => assert.equal(s.sequence, i + 1));
  } finally {
    await fx.cleanup();
  }
});

test('untranslated input is an internal error', async () => {
  const segments = [{ ...shortSegment(1), translation: '' }];
  const fx = await setup(segments);
  try {
    // Overwrite the translation checkpoint with an empty translations map.
    fx.store.recordCheckpoint(fx.jobId, {
      stage: 'translating',
      inputFingerprint: fx.sourceFingerprint,
      output: {
        schemaVersion: 1,
        sourceFingerprint: fx.sourceFingerprint,
        context: { topicSummary: '', terms: [] },
        translations: {}
      },
      schemaVersion: 1,
      reusable: true
    });
    const job = claimedJob(fx.store);
    await assert.rejects(
      runRefinementStage(
        job,
        { store: fx.store, logger: new RedactingLogger(), provider: new SplitProvider() },
        makeHooks(fx.store, fx.jobId)
      ),
      (error: unknown) => {
        assert.ok(error instanceof PipelineJobError);
        assert.equal(error.jobError.code, 'INTERNAL_ERROR');
        return true;
      }
    );
  } finally {
    await fx.cleanup();
  }
});

test('assembleRefined merges and resequences', () => {
  const original = [shortSegment(1), shortSegment(2), shortSegment(3)];
  const refined = new Map<number, LearningSegment[]>([
    [2, [shortSegment(2), { ...shortSegment(2), text: 'second half' }]]
  ]);
  const assembled = assembleRefined(original, refined);
  assert.equal(assembled.length, 4);
  assert.deepEqual(assembled.map((s) => s.sequence), [1, 2, 3, 4]);
  assert.equal(assembled[2].text, 'second half');
});
