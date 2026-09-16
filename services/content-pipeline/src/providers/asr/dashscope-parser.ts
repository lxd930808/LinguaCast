import type { LearningSegment, TranscriptWord } from '../../pipeline/segmentation/types.js';

// DashScope result parser (WP5) — port of the Swift TranscriptionSegmentExtractor.
//
// Preferred path: transcripts[].sentences[] in order, expanding words[] into
// TranscriptWord (timingSource = 'wordTimeline'). Without a word array the
// sentence-level timestamps survive as 'legacy'. Last resort is the generic
// array scan the pre-word implementation used.

type Json = Record<string, unknown>;

export function extractSegments(payload: unknown): LearningSegment[] {
  const sentences = preferredSentences(payload);
  if (sentences && sentences.length > 0) {
    return sentences.map((sentence, index) => segmentFromSentence(sentence, index + 1));
  }
  return legacyExtractSegments(payload);
}

function preferredSentences(payload: unknown): Json[] | null {
  if (!isObject(payload)) return null;
  const transcripts = payload.transcripts;
  if (Array.isArray(transcripts)) {
    const sentences: Json[] = [];
    for (const transcript of transcripts) {
      if (isObject(transcript) && Array.isArray(transcript.sentences)) {
        sentences.push(...transcript.sentences.filter(isObject));
      }
    }
    if (sentences.length > 0) return sentences;
  }
  const results = payload.results;
  if (Array.isArray(results)) {
    for (const result of results) {
      const nested = preferredSentences(result);
      if (nested && nested.length > 0) return nested;
    }
  }
  return null;
}

function segmentFromSentence(sentence: Json, sequence: number): LearningSegment {
  const text =
    stringValue(sentence.text ?? sentence.sentence ?? sentence.transcription) ?? '';
  const startMS =
    intValue(sentence.begin_time ?? sentence.start_time ?? sentence.start_ms) ?? 0;
  const endMS = intValue(sentence.end_time ?? sentence.end_ms) ?? startMS;
  const words = extractWords(sentence);
  return {
    sequence,
    startMS,
    endMS: Math.max(endMS, startMS + 1),
    text,
    learningText: text,
    translation: '',
    speaker: stringValue(sentence.speaker ?? sentence.speaker_id),
    notes: '',
    words,
    timingSource: words.length > 0 ? 'wordTimeline' : 'legacy'
  };
}

function extractWords(sentence: Json): TranscriptWord[] {
  if (!Array.isArray(sentence.words)) return [];
  const words: TranscriptWord[] = [];
  for (const raw of sentence.words) {
    if (!isObject(raw)) continue;
    const text = stringValue(raw.text ?? raw.word) ?? '';
    if (text === '') continue;
    const startMS = intValue(raw.begin_time ?? raw.start_time ?? raw.start_ms) ?? 0;
    const endMS = intValue(raw.end_time ?? raw.end_ms) ?? startMS;
    const rawPunctuation = stringValue(raw.punctuation);
    // DashScope emits punctuation as a separate token; keep it attached to the
    // word so sentence reconstruction and local segmentation work.
    const punctuation = rawPunctuation?.trim();
    words.push({
      text,
      startMS,
      endMS: Math.max(endMS, startMS + 1),
      ...(punctuation ? { punctuation } : {})
    });
  }
  return words;
}

/** Pre-word fallback: scan for the largest candidate array of sentence-like dicts. */
function legacyExtractSegments(payload: unknown): LearningSegment[] {
  const candidates = collectArrays(payload);
  const rawSegments = candidates.reduce<unknown[]>(
    (largest, current) => (current.length > largest.length ? current : largest),
    []
  );
  const segments: LearningSegment[] = [];
  rawSegments.forEach((item, index) => {
    if (!isObject(item)) return;
    const text =
      stringValue(item.text ?? item.sentence ?? item.transcription ?? item.result) ?? '';
    if (text === '') return;
    const startMS = intValue(item.start_time ?? item.begin_time ?? item.start_ms) ?? 0;
    const endMS = intValue(item.end_time ?? item.end_ms) ?? startMS;
    segments.push({
      sequence: index + 1,
      startMS,
      endMS,
      text,
      learningText: text,
      translation: '',
      speaker: stringValue(item.speaker ?? item.speaker_id),
      notes: '',
      words: [],
      timingSource: 'legacy'
    });
  });
  return segments;
}

function collectArrays(value: unknown): unknown[][] {
  if (isObject(value)) {
    const arrays: unknown[][] = [];
    for (const [key, child] of Object.entries(value)) {
      if (['results', 'segments', 'sentence', 'sentences'].includes(key) && Array.isArray(child)) {
        arrays.push(child);
      }
      arrays.push(...collectArrays(child));
    }
    return arrays;
  }
  if (Array.isArray(value)) {
    return value.flatMap((item) => collectArrays(item));
  }
  return [];
}

function intValue(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.trunc(value);
  if (typeof value === 'string') {
    // Swift parity: Int(Double(string) ?? 0) — garbage strings become 0.
    const parsed = Number(value);
    return Number.isFinite(parsed) ? Math.trunc(parsed) : 0;
  }
  return undefined;
}

function stringValue(value: unknown): string | undefined {
  if (typeof value === 'string') {
    const trimmed = value.trim();
    return trimmed === '' ? undefined : trimmed;
  }
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  return undefined;
}

function isObject(value: unknown): value is Json {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
