export const DIRECT_RANGE_CHUNK_SIZE = 10 * 1024 * 1024;
const DEFAULT_MAX_ATTEMPTS_PER_CHUNK = 4;

export interface DirectMediaIdentity {
  itag: number;
  mimeType: string | null;
  contentLength: number;
  lastModified: string | null;
}

export interface DirectMediaResource {
  url: string;
  identity: DirectMediaIdentity;
}

export interface DirectRangeDiagnostic {
  kind: 'chunk-complete' | 'retry' | 'url-refresh';
  itag: number;
  offset: number;
  rangeStart: number;
  rangeEnd: number;
  attempt: number;
  causeCode?: string;
  causeMessage?: string;
  httpStatus?: number;
  retryAfterMs?: number;
  responseHeaders?: Record<string, string | null>;
}

export interface ResumableRangeStreamOptions {
  url: string;
  identity: DirectMediaIdentity;
  startOffset?: number;
  chunkSize?: number;
  maxAttemptsPerChunk?: number;
  signal?: AbortSignal;
  fetch?: typeof fetch;
  retryDelayMs?: (failedAttempt: number) => number;
  nowMs?: () => number;
  refreshBeforeExpirySec?: number;
  maxTotalAttempts?: number;
  maxElapsedMs?: number;
  refreshResource?: () => Promise<DirectMediaResource>;
  onDiagnostic?: (diagnostic: DirectRangeDiagnostic) => void;
}

class RangeResponseError extends Error {
  readonly status: number;
  readonly retryAfterMs: number | undefined;
  readonly responseHeaders: Record<string, string | null>;

  constructor(
    status: number,
    message: string,
    retryAfterMs: number | undefined,
    responseHeaders: Record<string, string | null>
  ) {
    super(message);
    this.name = 'RangeResponseError';
    this.status = status;
    this.retryAfterMs = retryAfterMs;
    this.responseHeaders = responseHeaders;
  }
}

function causeCode(error: unknown): string | undefined {
  let current: unknown = error;
  for (let depth = 0; depth < 5; depth += 1) {
    if (!current || typeof current !== 'object') return undefined;
    if ('code' in current && typeof current.code === 'string') {
      return current.code;
    }
    current = 'cause' in current ? current.cause : undefined;
  }
  return undefined;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function isTransportFailure(error: unknown): boolean {
  const code = causeCode(error);
  return new Set([
    'UND_ERR_SOCKET',
    'UND_ERR_BODY_TIMEOUT',
    'UND_ERR_RES_CONTENT_LENGTH_MISMATCH',
    'DIRECT_RANGE_LENGTH_MISMATCH',
    'ECONNRESET',
    'EPIPE',
    'ENETRESET',
    'ETIMEDOUT'
  ]).has(code ?? '');
}

function concatChunks(chunks: Uint8Array[], total: number): Uint8Array {
  const result = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

function rangedUrl(rawUrl: string, start: number, end: number): string {
  const url = new URL(rawUrl);
  url.searchParams.set('range', `${start}-${end}`);
  return url.toString();
}

function urlIsNearExpiry(
  rawUrl: string,
  nowMs: number,
  refreshBeforeExpirySec: number
): boolean {
  try {
    const expire = Number(new URL(rawUrl).searchParams.get('expire'));
    return (
      Number.isFinite(expire) &&
      expire > 0 &&
      expire - nowMs / 1000 <= refreshBeforeExpirySec
    );
  } catch {
    return false;
  }
}

function parseRetryAfterMs(value: string | null, nowMs: number): number | undefined {
  if (!value) return undefined;
  if (/^\d+$/.test(value)) return Number(value) * 1000;
  const dateMs = Date.parse(value);
  if (!Number.isFinite(dateMs)) return undefined;
  return Math.max(0, dateMs - nowMs);
}

function assertSameMediaIdentity(
  expected: DirectMediaIdentity,
  actual: DirectMediaIdentity
): void {
  const sameLastModified =
    !expected.lastModified ||
    !actual.lastModified ||
    expected.lastModified === actual.lastModified;
  if (
    expected.itag !== actual.itag ||
    expected.mimeType !== actual.mimeType ||
    expected.contentLength !== actual.contentLength ||
    !sameLastModified
  ) {
    throw Object.assign(
      new Error(
        `Direct media identity changed while refreshing URL: expected itag=${expected.itag} length=${expected.contentLength}, got itag=${actual.itag} length=${actual.contentLength}`
      ),
      {
        code: 'MEDIA_IDENTITY_CHANGED',
        expectedIdentity: expected,
        actualIdentity: actual
      }
    );
  }
}

function assertResourceIdentity(
  expected: DirectMediaIdentity,
  resource: DirectMediaResource
): void {
  assertSameMediaIdentity(expected, resource.identity);
  let urlContentLength: number | null = null;
  try {
    const raw = new URL(resource.url).searchParams.get('clen');
    if (raw !== null) urlContentLength = Number(raw);
  } catch {
    // URL parsing is handled by fetch; identity validation remains metadata-only.
  }
  if (
    urlContentLength !== null &&
    (!Number.isSafeInteger(urlContentLength) ||
      urlContentLength !== expected.contentLength)
  ) {
    throw Object.assign(
      new Error(
        `Direct media URL clen changed while refreshing: expected=${expected.contentLength} got=${urlContentLength}`
      ),
      { code: 'MEDIA_IDENTITY_CHANGED' }
    );
  }
}

async function waitForRetry(ms: number, signal?: AbortSignal): Promise<void> {
  if (ms <= 0) return;
  await new Promise<void>((resolve, reject) => {
    const finish = () => {
      signal?.removeEventListener('abort', abort);
      resolve();
    };
    const timer = setTimeout(finish, ms);
    const abort = () => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
      reject(signal?.reason ?? new DOMException('Aborted', 'AbortError'));
    };
    if (signal?.aborted) {
      abort();
      return;
    }
    signal?.addEventListener('abort', abort, { once: true });
  });
}

async function fetchRangeBlock(
  fetchImpl: typeof fetch,
  url: string,
  start: number,
  end: number,
  signal?: AbortSignal,
  nowMs = Date.now
): Promise<Uint8Array> {
  const expectedLength = end - start + 1;
  const response = await fetchImpl(rangedUrl(url, start, end), {
    method: 'GET',
    headers: {
      Accept: '*/*',
      'Accept-Encoding': 'identity',
      Origin: 'https://www.youtube.com',
      Referer: 'https://www.youtube.com',
      DNT: '?1'
    },
    redirect: 'follow',
    signal
  });

  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw new RangeResponseError(
      response.status,
      `Direct media range request failed: HTTP ${response.status}`,
      parseRetryAfterMs(response.headers.get('retry-after'), nowMs()),
      {
        contentLength: response.headers.get('content-length'),
        contentRange: response.headers.get('content-range'),
        acceptRanges: response.headers.get('accept-ranges'),
        retryAfter: response.headers.get('retry-after')
      }
    );
  }
  if (!response.body) {
    throw new Error('Direct media range response body is missing');
  }

  const declaredLength = Number(response.headers.get('content-length') || 0);
  if (declaredLength > 0 && declaredLength !== expectedLength) {
    await response.body.cancel().catch(() => {});
    throw Object.assign(
      new Error(
        `Direct media range length mismatch: expected=${expectedLength} declared=${declaredLength}`
      ),
      { code: 'DIRECT_RANGE_LENGTH_MISMATCH' }
    );
  }

  const chunks: Uint8Array[] = [];
  let received = 0;
  const reader = response.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      received += value.byteLength;
      if (received > expectedLength) {
        throw Object.assign(
          new Error(
            `Direct media range overflow: expected=${expectedLength} received=${received}`
          ),
          { code: 'DIRECT_RANGE_LENGTH_MISMATCH' }
        );
      }
    }
  } finally {
    reader.releaseLock();
  }
  if (received !== expectedLength) {
    throw Object.assign(
      new Error(
        `Direct media range truncated: expected=${expectedLength} received=${received}`
      ),
      { code: 'DIRECT_RANGE_LENGTH_MISMATCH' }
    );
  }
  return concatChunks(chunks, received);
}

