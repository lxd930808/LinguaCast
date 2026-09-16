export const EVIDENCE_LEVEL_RANK = {
  primary_content: 0,
  transcript: 1,
  search_metadata: 2,
  research_note: 3,
  user_preference: 9
} as const;

export type EvidenceLevelName = keyof typeof EVIDENCE_LEVEL_RANK;

export interface EvidenceLocator {
  sourceURL?: string | null;
  contentKey?: string | null;
  startMs?: number | null;
  endMs?: number | null;
  virtualUri?: string | null;
}

export interface EvidenceItem {
  artifactId: string | null;
  sha256: string;
  passageId: string;
  evidenceLevel: EvidenceLevelName;
  kind: string;
  excerpt: string;
  locator: EvidenceLocator;
  score: number;
}

export interface EvidenceConflict {
  reason: string;
  passageIds: string[];
  artifactIds: string[];
}

export interface EvidenceGap {
  code: string;
  reason: string;
  suggestions: string[];
}

export interface EvidencePack {
  researchId: string;
  query: string;
  items: EvidenceItem[];
  preferences: EvidenceItem[];
  conflicts: EvidenceConflict[];
  gaps: EvidenceGap[];
}

export const EXCERPT_MAX = 240;

export function clipExcerpt(text: string, max = EXCERPT_MAX): string {
  const normalized = text.replace(/\s+/g, ' ').trim();
  return normalized.slice(0, max);
}

export function rankEvidence(left: EvidenceItem, right: EvidenceItem): number {
  const level = EVIDENCE_LEVEL_RANK[left.evidenceLevel] - EVIDENCE_LEVEL_RANK[right.evidenceLevel];
  if (level !== 0) return level;
  const kindBoost = kindRank(left.kind) - kindRank(right.kind);
  if (kindBoost !== 0) return kindBoost;
  return right.score - left.score;
}

function kindRank(kind: string): number {
  switch (kind) {
    case 'web_page':
      return 0;
    case 'shared_file':
      return 1;
    case 'transcript':
      return 2;
    case 'youtube_search':
    case 'podcast_search':
      return 3;
    case 'web_search':
      return 4;
    case 'research_memory':
      return 5;
    default:
      return 6;
  }
}

export function detectConflicts(items: EvidenceItem[]): EvidenceConflict[] {
  const factual = items.filter(
    (item) => item.evidenceLevel === 'primary_content' || item.evidenceLevel === 'transcript'
  );
  const byArtifact = new Map<string, EvidenceItem[]>();
  for (const item of factual) {
    const key = item.artifactId ?? item.locator.virtualUri ?? item.passageId;
    const list = byArtifact.get(key) ?? [];
    list.push(item);
    byArtifact.set(key, list);
  }
  if (byArtifact.size < 2) return [];
  return [
    {
      reason: 'multiple locatable sources remain; do not merge them into one claim',
      passageIds: factual.map((item) => item.passageId),
      artifactIds: [...new Set(factual.map((item) => item.artifactId).filter((id): id is string => Boolean(id)))]
    }
  ];
}

export function evidenceGaps(items: EvidenceItem[], query: string): EvidenceGap[] {
  const gaps: EvidenceGap[] = [];
  const hasPrimary = items.some((item) => item.evidenceLevel === 'primary_content');
  const hasTranscript = items.some((item) => item.evidenceLevel === 'transcript');
  const hasSearch = items.some((item) => item.evidenceLevel === 'search_metadata');
  if (items.length === 0) {
    gaps.push({
      code: 'EVIDENCE_NOT_FOUND',
      reason: `no locatable artifacts matched ${JSON.stringify(query)}`,
      suggestions: ['search_youtube', 'search_podcasts', 'web_search', 'fetch_web_page', 'request_transcription']
    });
    return gaps;
  }
  if (!hasPrimary && !hasTranscript) {
    gaps.push({
      code: 'EVIDENCE_NOT_FOUND',
      reason: hasSearch
        ? 'only search metadata is available; do not treat summaries as read pages or transcripts'
        : 'no primary content or transcript is available',
      suggestions: hasSearch ? ['fetch_web_page', 'request_transcription'] : ['web_search', 'request_transcription']
    });
  }
  return gaps;
}
