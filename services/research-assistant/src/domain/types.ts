export type SessionPhase =
  | 'researching'
  | 'report_ready'
  | 'source_selected'
  | 'preparing_content'
  | 'transcript_ready'
  | 'qa_ready'
  | 'recoverable_error'
  | 'deleting'
  | 'deleted';

export type TurnKind = 'research' | 'qa';
export type TurnStatus = 'queued' | 'running' | 'completed' | 'failed' | 'cancelled';
export type TranslationQuality = 'fast' | 'quality';
export type Platform = 'youtube' | 'apple_podcasts';
export type SourceType = 'video' | 'podcast_show' | 'podcast_episode';

export const SESSION_TRANSITIONS: Record<SessionPhase, SessionPhase[]> = {
  researching: ['report_ready', 'recoverable_error', 'deleting'],
  report_ready: ['source_selected', 'researching', 'deleting'],
  source_selected: ['preparing_content', 'recoverable_error', 'deleting'],
  preparing_content: ['transcript_ready', 'recoverable_error', 'deleting'],
  transcript_ready: ['qa_ready', 'recoverable_error', 'deleting'],
  qa_ready: ['source_selected', 'preparing_content', 'recoverable_error', 'deleting'],
  recoverable_error: [
    'researching',
    'report_ready',
    'source_selected',
    'preparing_content',
    'transcript_ready',
    'qa_ready',
    'deleting'
  ],
  deleting: ['deleted'],
  deleted: []
};

export function canTransition(from: SessionPhase, to: SessionPhase): boolean {
  return SESSION_TRANSITIONS[from]?.includes(to) === true;
}

export class DomainError extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly retryable = false,
    public readonly httpStatus = 409,
    public readonly params: Record<string, unknown> = {}
  ) {
    super(message);
    this.name = 'DomainError';
  }
}

export function describeUnknownError(value: unknown): string {
  if (value instanceof Error) return sanitizePublicText(value.message);
  if (typeof value === 'string' && value.trim()) return sanitizePublicText(value);
  if (value && typeof value === 'object') {
    const record = value as Record<string, unknown>;
    if (typeof record.message === 'string' && record.message.trim()) return sanitizePublicText(record.message);
    if (typeof record.error === 'string' && record.error.trim()) return sanitizePublicText(record.error);
    try {
      const json = JSON.stringify(value);
      if (json && json !== '{}') return sanitizePublicText(json.slice(0, 500));
    } catch {
      // ignore circular objects
    }
  }
  return 'unknown error';
}

const BLOCKED_PARAM_KEYS = new Set([
  'path',
  'relativePath',
  'realPath',
  'absolutePath',
  'cwd',
  'argv',
  'headers',
  'authorization',
  'cookie',
  'token',
  'apiKey',
  'secret'
]);

const FS_PATH = /(^|[\s"'=])(\/(?:var|tmp|Users|home|etc|usr|private|Volumes|opt)\/[^\s"']+)/g;
const WINDOWS_PATH = /(^|[\s"'=])([A-Za-z]:\\[^\s"']+)/g;

export function sanitizePublicText(text: string): string {
  return text
    .replace(FS_PATH, '$1[redacted-path]')
    .replace(WINDOWS_PATH, '$1[redacted-path]')
    .replace(/Bearer\s+\S+/gi, 'Bearer [REDACTED]')
    .replace(/X-Amz-[^=\s]+=[^\s&]+/gi, 'X-Amz-[REDACTED]')
    .replace(/(api[_-]?key|secret|token|cookie)\s*[:=]\s*\S+/gi, '$1=[REDACTED]');
}

export function sanitizePublicParams(params: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(params)) {
    if (BLOCKED_PARAM_KEYS.has(key)) continue;
    if (typeof value === 'string') {
      if (value.startsWith('/') && !value.startsWith('research://') && !value.startsWith('shared://')) continue;
      out[key] = sanitizePublicText(value);
      continue;
    }
    if (value == null || typeof value === 'number' || typeof value === 'boolean') {
      out[key] = value;
    }
  }
  return out;
}

export function publicErrorFields(error: DomainError): {
  code: string;
  message: string;
  retryable: boolean;
  params: Record<string, unknown>;
} {
  return {
    code: error.code,
    message: sanitizePublicText(error.message),
    retryable: error.retryable,
    params: sanitizePublicParams(error.params)
  };
}
