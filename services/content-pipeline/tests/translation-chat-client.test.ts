import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createServer } from 'node:http';
import { once } from 'node:events';

import {
  mapHttpError,
  OpenAICompatibleTranslationProvider,
  TranslationEmptyContentError
} from '../src/providers/translation/chat-client.js';
import { TranslationProviderError } from '../src/providers/translation/types.js';

// Chat provider tests (WP6): scripted fetch proves request shape, transient
// retries with Retry-After, empty-content rejection and stable error mapping.

interface RecordedRequest {
  url: string;
  body: Record<string, unknown>;
  authorization: string | null;
}

function scriptedFetch(
  script: Array<{ status: number; body?: unknown; headers?: Record<string, string> } | Error>
): { fetchImpl: typeof fetch; calls: RecordedRequest[] } {
  const calls: RecordedRequest[] = [];
  const fetchImpl = (async (url: unknown, init?: { headers?: Record<string, string>; body?: string }) => {
    const headers = (init?.headers ?? {}) as Record<string, string>;
    calls.push({
      url: String(url),
      body: JSON.parse(String(init?.body ?? '{}')),
      authorization: headers.Authorization ?? null
    });
    const next = script.shift();
    if (!next) throw new Error('fetch script exhausted');
    if (next instanceof Error) throw next;
    return new Response(
      typeof next.body === 'string' ? next.body : JSON.stringify(next.body ?? {}),
      { status: next.status, headers: next.headers }
    );
  }) as unknown as typeof fetch;
  return { fetchImpl, calls };
}

function chatBody(content: string) {
  return { choices: [{ message: { content } }] };
}

const BASE_OPTIONS = {
  provider: 'openrouter',
  baseUrl: 'https://openrouter.ai/api',
  apiKey: 'test-key-0123456789',
  model: 'test-model',
  reasoningEffort: 'medium' as string | null,
  sleepImpl: async () => {}
};

test('posts to the versioned endpoint with bearer auth and policy body', async () => {
  const { fetchImpl, calls } = scriptedFetch([{ status: 200, body: chatBody('{"1":{}}') }]);
  const provider = new OpenAICompatibleTranslationProvider({ ...BASE_OPTIONS, fetchImpl });
  const content = await provider.chatCompletion({ systemPrompt: 'S', userPrompt: 'U' });
  assert.equal(content, '{"1":{}}');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://openrouter.ai/api/v1/chat/completions');
  assert.equal(calls[0].authorization, 'Bearer test-key-0123456789');
  assert.equal(calls[0].body.model, 'test-model');
  assert.deepEqual(calls[0].body.reasoning, { effort: 'medium' });
  assert.deepEqual(calls[0].body.messages, [
    { role: 'system', content: 'S' },
    { role: 'user', content: 'U' }
  ]);
});

test('openrouter retries 429 honoring Retry-After, then succeeds', async () => {
  const delays: number[] = [];
  const { fetchImpl, calls } = scriptedFetch([
    { status: 429, headers: { 'Retry-After': '3' } },
    { status: 200, body: chatBody('ok') }
  ]);
  const provider = new OpenAICompatibleTranslationProvider({
    ...BASE_OPTIONS,
    fetchImpl,
    sleepImpl: async (ms) => {
      delays.push(ms);
    }
  });
  assert.equal(await provider.chatCompletion({ systemPrompt: 'S', userPrompt: 'U' }), 'ok');
  assert.equal(calls.length, 2);
  assert.deepEqual(delays, [3000]);
});

test('dashscope 429 fails immediately (no transient retry, client parity)', async () => {
  const { fetchImpl, calls } = scriptedFetch([{ status: 429, headers: { 'Retry-After': '30' } }]);
  const provider = new OpenAICompatibleTranslationProvider({
    ...BASE_OPTIONS,
    provider: 'dashscope',
    baseUrl: 'https://dashscope.aliyuncs.com',
    fetchImpl
  });
  await assert.rejects(
    provider.chatCompletion({ systemPrompt: 'S', userPrompt: 'U' }),
    (error: unknown) => {
      assert.ok(error instanceof TranslationProviderError);
      assert.equal(error.retryable, true);
      assert.equal(error.retryAfterSeconds, 30);
      return true;
    }
  );
  assert.equal(calls.length, 1);
});

