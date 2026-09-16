import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { Readable, Transform } from 'node:stream';

import { PipelineJobError } from '../jobs/worker.js';
import { assertPublicUrl, SsrfBlockedError, type SsrfCheckOptions } from './ssrf.js';

// SSRF-safe streaming downloader (WP4). The response body is piped to a temp
// file while a SHA-256 is computed incrementally; memory stays O(chunk).
// Redirects are followed manually so every hop is re-validated.

export interface DownloadOptions {
  maxBytes: number;
  totalTimeoutMs?: number;
  idleTimeoutMs?: number;
  maxRedirects?: number;
  /** Accepted Content-Type prefixes; octet-stream is always accepted. */
  allowedMimePrefixes?: string[];
  signal?: AbortSignal;
  ssrf?: SsrfCheckOptions;
  fetchImpl?: typeof fetch;
  onProgress?: (bytes: number) => void;
}

export interface DownloadResult {
  filePath: string;
  bytes: number;
  sha256: string;
  contentType: string;
  finalUrl: string;
  redirects: number;
}

// `binary/octet-stream` is the legacy spelling S3/CloudFront returns for objects
// stored without an explicit content type; Substack-hosted feeds serve audio that
// way. The real container/codec check happens downstream in ffprobe, so accepting
// both spellings here does not weaken validation.
const DEFAULT_ALLOWED_MIME = [
  'audio/',
  'application/octet-stream',
  'binary/octet-stream',
  'application/ogg',
  'video/'
];
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

class IdleTimeout extends Error {
  constructor(ms: number) {
    super(`no bytes received for ${ms}ms`);
    this.name = 'IdleTimeout';
  }
}

