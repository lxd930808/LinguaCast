import type { EvalMatchRule, EvalQuery, EvalResult } from './types.js';

export function ruleMatches(result: EvalResult, rule: EvalMatchRule): boolean {
  switch (rule.kind) {
    case 'title_contains':
      return rule.terms.some((term) => result.title.toLowerCase().includes(term.toLowerCase()));
    case 'publisher_contains':
      return rule.terms.some((term) => (result.publisher ?? '').toLowerCase().includes(term.toLowerCase()));
    case 'source_type':
      return result.sourceType === rule.sourceType;
    case 'identity':
      if (rule.stableId && result.stableId === rule.stableId) return true;
      if (rule.sourceId && result.sourceId === rule.sourceId) return true;
      return false;
    default:
      return false;
  }
}

export function isRelevant(result: EvalResult, query: EvalQuery): boolean {
  if (query.relevant.length === 0) return false;
  return query.relevant.some((rule) => ruleMatches(result, rule));
}

export function isUnacceptable(result: EvalResult, query: EvalQuery): boolean {
  return query.unacceptable.some((rule) => ruleMatches(result, rule));
}

export function topKPrecision(results: EvalResult[], query: EvalQuery, k = 5): number | null {
  const slice = results.slice(0, k);
  if (slice.length === 0) return query.expectZero ? 1 : 0;
  const hits = slice.filter((item) => isRelevant(item, query)).length;
  return hits / slice.length;
}

export function personEpisodePrecision(results: EvalResult[], query: EvalQuery, k = 5): number | null {
  if (query.intent !== 'person' || !query.media.includes('podcast')) return null;
  const slice = results
    .filter((item) => item.platform === 'podcast' || item.platform === 'apple_podcasts')
    .slice(0, k);
  if (slice.length === 0) return query.expectZero ? 1 : 0;
  const hits = slice.filter(
    (item) => item.sourceType === 'podcast_episode' && isRelevant(item, query)
  ).length;
  return hits / slice.length;
}

export function qualifiedHit(results: EvalResult[], query: EvalQuery): boolean {
  if (query.expectZero || !query.expectQualifiedHit) {
    return results.length === 0 || results.every((item) => !isRelevant(item, query));
  }
  return results.some((item) => (item.qualified ?? true) && isRelevant(item, query));
}

export function dateCompliant(results: EvalResult[], query: EvalQuery): boolean | null {
  if (!query.publishedAfter) return null;
  const recommended = results.filter((item) => item.selectedForReport || item.rank <= 5);
  if (recommended.length === 0) return query.expectZero ? true : false;
  const cutoff = Date.parse(query.publishedAfter);
  return recommended.every((item) => {
    if (!item.publishedAt) return false;
    return Date.parse(item.publishedAt) >= cutoff;
  });
}

export function reportOffTopic(results: EvalResult[], query: EvalQuery): { offTopic: number; total: number } {
  const report = results.filter((item) => item.selectedForReport);
  if (report.length === 0) return { offTopic: 0, total: 0 };
  return {
    offTopic: report.filter((item) => isUnacceptable(item, query) || !isRelevant(item, query)).length,
    total: report.length
  };
}
