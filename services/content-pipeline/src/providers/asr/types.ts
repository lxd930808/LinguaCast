// Transcription provider abstraction (WP5). The first implementation is
// DashScope recorded transcription; tests use fakes. Submit is NOT idempotent
// — the pipeline calls it exactly once per audio fingerprint and persists the
// task ID immediately.

export type AsrTaskStatus = 'PENDING' | 'RUNNING' | 'SUCCEEDED' | 'FAILED' | 'CANCELED' | 'UNKNOWN';

export interface AsrSubmitInput {
  /** Publicly fetchable (pre-signed) audio URL. */
  audioUrl: string;
  language?: string;
}

export interface AsrPollResult {
  status: AsrTaskStatus;
  /** Present when status === 'SUCCEEDED'. */
  transcriptionUrl?: string;
  /** Provider-suggested delay before the next poll. */
  retryAfterMs?: number;
  /** Failure detail for terminal states. */
  failureMessage?: string;
}

export interface TranscriptionProvider {
  readonly name: string;
  /**
   * Creates a transcription task and returns its ID. Implementations must
   * attempt the POST at most once: when the outcome of the request is
   * unknown (timeout / connection drop after the request may have been
   * processed) they throw AsrSubmissionUncertainError instead of retrying.
   */
  submit(input: AsrSubmitInput): Promise<string>;
  /** Queries task state. Polling IS idempotent and may retry internally. */
  poll(taskId: string): Promise<AsrPollResult>;
}

/**
 * The submit request's outcome is unknown (network failure or timeout after
 * the request could have reached the provider). The pipeline must fail the
 * job with ASR_SUBMISSION_UNCERTAIN and never auto-create a second task.
 */
export class AsrSubmissionUncertainError extends Error {
  constructor(message: string, readonly cause?: unknown) {
    super(message);
    this.name = 'AsrSubmissionUncertainError';
  }
}

/** The provider definitively refused or failed the task. */
export class AsrProviderError extends Error {
  constructor(
    message: string,
    readonly retryable: boolean,
    readonly retryAfterSeconds?: number
  ) {
    super(message);
    this.name = 'AsrProviderError';
  }
}