export async function downloadToFile(
  sourceUrl: string,
  filePath: string,
  options: DownloadOptions
): Promise<DownloadResult> {
  const fetchImpl = options.fetchImpl ?? fetch;
  const maxRedirects = options.maxRedirects ?? 5;
  const totalTimeoutMs = options.totalTimeoutMs ?? 30 * 60 * 1000;
  const idleTimeoutMs = options.idleTimeoutMs ?? 30 * 1000;
  const allowed = options.allowedMimePrefixes ?? DEFAULT_ALLOWED_MIME;

  await mkdir(dirname(filePath), { recursive: true });

  let current = sourceUrl;
  let redirects = 0;

  for (;;) {
    let parsed: URL;
    try {
      parsed = new URL(current);
    } catch {
      throw downloadError('malformed URL', false);
    }
    try {
      await assertPublicUrl(parsed, options.ssrf);
    } catch (error) {
      if (error instanceof SsrfBlockedError) {
        throw new PipelineJobError(
          {
            code: 'SOURCE_RESTRICTED',
            message: error.message,
            retryable: false,
            failedStage: 'fetching_audio'
          },
          error
        );
      }
      throw error;
    }

    const totalTimer = AbortSignal.timeout(totalTimeoutMs);
    const signal = options.signal
      ? AbortSignal.any([options.signal, totalTimer])
      : totalTimer;

    let response: Response;
    try {
      response = await fetchImpl(current, { redirect: 'manual', signal });
    } catch (error) {
      if (isAbort(error) && options.signal?.aborted) throw error;
      throw downloadError(
        `connection failed: ${error instanceof Error ? error.message : String(error)}`,
        true
      );
    }

    if (REDIRECT_STATUSES.has(response.status)) {
      const location = response.headers.get('location');
      response.body?.cancel().catch(() => {});
      if (!location) throw downloadError(`redirect ${response.status} without Location`, true);
      redirects += 1;
      if (redirects > maxRedirects) {
        throw downloadError(`too many redirects (>${maxRedirects})`, false);
      }
      current = new URL(location, current).toString();
      continue;
    }

    if (response.status === 404 || response.status === 410) {
      throw new PipelineJobError({
        code: 'SOURCE_UNAVAILABLE',
        message: `source returned HTTP ${response.status}`,
        retryable: false,
        failedStage: 'validating_source'
      });
    }
    if (response.status === 401 || response.status === 403) {
      throw new PipelineJobError({
        code: 'SOURCE_RESTRICTED',
        message: `source returned HTTP ${response.status}`,
        retryable: false,
        failedStage: 'validating_source'
      });
    }
    if (response.status === 429) {
      const retryAfter = Number(response.headers.get('retry-after'));
      throw new PipelineJobError({
        code: 'SOURCE_RATE_LIMITED',
        message: 'source rate limited the download',
        retryable: true,
        retryAfterSeconds: Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : 60,
        failedStage: 'fetching_audio'
      });
    }
    if (response.status < 200 || response.status >= 300) {
      throw downloadError(`unexpected HTTP ${response.status}`, response.status >= 500);
    }

    const contentType = (response.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
    if (!allowed.some((prefix) => contentType.startsWith(prefix))) {
      throw new PipelineJobError({
        code: 'UNSUPPORTED_AUDIO',
        message: `unexpected content type ${contentType || '(none)'}`,
        retryable: false,
        failedStage: 'fetching_audio'
      });
    }

    const declaredLength = Number(response.headers.get('content-length'));
    if (Number.isFinite(declaredLength) && declaredLength > options.maxBytes) {
      response.body?.cancel().catch(() => {});
      throw new PipelineJobError({
        code: 'MEDIA_TOO_LARGE',
        message: `declared ${declaredLength} bytes exceeds limit ${options.maxBytes}`,
        retryable: false,
        failedStage: 'fetching_audio',
        params: { maxBytes: options.maxBytes }
      });
    }

    if (!response.body) throw downloadError('empty response body', true);

    const hash = createHash('sha256');
    let received = 0;
    let truncated = false;
    let oversized = false;
    let idleTimer: NodeJS.Timeout | null = null;
    let idleError: IdleTimeout | null = null;

    const counting = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        received += chunk.length;
        hash.update(chunk);
        options.onProgress?.(received);
        if (received > options.maxBytes) {
          oversized = true;
          callback(new Error('size limit exceeded'));
          return;
        }
        callback(null, chunk);
      }
    });

    const reader = response.body.getReader();
    const idleRace = new ReadableStream<Uint8Array>({
      async pull(controller) {
        const chunkPromise = reader.read();
        const timeoutPromise = new Promise<never>((_resolve, reject) => {
          idleTimer = setTimeout(() => reject(new IdleTimeout(idleTimeoutMs)), idleTimeoutMs);
          idleTimer.unref?.();
        });
        try {
          const { done, value } = await Promise.race([chunkPromise, timeoutPromise]);
          if (idleTimer) clearTimeout(idleTimer);
          if (done) {
            controller.close();
            return;
          }
          controller.enqueue(value);
        } catch (error) {
          if (idleTimer) clearTimeout(idleTimer);
          if (error instanceof IdleTimeout) {
            idleError = error;
            controller.error(error);
            reader.cancel().catch(() => {});
            return;
          }
          controller.error(error);
        }
      },
      cancel() {
        reader.cancel().catch(() => {});
      }
    });

    const fileStream = createWriteStream(filePath);
    try {
      await pipeline(Readable.fromWeb(idleRace as Parameters<typeof Readable.fromWeb>[0]), counting, fileStream);
    } catch (error) {
      fileStream.destroy();
      if (isAbort(error) && options.signal?.aborted) throw error;
      const idleFailure = idleError as IdleTimeout | null;
      if (idleFailure) {
        throw downloadError(`stalled download: ${idleFailure.message}`, true);
      }
      if (oversized) {
        throw new PipelineJobError({
          code: 'MEDIA_TOO_LARGE',
          message: `download exceeded limit ${options.maxBytes} bytes`,
          retryable: false,
          failedStage: 'fetching_audio',
          params: { maxBytes: options.maxBytes }
        });
      }
      throw downloadError(
        `stream failed: ${error instanceof Error ? error.message : String(error)}`,
        true
      );
    }

    if (Number.isFinite(declaredLength) && declaredLength >= 0 && received < declaredLength) {
      truncated = true;
    }
    if (truncated) {
      throw downloadError(
        `truncated download: ${received} of ${declaredLength} bytes`,
        true
      );
    }
    if (received === 0) {
      throw downloadError('empty download', true);
    }

    return {
      filePath,
      bytes: received,
      sha256: hash.digest('hex'),
      contentType,
      finalUrl: current,
      redirects
    };
  }
}

function downloadError(message: string, retryable: boolean): PipelineJobError {
  return new PipelineJobError({
    code: 'AUDIO_DOWNLOAD_FAILED',
    message,
    retryable,
    failedStage: 'fetching_audio'
  });
}

function isAbort(error: unknown): boolean {
  return error instanceof Error && error.name === 'AbortError';
}
