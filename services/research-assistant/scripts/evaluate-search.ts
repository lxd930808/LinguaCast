#!/usr/bin/env tsx
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

import { EVAL_CORPUS } from '../evaluation/corpus.js';
import { v13BaselineRuns, V13_BASELINE_FIXTURE_VERSION } from '../evaluation/v13-baseline.js';
import { v14CandidateRuns, V14_CANDIDATE_FIXTURE_VERSION } from '../evaluation/v14-candidate.js';
import {
  dateCompliant,
  personEpisodePrecision,
  qualifiedHit,
  reportOffTopic,
  topKPrecision
} from '../evaluation/matching.js';
import type { EvalMetrics, EvalQuery, EvalReport, EvalRun } from '../evaluation/types.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const OUT_DIR = join(ROOT, 'evaluation', 'output');

function parseArgs(argv: string[]): { mode: 'baseline' | 'candidate'; live: boolean; outDir: string } {
  let mode: 'baseline' | 'candidate' = 'baseline';
  let live = false;
  let outDir = OUT_DIR;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i] ?? '';
    if (arg === '--mode=baseline' || arg === '--mode=candidate') {
      mode = arg.endsWith('candidate') ? 'candidate' : 'baseline';
    } else if (arg === '--mode' && argv[i + 1]) {
      mode = argv[i + 1] === 'candidate' ? 'candidate' : 'baseline';
      i += 1;
    } else if (arg === '--live') {
      live = true;
    } else if (arg === '--out' && argv[i + 1]) {
      outDir = argv[i + 1] ?? outDir;
      i += 1;
    }
  }
  return { mode, live, outDir };
}

function gitCommit(): string {
  const result = spawnSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8', cwd: join(ROOT, '..', '..') });
  return result.status === 0 ? result.stdout.trim() : 'unknown';
}

function mean(values: Array<number | null>): number | null {
  const nums = values.filter((value): value is number => value != null && Number.isFinite(value));
  if (nums.length === 0) return null;
  return nums.reduce((sum, value) => sum + value, 0) / nums.length;
}

export function scoreRuns(queries: EvalQuery[], runs: EvalRun[]): EvalReport['perQuery'] {
  const byId = new Map(runs.map((run) => [run.queryId, run]));
  return queries.map((query) => {
    const run = byId.get(query.id);
    const results = run?.results ?? [];
    const youtube = results.filter((item) => item.platform === 'youtube');
    const podcast = results.filter((item) => item.platform === 'podcast' || item.platform === 'apple_podcasts');
    const media = query.media;
    let precisionAt5: number | null = null;
    if (media.includes('youtube') && media.includes('podcast')) {
      const parts = [topKPrecision(youtube, query), topKPrecision(podcast, query)].filter(
        (value): value is number => value != null
      );
      precisionAt5 = parts.length ? parts.reduce((a, b) => a + b, 0) / parts.length : topKPrecision(results, query);
    } else if (media.includes('youtube')) {
      precisionAt5 = topKPrecision(youtube.length ? youtube : results, query);
    } else {
      precisionAt5 = topKPrecision(podcast.length ? podcast : results, query);
    }
    const off = reportOffTopic(results, query);
    return {
      queryId: query.id,
      precisionAt5,
      qualifiedHit: qualifiedHit(results, query),
      dateCompliant: dateCompliant(results, query),
      offTopicReportSources: off.offTopic,
      reportSourceCount: off.total
    };
  });
}

export function aggregate(queries: EvalQuery[], runs: EvalRun[]): EvalMetrics {
  const perQuery = scoreRuns(queries, runs);
  const byId = new Map(queries.map((query) => [query.id, query]));
  const youtubePrecisions: Array<number | null> = [];
  const podcastPrecisions: Array<number | null> = [];
  const personPrecisions: Array<number | null> = [];
  for (const query of queries) {
    const results = runs.find((run) => run.queryId === query.id)?.results ?? [];
    if (query.media.includes('youtube') && !query.expectZero) {
      youtubePrecisions.push(topKPrecision(results.filter((item) => item.platform === 'youtube'), query));
    }
    if (query.media.includes('podcast') && !query.expectZero) {
      podcastPrecisions.push(
        topKPrecision(
          results.filter((item) => item.platform === 'podcast' || item.platform === 'apple_podcasts'),
          query
        )
      );
    }
    const person = personEpisodePrecision(results, query);
    if (person != null && !query.expectZero) personPrecisions.push(person);
  }
  const coverageQueries = queries.filter((query) => query.expectQualifiedHit && !query.expectZero);
  const coverageHits = coverageQueries.filter((query) => perQuery.find((row) => row.queryId === query.id)?.qualifiedHit)
    .length;
  const dated = perQuery.filter((row) => row.dateCompliant != null);
  const reportTotal = perQuery.reduce((sum, row) => sum + row.reportSourceCount, 0);
  const reportOff = perQuery.reduce((sum, row) => sum + row.offTopicReportSources, 0);
  void byId;
  return {
    youtubeTop5Precision: mean(youtubePrecisions),
    podcastTop5Precision: mean(podcastPrecisions),
    personEpisodeTop5Precision: mean(personPrecisions),
    qualifiedHitCoverage: coverageQueries.length ? coverageHits / coverageQueries.length : 0,
    dateCompliance: dated.length ? dated.filter((row) => row.dateCompliant).length / dated.length : null,
    reportOffTopicRate: reportTotal ? reportOff / reportTotal : 0,
    queryCount: queries.length
  };
}

