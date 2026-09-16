import type { ArtifactWriter } from '../../artifacts/writer.js';
import type { TranscriptSource } from '../../content/v2/transcript-installer.js';
import type { V2Store } from '../../db/v2/store.js';
import { DomainError } from '../../domain/types.js';

const SOURCE_ID_PATTERN = /^so_[0-9A-HJKMNP-TV-Z]{26}$/;

interface SearchHit {
  sourceId?: string;
  assistantSourceId?: string;
  nativeSourceId?: string;
  canonicalURL?: string;
  title?: string;
  feedURL?: string | null;
  enclosureUrl?: string | null;
  platform?: string;
}

export function resolveTranscriptSource(
  store: V2Store,
  writer: ArtifactWriter,
  researchId: string,
  sourceId: string
): TranscriptSource {
  if (!SOURCE_ID_PATTERN.test(sourceId)) {
    throw new DomainError('SOURCE_NOT_FOUND', 'sourceId is missing or not in this Research', false, 404);
  }
  const kinds: Array<{ kind: string; platform: 'youtube' | 'podcast' }> = [
    { kind: 'youtube_search', platform: 'youtube' },
    { kind: 'podcast_search', platform: 'podcast' }
  ];
  for (const { kind, platform } of kinds) {
    for (const artifact of store.listArtifacts(researchId, kind, 'ready')) {
      let body: string;
      try {
        body = writer.get(artifact.artifactId).text;
      } catch {
        continue;
      }
      const hit = findHit(body, sourceId);
      if (!hit) continue;
      const nativeSourceId = hit.nativeSourceId || (SOURCE_ID_PATTERN.test(hit.sourceId ?? '') ? '' : hit.sourceId) || '';
      const canonicalURL = hit.canonicalURL ?? '';
      if (!nativeSourceId || !canonicalURL) continue;
      return {
        sourceId,
        platform,
        nativeSourceId,
        canonicalURL,
        title: hit.title,
        feedURL: hit.feedURL ?? null,
        enclosureUrl: hit.enclosureUrl ?? null
      };
    }
  }
  throw new DomainError('SOURCE_NOT_FOUND', 'sourceId is missing or not in this Research', false, 404);
}

function findHit(body: string, sourceId: string): SearchHit | null {
  try {
    const doc = JSON.parse(body) as { results?: SearchHit[] };
    for (const row of doc.results ?? []) {
      if (row.assistantSourceId === sourceId || row.sourceId === sourceId || row.nativeSourceId === sourceId) {
        return row;
      }
    }
  } catch {
    return null;
  }
  return null;
}
