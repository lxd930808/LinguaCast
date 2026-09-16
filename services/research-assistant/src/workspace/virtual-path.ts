import { DomainError } from '../domain/types.js';

export const RESEARCH_SCHEME = 'research://';
export const SHARED_SCHEME = 'shared://';
export const GRANT_ALIAS_PATTERN = /^[a-z][a-z0-9-]{0,62}$/;
export const PATH_SEGMENT_PATTERN = /^[A-Za-z0-9._-]+$/;
export const BLOCKED_SEGMENTS = new Set(['.', '..', '.versions']);

const UNICODE_SEPARATORS = /[\u2044\u2215\u29F8\u29F9\uFF0F\uFF3C]/;
const WINDOWS_DRIVE = /^[A-Za-z]:/;

export type ParsedVirtualUri =
  | { kind: 'research'; alias: null; segments: string[]; canonical: string }
  | { kind: 'shared'; alias: string; segments: string[]; canonical: string };

function pathUnsafe(reason: string, uri?: string): DomainError {
  return new DomainError('WORKSPACE_PATH_UNSAFE', 'virtual path is not allowed', false, 400, {
    reason,
    ...(uri ? { uri } : {})
  });
}

export function formatResearchUri(segments: string[]): string {
  return segments.length === 0 ? RESEARCH_SCHEME : `${RESEARCH_SCHEME}${segments.join('/')}`;
}

export function formatSharedUri(alias: string, segments: string[]): string {
  return segments.length === 0 ? `${SHARED_SCHEME}${alias}` : `${SHARED_SCHEME}${alias}/${segments.join('/')}`;
}

export function splitRelativePath(rest: string, uri: string): string[] {
  if (rest === '') return [];
  if (rest.startsWith('/') || rest.startsWith('\\') || WINDOWS_DRIVE.test(rest)) {
    throw pathUnsafe('absolute or drive path is not allowed', uri);
  }
  const segments = rest.split('/');
  if (segments.some((segment) => segment === '')) {
    throw pathUnsafe('empty path segment is not allowed', uri);
  }
  for (const segment of segments) {
    if (BLOCKED_SEGMENTS.has(segment) || segment.startsWith('.tmp-') || !PATH_SEGMENT_PATTERN.test(segment)) {
      throw pathUnsafe('path segment is not allowed', uri);
    }
  }
  return segments;
}

export function parseVirtualUri(raw: string): ParsedVirtualUri {
  if (typeof raw !== 'string' || raw.length < RESEARCH_SCHEME.length || raw.length > 1024) {
    throw pathUnsafe('uri length is invalid');
  }
  if (raw.includes('\0') || raw.includes('\\') || raw.includes('%') || UNICODE_SEPARATORS.test(raw)) {
    throw pathUnsafe('encoded or non-canonical separator is not allowed', raw);
  }
  if (raw.startsWith(RESEARCH_SCHEME)) {
    const segments = splitRelativePath(raw.slice(RESEARCH_SCHEME.length), raw);
    return { kind: 'research', alias: null, segments, canonical: formatResearchUri(segments) };
  }
  if (raw.startsWith(SHARED_SCHEME)) {
    const rest = raw.slice(SHARED_SCHEME.length);
    const parts = splitRelativePath(rest, raw);
    if (parts.length === 0) {
      throw pathUnsafe('shared alias is required', raw);
    }
    const alias = parts[0] as string;
    if (!GRANT_ALIAS_PATTERN.test(alias)) {
      throw pathUnsafe('shared alias is not allowed', raw);
    }
    const segments = parts.slice(1);
    return { kind: 'shared', alias, segments, canonical: formatSharedUri(alias, segments) };
  }
  throw pathUnsafe('uri scheme is not allowed', raw);
}

export function joinVirtual(base: ParsedVirtualUri, extraSegments: string[]): string {
  const segments = [...base.segments, ...extraSegments];
  for (const segment of extraSegments) {
    if (BLOCKED_SEGMENTS.has(segment) || segment.startsWith('.tmp-') || !PATH_SEGMENT_PATTERN.test(segment)) {
      throw pathUnsafe('path segment is not allowed');
    }
  }
  return base.kind === 'research' ? formatResearchUri(segments) : formatSharedUri(base.alias, segments);
}
