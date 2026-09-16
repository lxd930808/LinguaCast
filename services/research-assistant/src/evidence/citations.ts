import { playerDeepLink } from '../content/content-key.js';
import type { V2ArtifactRecord, V2CitationRecord, V2Store } from '../db/v2/store.js';
import { newCitationId } from '../research-v2/state.js';
import { EXCERPT_MAX, type EvidenceLevelName } from './pack.js';

export interface ProposedCitation {
  citationId?: string;
  artifactId: string;
  evidenceLevel?: string;
  label?: string;
  passageId?: string | null;
  startMilliseconds?: number | null;
  endMilliseconds?: number | null;
  sourceURL?: string | null;
  contentKey?: string | null;
  quote: string;
  sha256?: string;
}

export interface ValidatedCitation {
  citationId: string;
  artifactId: string;
  evidenceLevel: EvidenceLevelName;
  label: string;
  passageId: string | null;
  startMilliseconds: number | null;
  endMilliseconds: number | null;
  sourceURL: string | null;
  contentKey: string | null;
  quote: string;
  sha256: string;
}

export function validateCitations(
  store: V2Store,
  researchId: string,
  proposed: ProposedCitation[]
): { ok: true; citations: ValidatedCitation[] } | { ok: false; reason: string; code: string } {
  if (!store.getResearch(researchId)) {
    return { ok: false, reason: 'research is unknown', code: 'RESEARCH_NOT_FOUND' };
  }
  if (proposed.length === 0) {
    return { ok: false, reason: 'no citations', code: 'CITATION_VALIDATION_FAILED' };
  }
  const citations: ValidatedCitation[] = [];
  for (const item of proposed) {
    const artifact = store.getArtifact(researchId, item.artifactId);
    if (!artifact || artifact.researchId !== researchId) {
      return { ok: false, reason: 'artifact is not in this research', code: 'ARTIFACT_NOT_FOUND' };
    }
    if (artifact.status === 'corrupt') {
      return { ok: false, reason: 'artifact is corrupt', code: 'ARTIFACT_CORRUPT' };
    }
    if (artifact.status !== 'ready' && artifact.status !== 'superseded') {
      return { ok: false, reason: 'artifact is not ready', code: 'ARTIFACT_NOT_READY' };
    }
    if (item.sha256 && item.sha256 !== artifact.sha256) {
      return { ok: false, reason: 'citation hash does not match the artifact version', code: 'CITATION_VALIDATION_FAILED' };
    }
    const level = (item.evidenceLevel ?? artifact.evidenceLevel) as EvidenceLevelName;
    if (level !== artifact.evidenceLevel) {
      return { ok: false, reason: 'evidence level does not match the artifact', code: 'CITATION_VALIDATION_FAILED' };
    }
    if (artifact.kind === 'web_search' || artifact.kind === 'youtube_search' || artifact.kind === 'podcast_search') {
      if (level !== 'search_metadata') {
        return { ok: false, reason: 'search summaries cannot be labeled as read content', code: 'CITATION_VALIDATION_FAILED' };
      }
    }
    const quote = item.quote.replace(/\s+/g, ' ').trim().slice(0, EXCERPT_MAX);
    if (!quote) {
      return { ok: false, reason: 'quote is required', code: 'CITATION_VALIDATION_FAILED' };
    }
    const passageId = item.passageId ?? null;
    if (level === 'primary_content') {
      const sourceURL = item.sourceURL ?? sourceUrlOf(artifact);
      if (!sourceURL || !passageId) {
        return { ok: false, reason: 'web citations require artifact ID, URL, and passage ID', code: 'CITATION_VALIDATION_FAILED' };
      }
      if (!passageExists(store, researchId, artifact.artifactId, passageId, quote)) {
        return { ok: false, reason: 'passage is not locatable in the artifact', code: 'CITATION_VALIDATION_FAILED' };
      }
    }
    if (level === 'transcript') {
      const contentKey = item.contentKey ?? contentKeyOf(artifact);
      const startMs = item.startMilliseconds ?? null;
      const endMs = item.endMilliseconds ?? null;
      if (!contentKey || startMs == null || endMs == null || startMs > endMs) {
        return { ok: false, reason: 'transcript citations require contentKey and a time range', code: 'CITATION_VALIDATION_FAILED' };
      }
      if (!transcriptRangeExists(store, researchId, artifact.artifactId, startMs, endMs, quote)) {
        return { ok: false, reason: 'transcript time range is not locatable', code: 'CITATION_VALIDATION_FAILED' };
      }
    }
    citations.push({
      citationId: item.citationId ?? newCitationId(),
      artifactId: artifact.artifactId,
      evidenceLevel: level,
      label: item.label || defaultLabel(level, item),
      passageId,
      startMilliseconds: item.startMilliseconds ?? null,
      endMilliseconds: item.endMilliseconds ?? null,
      sourceURL: item.sourceURL ?? sourceUrlOf(artifact),
      contentKey: item.contentKey ?? contentKeyOf(artifact),
      quote,
      sha256: artifact.sha256
    });
  }
  return { ok: true, citations };
}