test('401 maps to a non-retryable provider error', async () => {
  const { fetchImpl } = scriptedFetch([{ status: 401 }]);
  const provider = new OpenAICompatibleTranslationProvider({ ...BASE_OPTIONS, fetchImpl });
  await assert.rejects(provider.chatCompletion({ systemPrompt: 'S', userPrompt: 'U' }), (error: unknown) => {
    assert.ok(error instanceof TranslationProviderError);
    assert.equal(error.retryable, false);
    assert.equal(error.status, 401);
    return true;
  });
});

test('empty content is rejected as a content failure', async () => {
  const { fetchImpl } = scriptedFetch([{ status: 200, body: chatBody('   ') }]);
  const provider = new OpenAICompatibleTranslationProvider({ ...BASE_OPTIONS, fetchImpl });
  await assert.rejects(
    provider.chatCompletion({ systemPrompt: 'S', userPrompt: 'U' }),
    TranslationEmptyContentError
  );
});

test('network failure respects configured retry count then maps to retryable provider error', async () => {
  const { fetchImpl, calls } = scriptedFetch([new Error('socket reset'), new Error('socket reset')]);
  const provider = new OpenAICompatibleTranslationProvider({ ...BASE_OPTIONS, networkRetries: 1, fetchImpl });
  await assert.rejects(provider.chatCompletion({ systemPrompt: 'S', userPrompt: 'U' }), (error: unknown) => {
    assert.ok(error instanceof TranslationProviderError);
    assert.equal(error.retryable, true);
    return true;
  });
  assert.equal(calls.length, 2);
});

test('mapHttpError covers the stable status classes', () => {
  assert.equal(mapHttpError(403, 'openrouter', {}).retryable, false);
  const limited = mapHttpError(429, 'dashscope', { 'retry-after': '12' });
  assert.equal(limited.retryable, true);
  assert.equal(limited.retryAfterSeconds, 12);
  assert.equal(mapHttpError(500, 'dashscope', {}).retryable, true);
  assert.equal(mapHttpError(404, 'openrouter', {}).retryable, false);
});

test('DeepSeek uses the App JSON request contract and retries transient failures', async () => {
  const { fetchImpl, calls } = scriptedFetch([
    { status: 503 }, { status: 200, body: chatBody('{"translation":"你好"}') }
  ]);
  const provider = new OpenAICompatibleTranslationProvider({
    ...BASE_OPTIONS, provider: 'deepseek', baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-v4-flash', reasoningEffort: 'max', fetchImpl
  });
  assert.equal(await provider.chatCompletion({ systemPrompt: 'Return JSON', userPrompt: 'Hello' }), '{"translation":"你好"}');
  assert.equal(calls.length, 2);
  assert.equal(calls[0].url, 'https://api.deepseek.com/v1/chat/completions');
  assert.equal(calls[0].authorization, 'Bearer test-key-0123456789');
  assert.deepEqual(calls[0].body, {
    model: 'deepseek-v4-flash', messages: [{ role: 'system', content: 'Return JSON' }, { role: 'user', content: 'Hello' }],
    temperature: 0.2, top_p: 0.7, reasoning_effort: 'max',
    response_format: { type: 'json_object' }, max_tokens: 8192
  });
});

// Simulate OpenRouter's early headers/keepalive followed by a stalled body.
function stalledResponse(signal: AbortSignal): Response {
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode(' '));
      signal.addEventListener('abort', () => controller.error(signal.reason), { once: true });
    }
  }));
}

