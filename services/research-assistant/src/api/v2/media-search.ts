import type { SearchPlan } from '../../search/contracts.js';
import type { SearchOrchestrator } from '../../search/orchestrator.js';
import type { V2MediaHit, V2MediaSearch } from '../../research-v2/tool-dispatch.js';

function topicPlan(media: 'youtube' | 'podcast', query: string): SearchPlan {
  return {
    intent: 'topic',
    media: [media],
    queries: [query],
    person: null,
    showOrChannel: null,
    language: 'en',
    region: 'US',
    publishedAfter: null,
    publishedBefore: null,
    duration: 'any',
    clean: false
  };
}

function toHit(row: {
  sourceId: string;
  title: string;
  canonicalURL: string;
  platform: string;
  sourceType?: V2MediaHit['sourceType'];
  provider?: string;
  publishedAt?: string | null;
  feedURL?: string | null;
  enclosureUrl?: string | null;
}): V2MediaHit {
  const platform = row.platform === 'youtube' ? 'youtube' : 'podcast';
  return {
    sourceId: row.sourceId,
    title: row.title,
    canonicalURL: row.canonicalURL,
    platform,
    sourceType: row.sourceType,
    provider: row.provider,
    publishedAt: row.publishedAt ?? null,
    feedURL: row.feedURL ?? null,
    enclosureUrl: row.enclosureUrl ?? null
  };
}

export function mediaSearchFromOrchestrator(orchestrator: SearchOrchestrator | null | undefined): V2MediaSearch | null {
  if (!orchestrator) return null;
  return {
    async searchYouTube(query, limit, signal) {
      const part = await orchestrator.searchYouTube(topicPlan('youtube', query), limit, signal);
      const hits = part.hits.map(toHit);
      return { hits, status: hits.length ? 'success' : 'empty' };
    },
    async searchPodcasts(query, limit, signal) {
      const outcome = await orchestrator.search(topicPlan('podcast', query), limit, signal);
      const hits = outcome.hits.filter((hit) => hit.platform !== 'youtube').map(toHit);
      return { hits, status: hits.length ? 'success' : outcome.warnings.length ? 'partial' : 'empty' };
    }
  };
}