/**
 * Creates a byte stream backed by independently validated URL `range=` blocks.
 * A block is buffered and checked before it is emitted, so retrying a failed
 * request cannot duplicate partial bytes in the downstream file or FIFO.
 */
export function createResumableRangeStream(
  options: ResumableRangeStreamOptions
): ReadableStream<Uint8Array> {
  const fetchImpl = options.fetch ?? fetch;
  const chunkSize = Math.max(1, options.chunkSize ?? DIRECT_RANGE_CHUNK_SIZE);
  const maxAttempts = Math.max(
    1,
    options.maxAttemptsPerChunk ?? DEFAULT_MAX_ATTEMPTS_PER_CHUNK
  );
  const retryDelayMs =
    options.retryDelayMs ??
    ((failedAttempt: number) => 500 * 2 ** Math.max(0, failedAttempt - 1));
  const nowMs = options.nowMs ?? Date.now;
  const refreshBeforeExpirySec = Math.max(
    0,
    options.refreshBeforeExpirySec ?? 300
  );
  const maxTotalAttempts = Math.max(1, options.maxTotalAttempts ?? 512);
  const maxElapsedMs = Math.max(1, options.maxElapsedMs ?? 6 * 60 * 60 * 1000);
  const startedAt = nowMs();
  let totalAttempts = 0;
  let offset = Math.max(0, options.startOffset ?? 0);
  let resourceUrl = options.url;

  assertResourceIdentity(options.identity, {
    url: resourceUrl,
    identity: options.identity
  });
  if (offset > options.identity.contentLength) {
    throw new RangeError(
      `Direct media start offset ${offset} exceeds length ${options.identity.contentLength}`
    );
  }

  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      if (offset >= options.identity.contentLength) {
        controller.close();
        return;
      }

      const rangeStart = offset;
      const rangeEnd = Math.min(
        rangeStart + chunkSize - 1,
        options.identity.contentLength - 1
      );
      if (
        options.refreshResource &&
        urlIsNearExpiry(resourceUrl, nowMs(), refreshBeforeExpirySec)
      ) {
        const refreshed = await options.refreshResource();
        assertResourceIdentity(options.identity, refreshed);
        resourceUrl = refreshed.url;
        options.onDiagnostic?.({
          kind: 'url-refresh',
          itag: options.identity.itag,
          offset,
          rangeStart,
          rangeEnd,
          attempt: 0,
          causeMessage: 'signed URL near expiry'
        });
      }
      let lastError: unknown;
      let resourceRefreshes = 0;
      let attemptsMade = 0;

      for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
        if (options.signal?.aborted) {
          throw options.signal.reason ?? new DOMException('Aborted', 'AbortError');
        }
        if (
          totalAttempts >= maxTotalAttempts ||
          nowMs() - startedAt >= maxElapsedMs
        ) {
          throw Object.assign(
            new Error(
              `Direct media download retry budget exceeded at offset ${offset}`
            ),
            {
              code: 'MEDIA_DOWNLOAD_FAILED',
              diagnostics: {
                itag: options.identity.itag,
                offset,
                rangeStart,
                rangeEnd,
                totalAttempts,
                elapsedMs: nowMs() - startedAt,
                retryBudgetExceeded: true
              }
            }
          );
        }
        totalAttempts += 1;
        attemptsMade = attempt;
        try {
          const block = await fetchRangeBlock(
            fetchImpl,
            resourceUrl,
            rangeStart,
            rangeEnd,
            options.signal,
            nowMs
          );
          controller.enqueue(block);
          offset = rangeEnd + 1;
          options.onDiagnostic?.({
            kind: 'chunk-complete',
            itag: options.identity.itag,
            offset,
            rangeStart,
            rangeEnd,
            attempt
          });
          return;
        } catch (error) {
          if (options.signal?.aborted) {
            throw options.signal.reason ?? error;
          }
          lastError = error;
          if (attempt >= maxAttempts) break;
          if (error instanceof RangeResponseError) {
            if (
              error.status === 403 ||
              error.status === 410 ||
              error.status === 416
            ) {
              if (options.refreshResource && resourceRefreshes === 0) {
                const refreshed = await options.refreshResource();
                assertResourceIdentity(options.identity, refreshed);
                resourceUrl = refreshed.url;
                resourceRefreshes += 1;
                options.onDiagnostic?.({
                  kind: 'url-refresh',
                  itag: options.identity.itag,
                  offset,
                  rangeStart,
                  rangeEnd,
                  attempt,
                  causeMessage: error.message,
                  httpStatus: error.status,
                  retryAfterMs: error.retryAfterMs,
                  responseHeaders: error.responseHeaders
                });
                continue;
              }
              break;
            }
            if (error.status !== 429 && error.status < 500) break;
          }
          if (
            attempt >= 2 &&
            isTransportFailure(error) &&
            options.refreshResource &&
            resourceRefreshes === 0
          ) {
            const refreshed = await options.refreshResource();
            assertResourceIdentity(options.identity, refreshed);
            resourceUrl = refreshed.url;
            resourceRefreshes += 1;
            options.onDiagnostic?.({
              kind: 'url-refresh',
              itag: options.identity.itag,
              offset,
              rangeStart,
              rangeEnd,
              attempt,
              causeCode: causeCode(error),
              causeMessage: errorMessage(error)
            });
            continue;
          }
          options.onDiagnostic?.({
            kind: 'retry',
            itag: options.identity.itag,
            offset,
            rangeStart,
            rangeEnd,
            attempt,
            causeCode: causeCode(error),
            causeMessage: errorMessage(error),
            httpStatus:
              error instanceof RangeResponseError ? error.status : undefined,
            retryAfterMs:
              error instanceof RangeResponseError
                ? error.retryAfterMs
                : undefined,
            responseHeaders:
              error instanceof RangeResponseError
                ? error.responseHeaders
                : undefined
          });
          await waitForRetry(
            Math.max(
              retryDelayMs(attempt),
              error instanceof RangeResponseError
                ? error.retryAfterMs ?? 0
                : 0
            ),
            options.signal
          );
        }
      }

      throw Object.assign(
        new Error(
          `Direct media range failed after ${attemptsMade} attempts at ${rangeStart}-${rangeEnd}: ${errorMessage(lastError)}`
        ),
        {
          code: 'MEDIA_DOWNLOAD_FAILED',
          cause: lastError,
          diagnostics: {
            itag: options.identity.itag,
            offset,
            rangeStart,
            rangeEnd,
            attempt: attemptsMade,
            causeCode: causeCode(lastError),
            causeMessage: errorMessage(lastError),
            httpStatus:
              lastError instanceof RangeResponseError
                ? lastError.status
                : undefined,
            retryAfterMs:
              lastError instanceof RangeResponseError
                ? lastError.retryAfterMs
                : undefined,
            responseHeaders:
              lastError instanceof RangeResponseError
                ? lastError.responseHeaders
                : undefined,
            totalAttempts,
            elapsedMs: nowMs() - startedAt
          }
        }
      );
    }
  });
}