function comparisonMarkdown(baseline: EvalReport, candidate: EvalReport): string {
  const row = (label: string, key: keyof EvalMetrics) => {
    const before = baseline.metrics[key];
    const after = candidate.metrics[key];
    const fmt = (value: number | null) => (typeof value === 'number' ? `${(value * 100).toFixed(1)}%` : 'n/a');
    return `| ${label} | ${fmt(before as number | null)} | ${fmt(after as number | null)} |`;
  };
  return [
    '# Search evaluation comparison',
    '',
    `- generatedAt: ${candidate.generatedAt}`,
    `- commit: ${candidate.commit}`,
    '',
    '| Metric | V13 baseline | V14 candidate |',
    '| --- | --- | --- |',
    row('YouTube Top-5 precision', 'youtubeTop5Precision'),
    row('Podcast Top-5 precision', 'podcastTop5Precision'),
    row('Person episode Top-5 precision', 'personEpisodeTop5Precision'),
    row('Qualified-hit coverage', 'qualifiedHitCoverage'),
    row('Date compliance', 'dateCompliance'),
    row('Report off-topic rate', 'reportOffTopicRate'),
    ''
  ].join('\n');
}

function markdownSummary(report: EvalReport): string {
  const m = report.metrics;
  const pct = (value: number | null) => (value == null ? 'n/a' : `${(value * 100).toFixed(1)}%`);
  return [
    `# Search evaluation (${report.mode})`,
    '',
    `- generatedAt: ${report.generatedAt}`,
    `- commit: ${report.commit}`,
    `- fixtureVersion: ${report.fixtureVersion}`,
    `- queries: ${m.queryCount}`,
    '',
    '| Metric | Value |',
    '| --- | --- |',
    `| YouTube Top-5 precision | ${pct(m.youtubeTop5Precision)} |`,
    `| Podcast Top-5 precision | ${pct(m.podcastTop5Precision)} |`,
    `| Person episode Top-5 precision | ${pct(m.personEpisodeTop5Precision)} |`,
    `| Qualified-hit coverage | ${pct(m.qualifiedHitCoverage)} |`,
    `| Date compliance | ${pct(m.dateCompliance)} |`,
    `| Report off-topic rate | ${pct(m.reportOffTopicRate)} |`,
    ''
  ].join('\n');
}

export function buildReport(mode: 'baseline' | 'candidate', runs: EvalRun[], fixtureVersion: string): EvalReport {
  return {
    mode,
    generatedAt: '2026-08-31T00:00:00Z',
    commit: gitCommit(),
    fixtureVersion,
    providerConfig: {
      live: false,
      searchV2: mode === 'candidate',
      podcastIndex: mode === 'candidate'
    },
    metrics: aggregate(EVAL_CORPUS, runs),
    perQuery: scoreRuns(EVAL_CORPUS, runs)
  };
}

function main(): void {
  const args = parseArgs(process.argv.slice(2));
  if (args.live) {
    throw new Error('live evaluation is opt-in and not implemented in default CI; omit --live');
  }
  mkdirSync(args.outDir, { recursive: true });
  const runs = args.mode === 'baseline' ? v13BaselineRuns() : v14CandidateRuns();
  const fixtureVersion = args.mode === 'baseline' ? V13_BASELINE_FIXTURE_VERSION : V14_CANDIDATE_FIXTURE_VERSION;
  const report = buildReport(args.mode, runs, fixtureVersion);
  const jsonPath = join(args.outDir, `${args.mode}.json`);
  const mdPath = join(args.outDir, `${args.mode}.md`);
  writeFileSync(jsonPath, `${JSON.stringify(report, null, 2)}\n`);
  writeFileSync(mdPath, markdownSummary(report));
  if (args.mode === 'candidate') {
    const baseline = buildReport('baseline', v13BaselineRuns(), V13_BASELINE_FIXTURE_VERSION);
    writeFileSync(join(args.outDir, 'comparison.md'), comparisonMarkdown(baseline, report));
  }
  process.stdout.write(`${mdPath}\n`);
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  main();
}
