import { DomainError } from '../../domain/types.js';

export interface SourceOnlyWord {
  text: string;
  startMS: number;
  endMS: number;
}

export interface SourceOnlySegment {
  sequence: number;
  startMS: number;
  endMS: number;
  text: string;
  learningText: string;
  speaker: string | null;
  words: SourceOnlyWord[];
}

export interface SourceOnlyTranscript {
  schemaVersion: 1;
  contentKey: string;
  v10JobId: string;
  v10ArtifactSha256: string;
  sourceLanguage: string | null;
  source: {
    platform: string;
    sourceId: string;
    canonicalURL: string;
    title?: string;
  };
  segments: SourceOnlySegment[];
}

const TRANSLATION_KEYS = new Set(['translation', 'targetText', 'targetVtt', 'targetVTT']);

export function decodeAndStripSourceOnly(raw: unknown): SourceOnlySegment[] {
  const doc = raw as { schemaVersion?: number; segments?: unknown[] };
  if (doc.schemaVersion !== 1 || !Array.isArray(doc.segments) || doc.segments.length === 0) {
    throw new DomainError('ARTIFACT_INVALID', 'segments.json schema is invalid', false, 422);
  }
  const segments: SourceOnlySegment[] = [];
  let lastSeq = 0;
  let lastEnd = -1;
  for (const item of doc.segments) {
    if (!item || typeof item !== 'object' || Array.isArray(item)) {
      throw new DomainError('ARTIFACT_INVALID', 'segment row is invalid', false, 422);
    }
    const row = item as Record<string, unknown>;
    const sequence = Number(row.sequence);
    const startMS = Number(row.startMS);
    const endMS = Number(row.endMS);
    const text = typeof row.text === 'string' ? row.text : '';
    if (!Number.isInteger(sequence) || sequence < lastSeq) {
      throw new DomainError('ARTIFACT_INVALID', 'segment sequence is invalid', false, 422);
    }
    if (!Number.isFinite(startMS) || !Number.isFinite(endMS) || startMS > endMS || startMS < 0) {
      throw new DomainError('ARTIFACT_INVALID', 'segment time range is invalid', false, 422);
    }
    lastSeq = sequence;
    lastEnd = Math.max(lastEnd, endMS);
    const learningText = typeof row.learningText === 'string' && row.learningText ? row.learningText : text;
    const speaker = row.speaker == null ? null : String(row.speaker);
    segments.push({
      sequence,
      startMS,
      endMS,
      text,
      learningText,
      speaker,
      words: decodeWords(row.words)
    });
  }
  return segments;
}

export function buildSourceOnlyTranscript(input: {
  contentKey: string;
  v10JobId: string;
  v10ArtifactSha256: string;
  sourceLanguage?: string | null;
  source: SourceOnlyTranscript['source'];
  segments: SourceOnlySegment[];
}): SourceOnlyTranscript {
  return {
    schemaVersion: 1,
    contentKey: input.contentKey,
    v10JobId: input.v10JobId,
    v10ArtifactSha256: input.v10ArtifactSha256,
    sourceLanguage: input.sourceLanguage ?? null,
    source: input.source,
    segments: input.segments
  };
}

export function encodeSourceOnlyJson(doc: SourceOnlyTranscript): string {
  return `${JSON.stringify(doc, null, 2)}\n`;
}

export function encodeSourceOnlyMarkdown(doc: SourceOnlyTranscript): string {
  const lines = [
    '---',
    'schemaVersion: 1',
    `contentKey: ${JSON.stringify(doc.contentKey)}`,
    `v10JobId: ${JSON.stringify(doc.v10JobId)}`,
    `v10ArtifactSha256: ${JSON.stringify(doc.v10ArtifactSha256)}`,
    '---',
    ''
  ];
  for (const segment of doc.segments) {
    const passageId = passageIdForSequence(segment.sequence);
    lines.push(`### ${passageId}`);
    lines.push(`startMS: ${segment.startMS}`);
    lines.push(`endMS: ${segment.endMS}`);
    lines.push(`speaker: ${segment.speaker ?? 'null'}`);
    lines.push('');
    lines.push(segment.text);
    lines.push('');
  }
  return lines.join('\n');
}

export function passageIdForSequence(sequence: number): string {
  return `p-${String(sequence).padStart(4, '0')}`;
}

export function containsTranslationLeak(value: unknown): boolean {
  if (!value || typeof value !== 'object') return false;
  if (Array.isArray(value)) return value.some(containsTranslationLeak);
  for (const [key, nested] of Object.entries(value as Record<string, unknown>)) {
    if (TRANSLATION_KEYS.has(key)) return true;
    if (containsTranslationLeak(nested)) return true;
  }
  return false;
}

function decodeWords(raw: unknown): SourceOnlyWord[] {
  if (!Array.isArray(raw)) return [];
  const words: SourceOnlyWord[] = [];
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue;
    const row = item as Record<string, unknown>;
    const text = typeof row.text === 'string' ? row.text : '';
    const startMS = Number(row.startMS);
    const endMS = Number(row.endMS);
    if (!text || !Number.isFinite(startMS) || !Number.isFinite(endMS) || startMS > endMS) continue;
    words.push({ text, startMS, endMS });
  }
  return words;
}
