import {
  AsrProviderError,
  AsrSubmissionUncertainError,
  type AsrPollResult,
  type AsrSubmitInput,
  type TranscriptionProvider
} from './types.js';

// DashScope recorded transcription (WP5) — mirrors the Swift
// DashScopeTranscriptionClient contract:
//   POST {base}/api/v1/services/audio/asr/transcription  (X-DashScope-Async)
//   GET  {base}/api/v1/tasks/{taskId}
// Model paraformer-v2 with word timestamps + diarization, speaker cap 4.

export interface DashScopeAsrOptions {
  apiKey: string;
  baseUrl?: string;
  model?: string;
  speakerCount?: number;
  fetchImpl?: typeof fetch;
  submitTimeoutMs?: number;
  pollTimeoutMs?: number;
}

export class DashScopeTranscriptionProvider implements TranscriptionProvider {
  readonly name = 'dashscope';
  private readonly baseUrl: string;
  private readonly model: string;
  private readonly speakerCount: number;
  private readonly fetchImpl: typeof fetch;
  private readonly submitTimeoutMs: number;
  private readonly pollTimeoutMs: number;

  constructor(private readonly options: DashScopeAsrOptions) {
    this.baseUrl = (options.baseUrl ?? 'https://dashscope.aliyuncs.com').replace(/\/+$/, '');
    this.model = options.model ?? 'paraformer-v2';
    this.speakerCount = options.speakerCount ?? 4;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.submitTimeoutMs = options.submitTimeoutMs ?? 30_000;
    this.pollTimeoutMs = options.pollTimeoutMs ?? 30_000;
  }

  async submit(input: AsrSubmitInput): Promise<string> {
    let response: Response;
    try {
      response = await this.fetchImpl(`${this.baseUrl}/api/v1/services/audio/asr/transcription`, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${this.options.apiKey}`,
          accept: 'application/json',
          'content-type': 'application/json',
          'x-dashscope-async': 'enable',
          'x-dashscope-ossresourceresolve': 'enable'
        },
        body: JSON.stringify({
          model: this.model,
          input: { file_urls: [input.audioUrl] },
          parameters: {
            timestamp_alignment_enabled: true,
            diarization_enabled: true,
            speaker_count: this.speakerCount
          }
        }),
        signal: AbortSignal.timeout(this.submitTimeoutMs)
      });
    } catch (error) {
      // The task may have been created server-side; never auto-retry submit.
      throw new AsrSubmissionUncertainError(
        `submit outcome unknown: ${error instanceof Error ? error.message : String(error)}`,
        error
      );
    }

    const text = await response.text();
    let json: Record<string, unknown> | null = null;
    try {
      json = JSON.parse(text) as Record<string, unknown>;
    } catch {
      json = null;
    }

    if (!response.ok) {
      const detail = errorDetail(json) ?? `HTTP ${response.status}`;
      const retryable = response.status === 429 || response.status >= 500;
      const retryAfter = Number(response.headers.get('retry-after'));
      throw new AsrProviderError(
        `DashScope submit failed: ${detail}`,
        retryable,
        Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : undefined
      );
    }

    const output = json?.output as Record<string, unknown> | undefined;
    const taskId = output?.task_id;
    if (typeof taskId === 'string' && taskId.length > 0) return taskId;
    // A 2xx without task_id is an ambiguous outcome: treat as uncertain.
    throw new AsrSubmissionUncertainError('DashScope submit returned no task_id');
  }

  async poll(taskId: string): Promise<AsrPollResult> {
    const url = `${this.baseUrl}/api/v1/tasks/${encodeURIComponent(taskId)}`;
    const attempts = [0, 3_000, 6_000]; // bounded: 3 attempts, fixed delays
    let lastError: unknown = null;

    for (let attempt = 0; attempt < attempts.length; attempt += 1) {
      if (attempt > 0) await sleep(attempts[attempt]);
      let response: Response;
      try {
        response = await this.fetchImpl(url, {
          headers: {
            authorization: `Bearer ${this.options.apiKey}`,
            accept: 'application/json'
          },
          signal: AbortSignal.timeout(this.pollTimeoutMs)
        });
      } catch (error) {
        lastError = error;
        continue;
      }

      if (response.status === 429 || response.status >= 500) {
        const retryAfter = Number(response.headers.get('retry-after'));
        if (attempt === attempts.length - 1) {
          throw new AsrProviderError(
            `DashScope poll failed: HTTP ${response.status}`,
            true,
            Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : undefined
          );
        }
        lastError = new Error(`HTTP ${response.status}`);
        continue;
      }
      if (!response.ok) {
        const text = await response.text();
        throw new AsrProviderError(`DashScope poll failed: HTTP ${response.status} ${text.slice(0, 200)}`, false);
      }

      let json: Record<string, unknown>;
      try {
        json = (await response.json()) as Record<string, unknown>;
      } catch (error) {
        lastError = error;
        continue;
      }
      const output = json.output as Record<string, unknown> | undefined;
      const status = typeof output?.task_status === 'string' ? output.task_status : 'UNKNOWN';

      if (status === 'SUCCEEDED') {
        const results = output?.results as Array<Record<string, unknown>> | undefined;
        const transcriptionUrl =
          (typeof results?.[0]?.transcription_url === 'string' && results[0].transcription_url) ||
          (typeof output?.transcription_url === 'string' ? output.transcription_url : undefined);
        if (!transcriptionUrl) {
          throw new AsrProviderError('DashScope task succeeded without transcription_url', false);
        }
        return { status: 'SUCCEEDED', transcriptionUrl };
      }
      if (status === 'FAILED' || status === 'CANCELED' || status === 'UNKNOWN') {
        throw new AsrProviderError(
          `DashScope task ended with status ${status}: ${errorDetail(json) ?? 'no detail'}`,
          status === 'FAILED'
        );
      }
      return { status: status === 'RUNNING' ? 'RUNNING' : 'PENDING' };
    }

    throw new AsrProviderError(
      `DashScope poll unreachable: ${lastError instanceof Error ? lastError.message : String(lastError)}`,
      true
    );
  }
}

function errorDetail(json: Record<string, unknown> | null): string | null {
  if (!json) return null;
  const pieces = [json.code, json.message, json.request_id]
    .filter((v): v is string => typeof v === 'string' && v.length > 0);
  const output = json.output as Record<string, unknown> | undefined;
  if (output) {
    for (const value of [output.code, output.message]) {
      if (typeof value === 'string' && value.length > 0) pieces.push(value);
    }
  }
  return pieces.length > 0 ? pieces.join(' / ') : null;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    timer.unref?.();
  });
}
