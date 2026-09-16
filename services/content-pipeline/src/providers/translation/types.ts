// Translation provider abstraction (WP6). The server owns provider, base URL,
// model and reasoning effort; a job request only carries quality mode and
// target language. Provider raw errors are mapped to stable job error codes
// at the stage boundary — prompts and API keys never appear in logs.

export interface TranslationChatMessage {
  role: 'system' | 'user';
  content: string;
}

export interface TranslationChatCall {
  systemPrompt: string;
  userPrompt: string;
  signal?: AbortSignal;
}

export interface TranslationProvider {
  readonly name: string;
  readonly model: string;
  /** Returns the assistant message content; throws TranslationProviderError. */
  chatCompletion(call: TranslationChatCall): Promise<string>;
}

/**
 * Provider-side failure (HTTP status, network). `retryable` drives job-level
 * retry; `retryAfterSeconds` surfaces a provider Retry-After hint.
 */
export class TranslationProviderError extends Error {
  constructor(
    message: string,
    readonly options: {
      retryable: boolean;
      status?: number;
      retryAfterSeconds?: number;
    }
  ) {
    super(message);
    this.name = 'TranslationProviderError';
  }

  get retryable(): boolean {
    return this.options.retryable;
  }

  get status(): number | undefined {
    return this.options.status;
  }

  get retryAfterSeconds(): number | undefined {
    return this.options.retryAfterSeconds;
  }
}
