// OpenAI-compatible chat provider (WP6). Handles request-body construction,
// transient-status retries with Retry-After, empty-content rejection and
// stable error mapping. Privacy: prompts and keys are never logged; error
// messages carry only status/provider metadata.

import {
  chatCompletionsUrl,
  extractContent,
  isEmptyContent,
  normalizedProvider,
  requestBody,
  retryDelaySeconds,
  shouldRetryHTTPStatus
} from './policy.js';
import {
  TranslationProviderError,
  type TranslationChatCall,
  type TranslationProvider
} from './types.js';

export interface ChatProviderOptions {
  provider: string;
  baseUrl: string;
  apiKey: string;
  model: string;
  reasoningEffort: string | null;
  /** Injectable for tests. */
  fetchImpl?: typeof fetch;
  /** Injectable for tests (defaults to a real timer). */
  sleepImpl?: (ms: number) => Promise<void>;
  /** Max HTTP attempts for retryable statuses (client parity: 4). */
  maxAttempts?: number;
  /** Retries for transport failures (DNS/reset/timeout, including response bodies), separate budget. */
  networkRetries?: number;
  requestTimeoutMs?: number;
}

export class OpenAICompatibleTranslationProvider implements TranslationProvider {
  readonly name: string;
  readonly model: string;
  private readonly url: string;
  private readonly apiKey: string;
  private readonly reasoningEffort: string | null;
  private readonly fetchImpl: typeof fetch;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly maxAttempts: number;
  private readonly networkRetries: number;
  private readonly requestTimeoutMs: number;

  constructor(options: ChatProviderOptions) {
    this.name = normalizedProvider(options.provider);
    this.model = options.model;
    this.url = chatCompletionsUrl(options.provider, options.baseUrl);
    this.apiKey = options.apiKey;
    this.reasoningEffort = options.reasoningEffort;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.sleep = options.sleepImpl ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.maxAttempts = options.maxAttempts ?? 4;
    this.networkRetries = options.networkRetries ?? 2;
    this.requestTimeoutMs = options.requestTimeoutMs ?? 300_000;
  }

  async chatCompletion(call: TranslationChatCall): Promise<string> {
    const body = requestBody(this.name, this.model, this.reasoningEffort, [
      { role: 'system', content: call.systemPrompt },
      { role: 'user', content: call.userPrompt }
    ]);
    const data = await this.sendWithRetries(body, call.signal);
    let json: unknown;
    try {
      json = JSON.parse(data);
    } catch {
      throw new TranslationProviderError('translation response is not valid JSON', {
        retryable: true
      });
    }
    const content = extractContent(json);
    if (isEmptyContent(content)) {
      // Surfaced as a content failure so the batch layer can retry the prompt.
      throw new TranslationEmptyContentError();
    }
    return content as string;
  }

  private async sendWithRetries(body: Record<string, unknown>, signal?: AbortSignal): Promise<string> {
    let attempt = 1;
    let networkAttemptsLeft = this.networkRetries;
    for (;;) {
      signal?.throwIfAborted();
      let response: Response;
      let text: string;
      const controller = new AbortController();
      const onAbort = () => controller.abort(signal?.reason);
      signal?.addEventListener('abort', onAbort, { once: true });
      const timeout = setTimeout(
        () => controller.abort(new DOMException('Translation request timed out', 'TimeoutError')),
        this.requestTimeoutMs
      );
      try {
        response = await this.fetchImpl(this.url, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${this.apiKey}`,
            'Content-Type': 'application/json'
          },
          body: JSON.stringify(body),
          signal: controller.signal
        });
        // Headers can arrive long before the model finishes its response.
        text = await response.text();
      } catch (error) {
        if (signal?.aborted) throw signal.reason;
        if (networkAttemptsLeft > 0) {
          networkAttemptsLeft -= 1;
          clearTimeout(timeout);
          signal?.removeEventListener('abort', onAbort);
          const retryIndex = this.networkRetries - networkAttemptsLeft - 1;
          await this.waitBeforeRetry(Math.min(8000, 2000 * 2 ** retryIndex), signal);
          continue;
        }
        throw new TranslationProviderError(
          `translation request failed: ${error instanceof Error ? error.name : 'network error'}`,
          { retryable: true }
        );
      } finally {
        clearTimeout(timeout);
        signal?.removeEventListener('abort', onAbort);
      }

      if (response.status >= 200 && response.status < 300) {
        return text;
      }

      const headers: Record<string, string> = {};
      response.headers.forEach((value, key) => {
        headers[key] = value;
      });
      if (shouldRetryHTTPStatus(response.status, this.name) && attempt < this.maxAttempts) {
        const delay = retryDelaySeconds(response.status, this.name, attempt, headers) ?? 2;
        await this.waitBeforeRetry(delay * 1000, signal);
        attempt += 1;
        continue;
      }
      throw mapHttpError(response.status, this.name, headers);
    }
  }

  private async waitBeforeRetry(ms: number, signal?: AbortSignal): Promise<void> {
    signal?.throwIfAborted();
    if (!signal) return this.sleep(ms);
    let onAbort: () => void = () => {};
    const aborted = new Promise<never>((_, reject) => {
      onAbort = () => reject(signal.reason);
      signal.addEventListener('abort', onAbort, { once: true });
    });
    try {
      await Promise.race([this.sleep(ms), aborted]);
    } finally {
      signal.removeEventListener('abort', onAbort);
    }
  }
}

/** Empty assistant content: treated like a malformed batch by the parser layer. */
export class TranslationEmptyContentError extends Error {
  constructor() {
    super('translation response has empty content');
    this.name = 'TranslationEmptyContentError';
  }
}

/** Stable mapping from raw provider statuses to job-facing semantics. */
export function mapHttpError(
  status: number,
  provider: string,
  headers: Record<string, string>
): TranslationProviderError {
  if (status === 401 || status === 403) {
    return new TranslationProviderError(`translation provider ${provider} rejected credentials`, {
      retryable: false,
      status
    });
  }
  if (status === 429) {
    const retryAfter = headers['retry-after'] ?? headers['Retry-After'];
    const seconds = retryAfter ? Number.parseInt(retryAfter.trim(), 10) : NaN;
    return new TranslationProviderError(`translation provider ${provider} rate limited the request`, {
      retryable: true,
      status,
      retryAfterSeconds: Number.isFinite(seconds) && seconds > 0 ? seconds : undefined
    });
  }
  if (status >= 500) {
    return new TranslationProviderError(`translation provider ${provider} returned ${status}`, {
      retryable: true,
      status
    });
  }
  return new TranslationProviderError(`translation provider ${provider} returned ${status}`, {
    retryable: false,
    status
  });
}
