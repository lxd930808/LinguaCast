// WebVTT writer (WP6): port of the client's makeVTT shape — bare cue ids,
// dot-millisecond timestamps, one text line per cue, blank-line separated.
// Segment text is single-line by construction (interior whitespace was
// normalized during translation), so no additional escaping is required.

import type { LearningSegment } from '../segmentation/types.js';

export function formatVttTimestamp(totalMillisecondsInput: number): string {
  const totalMilliseconds = Math.max(0, Math.round(totalMillisecondsInput));
  const hours = Math.floor(totalMilliseconds / 3_600_000);
  const minutes = Math.floor((totalMilliseconds % 3_600_000) / 60_000);
  const seconds = Math.floor((totalMilliseconds % 60_000) / 1000);
  const milliseconds = totalMilliseconds % 1000;
  const pad = (value: number, width: number) => String(value).padStart(width, '0');
  return `${pad(hours, 2)}:${pad(minutes, 2)}:${pad(seconds, 2)}.${pad(milliseconds, 3)}`;
}

/** Cues with empty text are skipped; an empty segment list yields a header-only VTT. */
export function buildVtt(
  segments: LearningSegment[],
  textOf: (segment: LearningSegment) => string
): string {
  const lines = ['WEBVTT', ''];
  for (const segment of segments) {
    const text = textOf(segment).trim();
    if (text.length === 0) continue;
    lines.push(String(segment.sequence));
    lines.push(`${formatVttTimestamp(segment.startMS)} --> ${formatVttTimestamp(segment.endMS)}`);
    lines.push(text);
    lines.push('');
  }
  return lines.join('\n');
}

export function buildSourceVtt(segments: LearningSegment[]): string {
  return buildVtt(segments, (s) => s.text);
}

export function buildTargetVtt(segments: LearningSegment[]): string {
  return buildVtt(segments, (s) => s.translation);
}