export function toCitationRecords(
  researchId: string,
  messageId: string | null,
  citations: ValidatedCitation[]
): V2CitationRecord[] {
  return citations.map((citation) => ({
    citationId: citation.citationId,
    researchId,
    messageId,
    artifactId: citation.artifactId,
    evidenceLevel: citation.evidenceLevel,
    label: citation.label,
    passageId: citation.passageId,
    startMs: citation.startMilliseconds,
    endMs: citation.endMilliseconds,
    sourceUrl: citation.sourceURL,
    contentKey: citation.contentKey,
    quote: citation.quote,
    sha256: citation.sha256
  }));
}

export function playerLinkFor(citation: ValidatedCitation): string | null {
  if (!citation.contentKey || citation.startMilliseconds == null) return null;
  return playerDeepLink(citation.contentKey, citation.startMilliseconds);
}

function sourceUrlOf(artifact: V2ArtifactRecord): string | null {
  const ref = artifact.sourceReference as { sourceURL?: string | null } | null;
  return ref?.sourceURL ?? null;
}

function contentKeyOf(artifact: V2ArtifactRecord): string | null {
  const ref = artifact.sourceReference as { contentKey?: string | null } | null;
  return ref?.contentKey ?? null;
}

function passageExists(
  store: V2Store,
  researchId: string,
  artifactId: string,
  passageId: string,
  quote: string
): boolean {
  const passage = resolvePassage(store, researchId, artifactId, passageId);
  if (!passage) return false;
  return passage.text.includes(quote) || quote.includes(passage.text.slice(0, 24));
}

function resolvePassage(
  store: V2Store,
  researchId: string,
  artifactId: string,
  passageId: string
) {
  return (
    store.getPassage(researchId, passageId) ??
    store.getPassage(researchId, `${artifactId}:${passageId}`) ??
    store.listPassagesForArtifact(researchId, artifactId).find((item) => {
      return item.passageId === passageId || item.passageId.endsWith(`:${passageId}`);
    }) ??
    null
  );
}

function transcriptRangeExists(
  store: V2Store,
  researchId: string,
  artifactId: string,
  startMs: number,
  endMs: number,
  quote: string
): boolean {
  const passages = store.listPassagesForArtifact(researchId, artifactId);
  return passages.some((passage) => {
    if (passage.startMs == null || passage.endMs == null) return false;
    if (startMs < passage.startMs || endMs > passage.endMs) return false;
    return passage.text.includes(quote) || quote.includes(passage.text.slice(0, 24));
  });
}

function defaultLabel(level: EvidenceLevelName, item: ProposedCitation): string {
  if (level === 'transcript' && item.startMilliseconds != null && item.endMilliseconds != null) {
    return `${formatClock(item.startMilliseconds)}-${formatClock(item.endMilliseconds)}`;
  }
  if (item.sourceURL) {
    try {
      return new URL(item.sourceURL).hostname;
    } catch {
      return 'source';
    }
  }
  return level;
}

function formatClock(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
}