test('timeout after headers retries the complete body with a fresh deadline', async () => {
  const signals: AbortSignal[] = [];
  const delays: number[] = [];
  const provider = new OpenAICompatibleTranslationProvider({
    ...BASE_OPTIONS, requestTimeoutMs: 15,
    sleepImpl: async (ms) => { delays.push(ms); },
    fetchImpl: async (_url, init) => {
      const signal = init!.signal!;
      signals.push(signal);
      return signals.length === 1 ? stalledResponse(signal) : new Response(JSON.stringify(chatBody('ok')));
    }
  });
  assert.equal(await provider.chatCompletion({ systemPrompt: 'S', userPrompt: 'U' }), 'ok');
  assert.equal(signals.length, 2);
  assert.equal(signals[0].aborted, true);
  assert.equal(signals[1].aborted, false);
  assert.notEqual(signals[0], signals[1]);
  assert.deepEqual(delays, [2000]);
});

test('body timeouts exhaust a bounded retry budget and become retryable provider errors', async () => {
  let calls = 0;
  const delays: number[] = [];
  const provider = new OpenAICompatibleTranslationProvider({
    ...BASE_OPTIONS, requestTimeoutMs: 10, networkRetries: 2,
    sleepImpl: async (ms) => { delays.push(ms); },
    fetchImpl: async (_url, init) => { calls++; return stalledResponse(init!.signal!); }
  });
  await assert.rejects(provider.chatCompletion({ systemPrompt: 'PRIVATE PROMPT', userPrompt: 'PRIVATE TEXT' }), (error: unknown) => {
    assert.ok(error instanceof TranslationProviderError);
    assert.equal(error.retryable, true);
    assert.match(error.message, /TimeoutError/);
    assert.ok(!error.message.includes('PRIVATE'));
    return true;
  });
  assert.equal(calls, 3);
  assert.deepEqual(delays, [2000, 4000]);
});

test('caller cancellation during body reading is propagated without retry', async () => {
  let calls = 0;
  const caller = new AbortController();
  const reason = new Error('cancelled by caller');
  const provider = new OpenAICompatibleTranslationProvider({
    ...BASE_OPTIONS,
    fetchImpl: async (_url, init) => {
      calls++;
      const response = stalledResponse(init!.signal!);
      queueMicrotask(() => caller.abort(reason));
      return response;
    }
  });
  await assert.rejects(provider.chatCompletion({ systemPrompt: 'S', userPrompt: 'U', signal: caller.signal }), reason);
  assert.equal(calls, 1);
});

test('caller cancellation interrupts retry backoff without another request', async () => {
  let calls = 0;
  const caller = new AbortController();
  const reason = new Error('cancelled during backoff');
  const provider = new OpenAICompatibleTranslationProvider({
    ...BASE_OPTIONS,
    fetchImpl: async () => { calls++; throw new Error('socket reset'); },
    sleepImpl: async () => { caller.abort(reason); }
  });
  await assert.rejects(provider.chatCompletion({ systemPrompt: 'S', userPrompt: 'U', signal: caller.signal }), reason);
  assert.equal(calls, 1);
});


test('native fetch retries a server that flushes headers then stalls its body', async () => {
  let calls = 0;
  const server = createServer((req, res) => {
    req.resume();
    calls++;
    res.writeHead(200, { 'Content-Type': 'application/json' });
    if (calls === 1) {
      res.flushHeaders();
      res.write(' ');
    } else {
      res.end(JSON.stringify(chatBody('ok')));
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const address = server.address();
    assert.ok(address && typeof address === 'object');
    const provider = new OpenAICompatibleTranslationProvider({
      ...BASE_OPTIONS, baseUrl: `http://127.0.0.1:${address.port}`,
      requestTimeoutMs: 150, networkRetries: 1
    });
    assert.equal(await provider.chatCompletion({ systemPrompt: 'Return JSON', userPrompt: 'test' }), 'ok');
    assert.equal(calls, 2);
  } finally {
    server.closeAllConnections();
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  }
});
