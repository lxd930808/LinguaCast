import type {
  V2ArtifactRecord,
  V2CitationRecord,
  V2GrantRecord,
  V2MessageRecord,
  V2ResearchRecord,
  V2TurnRecord
} from '../../db/v2/store.js';
import { DomainError } from '../../domain/types.js';
import type { MemorySnapshot } from '../../memory/types.js';
import type { TranscriptJobWire } from '../../content/v2/transcript-jobs.js';
import type { TurnWork } from './turn-work.js';

export const ARTIFACT_COUNT_KINDS = [
  'web_search',
  'web_page',
  'podcast_search',
  'youtube_search',
  'transcript',
  'research_memory',
  'report'
] as const;

const PATH_KEYS = new Set([
  'path',
  'relativePath',
  'uri',
  'fileName',
  'filename',
  'realPath',
  'absolutePath'
]);

export const ARTIFACT_BODY_MAX_BYTES = 64 * 1024;

export function eventsUrl(turnId: string): string {
  return `/v2/assistant/turns/${turnId}/events`;
}

export function artifactCounts(artifacts: Array<{ kind: string; status: string }>): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const kind of ARTIFACT_COUNT_KINDS) counts[kind] = 0;
  for (const artifact of artifacts) {
    if (artifact.status !== 'ready') continue;
    counts[artifact.kind] = (counts[artifact.kind] ?? 0) + 1;
  }
  return counts;
}

export function projectGrant(grant: V2GrantRecord): Record<string, unknown> {
  return {
    alias: grant.alias,
    permission: grant.permission,
    allowedExtensions: grant.allowedExtensions,
    maxFileBytes: grant.maxFileBytes,
    grantedAt: grant.grantedAt,
    status: grant.status
  };
}

export function projectArtifact(artifact: V2ArtifactRecord): Record<string, unknown> {
  return {
    artifactId: artifact.artifactId,
    researchId: artifact.researchId,
    kind: artifact.kind,
    status: artifact.status,
    mediaType: artifact.mediaType,
    bytes: artifact.bytes,
    sha256: artifact.sha256,
    producer: artifact.producer,
    sourceReference: projectSourceReference(artifact.sourceReference),
    evidenceLevel: artifact.evidenceLevel,
    createdAt: artifact.createdAt,
    updatedAt: artifact.updatedAt
  };
}

function projectSourceReference(value: unknown): unknown {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  if (typeof row.platform !== 'string' || typeof row.sourceId !== 'string' || typeof row.canonicalURL !== 'string') {
    return null;
  }
  return value;
}

export function projectCitation(citation: V2CitationRecord): Record<string, unknown> {
  return {
    citationId: citation.citationId,
    artifactId: citation.artifactId,
    evidenceLevel: citation.evidenceLevel,
    label: citation.label,
    passageId: citation.passageId,
    startMilliseconds: citation.startMs,
    endMilliseconds: citation.endMs,
    sourceURL: citation.sourceUrl,
    contentKey: citation.contentKey,
    quote: citation.quote,
    sha256: citation.sha256
  };
}

export function projectMessage(
  message: V2MessageRecord,
  citations: V2CitationRecord[]
): Record<string, unknown> {
  return {
    messageId: message.messageId,
    researchId: message.researchId,
    turnId: message.turnId,
    role: message.role,
    markdown: message.markdown,
    citations: citations.filter((citation) => citation.messageId === message.messageId).map(projectCitation),
    createdAt: message.createdAt
  };
}

export function projectTurn(turn: V2TurnRecord): Record<string, unknown> {
  return {
    turnId: turn.turnId,
    researchId: turn.researchId,
    mode: turn.mode,
    status: turn.status,
    eventsURL: eventsUrl(turn.turnId),
    error: turn.errorCode
      ? {
          code: turn.errorCode,
          message: turn.errorMessage ?? turn.errorCode,
          retryable: false,
          traceId: `tr_${turn.turnId.slice(3, 23)}`
        }
      : null,
    skillName: turn.skillName ?? undefined,
    skillVersion: turn.skillVersion ?? undefined,
    skillSha256: turn.skillSha256 ?? undefined,
    createdAt: turn.createdAt,
    startedAt: turn.startedAt,
    finishedAt: turn.finishedAt
  };
}

export function projectTurnAccepted(turn: V2TurnRecord, reused: boolean): Record<string, unknown> {
  return {
    turnId: turn.turnId,
    researchId: turn.researchId,
    mode: turn.mode,
    status: turn.status,
    eventsURL: eventsUrl(turn.turnId),
    reused
  };
}

export function projectResearch(
  research: V2ResearchRecord,
  artifacts: Array<{ kind: string; status: string }>,
  grants: V2GrantRecord[]
): Record<string, unknown> {
  return {
    researchId: research.researchId,
    title: research.title,
    phase: research.status,
    status: research.status,
    workspaceStatus: research.workspaceStatus,
    outputLanguage: research.outputLanguage,
    storefront: research.storefront,
    targetLanguage: research.targetLanguage,
    translationQuality: research.translationQuality,
    activeTurnId: research.activeTurnId,
    artifactCounts: artifactCounts(artifacts),
    grants: grants.map(projectGrant),
    createdAt: research.createdAt,
    updatedAt: research.updatedAt
  };
}

export function projectSnapshot(input: {
  research: V2ResearchRecord;
  messages: V2MessageRecord[];
  artifacts: V2ArtifactRecord[];
  grants: V2GrantRecord[];
  citations: V2CitationRecord[];
  memory: MemorySnapshot;
  activeTurn: V2TurnRecord | null;
  turnWork?: TurnWork[];
}): Record<string, unknown> {
  const reports = input.artifacts.filter((artifact) => artifact.kind === 'report' && artifact.status === 'ready');
  return {
    ...projectResearch(input.research, input.artifacts, input.grants),
    messages: input.messages.map((message) => projectMessage(message, input.citations)),
    artifacts: input.artifacts.map(projectArtifact),
    memory: input.memory,
    latestReportArtifactId: reports[0]?.artifactId ?? null,
    activeTurn: input.activeTurn ? projectTurn(input.activeTurn) : null,
    ...(input.turnWork ? { turnWork: input.turnWork } : {})
  };
}

export function projectTranscriptJob(job: TranscriptJobWire): Record<string, unknown> {
  return { ...job };
}

export function truncateArtifactText(text: string, maxBytes = ARTIFACT_BODY_MAX_BYTES): { text: string; truncated: boolean } {
  const bytes = Buffer.byteLength(text, 'utf8');
  if (bytes <= maxBytes) return { text, truncated: false };
  let end = text.length;
  while (end > 0 && Buffer.byteLength(text.slice(0, end), 'utf8') > maxBytes) {
    end -= 1;
  }
  return { text: text.slice(0, end), truncated: true };
}

export function rejectPathQuery(search: URLSearchParams): void {
  for (const key of search.keys()) {
    if (PATH_KEYS.has(key)) {
      throw new DomainError('INVALID_REQUEST', 'artifact routes do not accept path parameters', false, 400, {
        field: key
      });
    }
  }
}

export function encodeListCursor(updatedAt: string, id: string): string {
  return Buffer.from(`${updatedAt}|${id}`, 'utf8').toString('base64url');
}

export function decodeListCursor(cursor: string | null): { updatedAt: string; id: string } | null {
  if (!cursor) return null;
  const raw = Buffer.from(cursor, 'base64url').toString('utf8');
  const [updatedAt, id] = raw.split('|');
  if (!updatedAt || !id) return null;
  return { updatedAt, id };
}
