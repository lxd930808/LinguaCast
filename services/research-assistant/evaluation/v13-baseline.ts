import type { EvalQuery, EvalResult, EvalRun } from './types.js';
import { EVAL_CORPUS } from './corpus.js';

const BASELINE_RETRIEVED_AT = '2026-08-31T00:00:00Z';

function video(rank: number, id: string, title: string, extra: Partial<EvalResult> = {}): EvalResult {
  return {
    rank,
    platform: 'youtube',
    sourceType: 'video',
    sourceId: id,
    stableId: `youtube:video:${id}`,
    title,
    publisher: extra.publisher ?? 'Unknown Channel',
    publishedAt: extra.publishedAt ?? '2024-01-01T00:00:00Z',
    qualified: extra.qualified,
    selectedForReport: extra.selectedForReport ?? rank <= 3,
    ...extra
  };
}

function show(rank: number, id: string, title: string, extra: Partial<EvalResult> = {}): EvalResult {
  return {
    rank,
    platform: 'apple_podcasts',
    sourceType: 'podcast_show',
    sourceId: id,
    title,
    publisher: extra.publisher ?? title,
    publishedAt: extra.publishedAt ?? null,
    selectedForReport: extra.selectedForReport ?? rank <= 3,
    ...extra
  };
}

function episode(rank: number, id: string, title: string, extra: Partial<EvalResult> = {}): EvalResult {
  return {
    rank,
    platform: 'apple_podcasts',
    sourceType: 'podcast_episode',
    sourceId: id,
    title,
    publisher: extra.publisher ?? 'Unknown Show',
    publishedAt: extra.publishedAt ?? '2024-06-01T00:00:00Z',
    selectedForReport: extra.selectedForReport ?? rank <= 3,
    ...extra
  };
}

function offTopic(rank: number, id: string): EvalResult {
  return video(rank, id, 'Minecraft walkthrough funny moments', {
    publisher: 'Random Gaming',
    selectedForReport: rank === 1
  });
}

/**
 * Frozen V13-style recorded ranks. Person podcast queries return shows,
 * recency is ignored, and some runs mix off-topic hits — matching the
 * pre-V14 provider behaviour.
 */
export function v13ResultsFor(query: EvalQuery): EvalResult[] {
  if (query.expectZero) {
    return query.id.endsWith('01') || query.id.endsWith('03')
      ? [offTopic(1, 'zzzzzzzzzzz'), video(2, 'yyyyyyyyyyy', 'Unrelated vlog')]
      : [];
  }
  if (query.intent === 'person' && query.media.includes('podcast')) {
    const name = query.query.replace(/找 |最近参加的播客|播客|podcast appearance|recent podcast|采访|访谈/gi, '').trim();
    return [
      show(1, '1001', `${name} Official`, { selectedForReport: true }),
      show(2, '1002', `${name} Clips`),
      video(3, 'dQw4w9WgXcQ', `${name} keynote 2019`, { publishedAt: '2019-05-01T00:00:00Z' })
    ];
  }
  if (query.intent === 'recent') {
    return [
      video(1, 'oldoldold01', `${query.query} archive 2022`, {
        publishedAt: '2022-03-01T00:00:00Z',
        selectedForReport: true
      }),
      video(2, 'oldoldold02', 'Older background clip', { publishedAt: '2021-01-01T00:00:00Z' }),
      show(3, '2001', 'Long running show')
    ];
  }
  if (query.intent === 'show') {
    return [
      show(1, '3001', 'Unrelated similarly named show', { selectedForReport: true }),
      show(2, '3002', query.query),
      episode(3, 'ep-1', 'Random recent episode')
    ];
  }
  if (query.intent === 'channel') {
    return [
      video(1, 'chan0000001', 'Popular unrelated video', { publisher: 'Other Channel', selectedForReport: true }),
      video(2, 'chan0000002', query.query, { publisher: 'Guessed Channel' })
    ];
  }
  if (query.ambiguous) {
    return [
      video(1, 'ambig000001', query.query, { selectedForReport: true }),
      offTopic(2, 'ambig000002'),
      video(3, 'ambig000003', `${query.query} explained`)
    ];
  }
  return [
    video(1, 'topic000001', query.query, { selectedForReport: true }),
    video(2, 'topic000002', `${query.query} extra`),
    show(3, '4001', `${query.query} weekly`)
  ];
}

export const V13_BASELINE_FIXTURE_VERSION = 'v13-baseline-2026-08-31';

export function v13BaselineRuns(): EvalRun[] {
  return EVAL_CORPUS.map((query) => ({
    queryId: query.id,
    retrievedAt: BASELINE_RETRIEVED_AT,
    provider: 'v13-composite',
    results: v13ResultsFor(query)
  }));
}
