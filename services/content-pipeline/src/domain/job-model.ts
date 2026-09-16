/**
 * Content job domain model: enums, state machine and progress rules.
 * Wire semantics are frozen by docs/contracts/content-job-v1.openapi.yaml.
 */

export type ContentType = 'podcast_episode' | 'video';
export type TranslationQuality = 'fast' | 'quality';

export type JobStatus = 'queued' | 'running' | 'ready' | 'failed' | 'cancelled' | 'expired';

export type JobStage =
  | 'validating_source'
  | 'fetching_audio'
  | 'preparing_audio'
  | 'transcribing'
  | 'segmenting'
  | 'translating'
  | 'refining_subtitles'
  | 'packaging'
  | 'completed';

export const STAGE_ORDER: readonly JobStage[] = [
  'validating_source',
  'fetching_audio',
  'preparing_audio',
  'transcribing',
  'segmenting',
  'translating',
  'refining_subtitles',
  'packaging',
  'completed'
];

/** Lower progress bound while a stage is active (contract §5 table). */
export const STAGE_PROGRESS_FLOOR: Record<JobStage, number> = {
  validating_source: 0,
  fetching_audio: 0.03,
  preparing_audio: 0.25,
  transcribing: 0.32,
  segmenting: 0.62,
  translating: 0.68,
  refining_subtitles: 0.92,
  packaging: 0.97,
  completed: 1
};

/** Upper progress bound while a stage is active. */
export const STAGE_PROGRESS_CEILING: Record<JobStage, number> = {
  validating_source: 0.03,
  fetching_audio: 0.25,
  preparing_audio: 0.32,
  transcribing: 0.62,
  segmenting: 0.68,
  translating: 0.92,
  refining_subtitles: 0.97,
  packaging: 1,
  completed: 1
};

const TERMINAL_STATUSES: ReadonlySet<JobStatus> = new Set(['ready', 'failed', 'cancelled', 'expired']);

export function isTerminalStatus(status: JobStatus): boolean {
  return TERMINAL_STATUSES.has(status);
}

/**
 * Legal state transitions. Anything else is rejected by the store so a buggy
 * worker or API call cannot corrupt the job lifecycle.
 */
const TRANSITIONS: Readonly<Record<JobStatus, ReadonlySet<JobStatus>>> = {
  queued: new Set(['running', 'cancelled', 'expired']),
  running: new Set(['running', 'ready', 'failed', 'cancelled', 'expired']),
  ready: new Set(['expired']),
  failed: new Set(['queued', 'expired', 'cancelled']),
  cancelled: new Set(['expired']),
  expired: new Set()
};

export function canTransition(from: JobStatus, to: JobStatus): boolean {
  return TRANSITIONS[from].has(to);
}

/** Polling hints (seconds) surfaced as retryAfterSeconds. */
export function pollHintSeconds(status: JobStatus, stage: JobStage | null): number {
  if (status === 'queued') return 2;
  if (status !== 'running') return 60;
  switch (stage) {
    case 'fetching_audio':
      return 3;
    case 'transcribing':
      return 5;
    case 'translating':
      return 8;
    default:
      return 4;
  }
}

export type JobErrorCode =
  | 'SOURCE_UNAVAILABLE'
  | 'SOURCE_RESTRICTED'
  | 'SOURCE_RATE_LIMITED'
  | 'AUDIO_DOWNLOAD_FAILED'
  | 'MEDIA_TOO_LARGE'
  | 'MEDIA_TOO_LONG'
  | 'UNSUPPORTED_AUDIO'
  | 'ASR_SUBMISSION_UNCERTAIN'
  | 'ASR_FAILED'
  | 'TRANSLATION_FAILED'
  | 'ARTIFACT_PUBLISH_FAILED'
  | 'STORAGE_FULL'
  | 'QUEUE_BUSY'
  | 'PIPELINE_VERSION_UNSUPPORTED'
  | 'INTERNAL_ERROR';

export interface JobError {
  code: JobErrorCode | string;
  message: string;
  retryable: boolean;
  retryAfterSeconds?: number;
  failedStage?: JobStage;
  traceId: string;
  params?: Record<string, unknown>;
}

export interface ContentSource {
  platform: 'rss' | 'youtube';
  sourceId: string;
  url: string;
  feedUrl?: string;
  title?: string;
}

export interface JobRow {
  jobId: string;
  ownerScope: string;
  contentType: ContentType;
  contentKey: string;
  source: ContentSource;
  sourceLanguage: string;
  targetLanguage: string;
  translationQuality: TranslationQuality;
  pipelineVersion: string;
  clientArtifactSchemaVersion: number;
  dedupeKey: string;
  idempotencyKey: string | null;
  requestFingerprint: string | null;
  status: JobStatus;
  stage: JobStage | null;
  progress: number;
  stageProgress: number | null;
  audioReady: boolean;
  subtitlesReady: boolean;
  error: JobError | null;
  artifacts: unknown | null;
  attemptCount: number;
  leaseOwner: string | null;
  leaseExpiresAt: number | null;
  createdAt: number;
  updatedAt: number;
  /** V18 quota: logical operation and account-service reservation paying for this job. */
  operationKey?: string | null;
  reservationId?: string | null;
  quotaSeconds?: number | null;
}
