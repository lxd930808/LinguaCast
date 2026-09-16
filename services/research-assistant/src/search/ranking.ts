import type { MatchReason, NormalizedSearchHit, RankedSearchHit, SearchPlan } from './contracts.js';

const SHORTS = /\bshorts?\b|trailer|teaser|#shorts/i;
const DURATION_BOUNDS: Record<string, { min: number; max: number }> = {
  short: { min: 0, max: 240 },
  medium: { min: 240, max: 1200 },
  long: { min: 1200, max: Number.POSITIVE_INFINITY }
};

export function tokenize(text: string): string[] {
  return text
    .normalize('NFC')
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((token) => token.length > 1);
}

export function rankHits(hits: NormalizedSearchHit[], plan: SearchPlan): RankedSearchHit[] {
  const queries = plan.queries.map((query) => query.normalize('NFC'));
  const entity = (plan.person || plan.showOrChannel || '').normalize('NFC');
  const scored = hits.map((hit, providerIndex) => scoreHit(hit, plan, queries, entity, hit.providerRank ?? providerIndex + 1));
  scored.sort((a, b) => {
    if (b.score !== a.score) return b.score - a.score;
    if (a.providerRank !== b.providerRank) return a.providerRank - b.providerRank;
    return a.hit.sourceId.localeCompare(b.hit.sourceId);
  });
  return scored.map((row, index) => ({
    ...row.hit,
    rank: index + 1,
    relevanceScore: Number((row.score / 200).toFixed(4)),
    matchReason: row.reason,
    qualified: row.qualified
  }));
}

function scoreHit(
  hit: NormalizedSearchHit,
  plan: SearchPlan,
  queries: string[],
  entity: string,
  providerRank: number
): { hit: NormalizedSearchHit; score: number; reason: MatchReason; qualified: boolean; providerRank: number } {
  let score = 0;
  let reason: MatchReason = 'unqualified';
  const title = hit.title.normalize('NFC');
  const titleLower = title.toLowerCase();
  const blob = `${title} ${hit.publisher ?? ''} ${hit.description ?? ''} ${(hit.personTags ?? []).join(' ')}`.toLowerCase();

  if (entity) {
    const entityLower = entity.toLowerCase();
    if (titleLower === entityLower) {
      score += 120;
      reason = 'entity_exact';
    } else if (titleLower.includes(entityLower) && hit.sourceType === 'podcast_episode') {
      score += 100;
      reason = 'person_tag_and_episode_title';
    } else if ((hit.personTags ?? []).some((tag) => tag.toLowerCase().includes(entityLower))) {
      score += 90;
      reason = 'person_tag';
    } else if ((hit.publisher ?? '').toLowerCase().includes(entityLower)) {
      score += 80;
      reason = 'channel_or_show_match';
    }
  }

  for (const query of queries) {
    const queryLower = query.toLowerCase();
    if (titleLower === queryLower) {
      score += 110;
      if (reason === 'unqualified') reason = 'title_exact';
    } else if (titleLower.includes(queryLower)) {
      score += 70;
      if (reason === 'unqualified') reason = 'title_term_coverage';
    } else {
      const terms = tokenize(query);
      const covered = terms.filter((term) => blob.includes(term)).length;
      if (terms.length && covered / terms.length >= 0.5) {
        score += Math.round(40 * (covered / terms.length));
        if (reason === 'unqualified') {
          reason = titleLower.split(/[^\p{L}\p{N}]+/u).some((token) => terms.includes(token))
            ? 'title_term_coverage'
            : 'description_term';
        }
      }
    }
  }

  if (plan.publishedAfter && hit.publishedAt && Date.parse(hit.publishedAt) >= Date.parse(plan.publishedAfter)) {
    score += 20;
    if (reason === 'unqualified') reason = 'recent_window';
  } else if (plan.publishedAfter && hit.publishedAt && Date.parse(hit.publishedAt) < Date.parse(plan.publishedAfter)) {
    score -= 80;
  } else if (plan.publishedAfter && !hit.publishedAt) {
    score -= 10;
  }

  if (plan.duration !== 'any' && hit.durationSeconds) {
    const bound = DURATION_BOUNDS[plan.duration];
    if (hit.durationSeconds >= bound.min && hit.durationSeconds < bound.max) {
      score += 15;
      if (reason === 'unqualified') reason = 'duration_match';
    } else {
      score -= 25;
    }
  }

  if (plan.language && hit.language && hit.language.toLowerCase().startsWith(plan.language.slice(0, 2).toLowerCase())) {
    score += 8;
    if (reason === 'unqualified') reason = 'language_match';
  }

  score += Math.max(0, 12 - providerRank);
  if (reason === 'unqualified' && score > 0) reason = 'provider_rank';

  if (hit.durationSeconds && hit.publishedAt && hit.description) {
    score += 6;
    if (reason === 'provider_rank') reason = 'metadata_complete';
  }
  if (hit.deepResearchAvailability === 'available') score += 5;
  if (SHORTS.test(title) || (hit.durationSeconds != null && hit.durationSeconds < 60 && hit.platform === 'youtube')) {
    score -= 35;
  }

  const evidence =
    reason === 'title_exact' ||
    reason === 'entity_exact' ||
    reason === 'title_term_coverage' ||
    reason === 'person_tag' ||
    reason === 'person_tag_and_episode_title' ||
    reason === 'channel_or_show_match' ||
    reason === 'description_term';
  const qualified = evidence && score >= 40;
  return { hit: { ...hit, providerRank }, score, reason: qualified ? reason : 'unqualified', qualified, providerRank };
}

export function applyHardFilters(hits: NormalizedSearchHit[], plan: SearchPlan): {
  accepted: NormalizedSearchHit[];
  filtered: number;
} {
  const accepted = hits.filter((hit) => {
    if (plan.publishedAfter && hit.publishedAt && Date.parse(hit.publishedAt) < Date.parse(plan.publishedAfter)) {
      return false;
    }
    if (plan.clean && /\b(porn|xxx)\b/i.test(hit.title)) return false;
    return true;
  });
  return { accepted, filtered: hits.length - accepted.length };
}
