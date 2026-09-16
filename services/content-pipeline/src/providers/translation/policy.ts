// Provider policy (WP6): port of the Swift TranslationProviderPolicy /
// TranslationChatRequestPolicy / TranslationChatResponsePolicy /
// TranslationRetryPolicy semantics for DashScope, OpenRouter and DeepSeek.

import type { TranslationChatMessage } from './types.js';

export type TranslationProviderId = 'dashscope' | 'openrouter' | 'deepseek';

export function normalizedProvider(value: string): TranslationProviderId {
  const id = value.trim().toLowerCase();
  return id === 'openrouter' || id === 'deepseek' ? id : 'dashscope';
}

/**
 * Chat-completions endpoint. Accepts a bare host-style base URL or an
 * already-versioned one so deployments can point at any OpenAI-compatible
 * gateway without double `/v1` segments.
 */
export function chatCompletionsUrl(provider: string, configuredBaseUrl: string): string {
  const id = normalizedProvider(provider);
  let base = configuredBaseUrl.trim().replace(/\/+$/, '');
  if (id === 'dashscope') {
    if (!base.endsWith('/compatible-mode/v1') && !base.endsWith('/v1')) {
      base += '/compatible-mode/v1';
    }
  } else if (!base.endsWith('/v1')) {
    base += '/v1';
  }
  return `${base}/chat/completions`;
}

/**
 * Request body parity with the Swift client: temperature 0.2 / top_p 0.7.
 * OpenRouter takes a nested `reasoning` object; DashScope follows the client
 * and sends no reasoning field. Unconfigured OpenRouter effort is omitted.
 * DeepSeek uses the App default high effort and requires JSON output.
 */
export function requestBody(
  provider: string,
  model: string,
  reasoningEffort: string | null,
  messages: TranslationChatMessage[]
): Record<string, unknown> {
  const id = normalizedProvider(provider);
  const body: Record<string, unknown> = {
    model,
    messages,
    temperature: 0.2,
    top_p: 0.7
  };
  if (id === 'openrouter' && reasoningEffort !== null) {
    body.reasoning = { effort: reasoningEffort };
  }
  if (id === 'deepseek') {
    body.reasoning_effort = reasoningEffort ?? 'high';
    body.response_format = { type: 'json_object' };
    body.max_tokens = 8192;
  }
  return body;
}

/** Transient HTTP statuses follow the Swift provider policy. */
export function retriesTransientHTTPStatus(provider: string): boolean {
  return ['openrouter', 'deepseek'].includes(normalizedProvider(provider));
}

export function shouldRetryHTTPStatus(statusCode: number, provider: string): boolean {
  if (!retriesTransientHTTPStatus(provider)) return false;
  return statusCode === 429 || statusCode === 500 || statusCode === 503;
}

/**
 * Delay before the next attempt. A positive Retry-After header wins on 429;
 * otherwise exponential backoff 2s → 4s → 8s (capped), as in the client.
 */
export function retryDelaySeconds(
  statusCode: number,
  provider: string,
  attempt: number,
  headers: Record<string, string>
): number | null {
  if (!shouldRetryHTTPStatus(statusCode, provider)) return null;
  if (statusCode === 429) {
    const retryAfter = headerValue('Retry-After', headers);
    if (retryAfter !== null) {
      const seconds = Number.parseInt(retryAfter.trim(), 10);
      if (Number.isFinite(seconds) && seconds > 0) return seconds;
    }
  }
  const exponent = Math.max(0, attempt - 1);
  return Math.min(8, 2 * 2 ** exponent);
}

/** Numbered batches stay small so origins survive verbatim (client parity). */
export const BATCH_MAX_ITEMS = 10;
export const BATCH_MAX_CHARACTERS = 600;

/** Concurrent chat requests per job. Small batches tolerate modest fan-out. */
export function maxConcurrentRequests(_provider: string): number {
  return 3;
}

/** choices[0].message.content extraction (TranslationChatResponsePolicy). */
export function extractContent(responseJson: unknown): string | null {
  if (typeof responseJson !== 'object' || responseJson === null) return null;
  const choices = (responseJson as { choices?: unknown }).choices;
  if (!Array.isArray(choices) || choices.length === 0) return null;
  const message = (choices[0] as { message?: unknown })?.message;
  if (typeof message !== 'object' || message === null) return null;
  const content = (message as { content?: unknown }).content;
  return typeof content === 'string' ? content : null;
}

export function isEmptyContent(content: string | null): boolean {
  return content === null || content.trim().length === 0;
}

function headerValue(name: string, headers: Record<string, string>): string | null {
  const lower = name.toLowerCase();
  for (const [key, value] of Object.entries(headers)) {
    if (key.toLowerCase() === lower) return value;
  }
  return null;
}
