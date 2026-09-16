import type { EvalQuery, EvalResult, EvalRun } from './types.js';
import { EVAL_CORPUS } from './corpus.js';
import { validateSearchPlan } from '../src/search/identity.js';
import { applyHardFilters, rankHits } from '../src/search/ranking.js';
import type { NormalizedSearchHit, SearchMedia } from '../src/search/contracts.js';
import { isRelevant } from './matching.js';

const RETRIEVED_AT = '2026-08-31T00:00:00Z';
export const V14_CANDIDATE_FIXTURE_VERSION = 'v14-candidate-ranking-2026-08-31';

function youtubeId(seed: string): string {
  const padded = `${seed}xxxxxxxxxxx`.replace(/[^A-Za-z0-9_-]/g, 'x').slice(0, 11);
  return padded.length === 11 ? padded : `${padded}xxxxxxxxxxx`.slice(0, 11);
}

function relevantTitle(query: EvalQuery): string {
  const rule = query.relevant.find((item) => item.kind === 'title_contains');
  if (rule && rule.kind === 'title_contains') {
    return `${rule.terms[0]} ${query.query}`.slice(0, 180);
  }
  return query.query;
}

function rawHitsFor(query: EvalQuery): NormalizedSearchHit[] {
  if (query.expectZero) return [];
  const title = relevantTitle(query);
  const publishedAt = query.publishedAfter ?? '2026-06-01T00:00:00Z';
  const hits: NormalizedSearchHit[] = [];
  const wantYoutube = query.media.includes('youtube');
  const wantPodcast = query.media.includes('podcast');
  if (wantYoutube) {
    for (let i = 0; i < 5; i += 1) {
      hits.push({
        platform: 'youtube',
        sourceType: 'video',
        sourceId: youtubeId(`${query.id}y${i}`),
        canonicalURL: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        title: i === 0 ? title : `${title} part ${i + 1}`,
        publisher: query.intent === 'channel' ? query.query : 'Example Channel',
        publishedAt,
        durationSeconds: query.duration === 'long' ? 3600 : 1200,
        description: title,
        provider: 'ytdlp',
        provenance: { title: 'fixture' },
        deepResearchAvailability: 'available',
        warnings: [],
        providerRank: i + 1
      });
    }
  }
  if (wantPodcast) {
    if (query.intent === 'person') {
      for (let i = 0; i < 5; i += 1) {
        hits.push({
          platform: 'podcast',
          sourceType: 'podcast_episode',
          sourceId: `${query.id}-ep-${i}`,
          canonicalURL: 'https://example.test/ep',
          feedURL: 'https://feeds.example.com/show.xml',
          title: `${title} episode ${i + 1}`,
          publisher: 'Interview Show',
          publishedAt,
          durationSeconds: 3600,
          description: title,
          provider: 'podcastindex',
          provenance: { title: 'fixture' },
          deepResearchAvailability: 'available',
          warnings: [],
          enclosureUrl: 'https://cdn.example.com/ep.mp3',
          personTags: [query.query],
          guid: `${query.id}-ep-${i}`,
          providerRank: i + 1
        });
      }
    } else {
      hits.push({
        platform: 'podcast',
        sourceType: query.intent === 'show' ? 'podcast_show' : 'podcast_episode',
        sourceId: `${query.id}-pod`,
        canonicalURL: 'https://example.test/show',
        feedURL: 'https://feeds.example.com/show.xml',
        title,
        publisher: title,
        publishedAt,
        durationSeconds: 2400,
        description: title,
        provider: 'podcastindex',
        provenance: { title: 'fixture' },
        deepResearchAvailability: query.intent === 'show' ? 'unavailable' : 'available',
        warnings: [],
        enclosureUrl: query.intent === 'show' ? null : 'https://cdn.example.com/ep.mp3',
        guid: `${query.id}-pod`,
        providerRank: 1
      });
    }
  }
  hits.push({
    platform: 'youtube',
    sourceType: 'video',
    sourceId: youtubeId(`${query.id}off`),
    canonicalURL: 'https://www.youtube.com/watch?v=zzzzzzzzzzz',
    title: 'Minecraft walkthrough funny moments',
    publisher: 'Random Gaming',
    publishedAt: '2020-01-01T00:00:00Z',
    durationSeconds: 90,
    description: 'gaming',
    provider: 'ytdlp',
    provenance: { title: 'fixture' },
    deepResearchAvailability: 'available',
    warnings: [],
    providerRank: 99
  });
  return hits;
}

function toEvalResult(hit: NormalizedSearchHit & { rank: number; qualified: boolean }, query: EvalQuery): EvalResult {
  const relevant = isRelevant(
    {
      rank: hit.rank,
      platform: hit.platform === 'apple_podcasts' ? 'podcast' : hit.platform,
      sourceType: hit.sourceType,
      sourceId: hit.sourceId,
      title: hit.title,
      publisher: hit.publisher,
      publishedAt: hit.publishedAt,
      qualified: hit.qualified
    },
    query
  );
  return {
    rank: hit.rank,
    platform: hit.platform === 'apple_podcasts' ? 'podcast' : hit.platform,
    sourceType: hit.sourceType,
    sourceId: hit.sourceId,
    stableId: hit.stableId,
    title: hit.title,
    publisher: hit.publisher,
    publishedAt: hit.publishedAt,
    qualified: hit.qualified,
    selectedForReport: Boolean(hit.qualified && relevant && hit.rank <= 3)
  };
}

export function v14ResultsFor(query: EvalQuery): EvalResult[] {
  if (query.expectZero) return [];
  const media = query.media as SearchMedia[];
  const plan = validateSearchPlan(
    {
      intent: query.intent,
      media,
      queries: [query.query],
      person: query.intent === 'person' ? query.query : null,
      showOrChannel: query.intent === 'show' || query.intent === 'channel' ? query.query : null,
      publishedAfter: query.publishedAfter,
      duration: query.duration ?? 'any'
    },
    new Date('2026-08-31T00:00:00Z')
  );
  const { accepted } = applyHardFilters(rawHitsFor(query), plan);
  return rankHits(accepted, plan)
    .slice(0, 10)
    .map((hit) => toEvalResult(hit, query));
}

export function v14CandidateRuns(): EvalRun[] {
  return EVAL_CORPUS.map((query) => ({
    queryId: query.id,
    retrievedAt: RETRIEVED_AT,
    provider: 'v14-ranking-fixture',
    results: v14ResultsFor(query)
  }));
}
