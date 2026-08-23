import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import {
  createResumableRangeStream,
  type DirectMediaIdentity
} from '../src/sabr/resumable-range-stream.js';

async function readAll(stream: ReadableStream<Uint8Array>): Promise<Uint8Array> {
  const chunks: Uint8Array[] = [];
  let total = 0;
  const reader = stream.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      total += value.byteLength;
    }
  } finally {
    reader.releaseLock();
  }
  const result = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

describe('createResumableRangeStream', () => {
  it('retries a terminated range without committing duplicate partial bytes', async () => {
    const source = Uint8Array.from({ length: 20 }, (_, index) => index);
    const requestedRanges: string[] = [];
    let firstAttempt = true;
    const identity: DirectMediaIdentity = {
      itag: 137,
      mimeType: 'video/mp4; codecs="avc1.640028"',
      contentLength: source.byteLength,
      lastModified: '123'
    };

    const stream = createResumableRangeStream({
      url: 'https://media.example/videoplayback?expire=9999999999',
      identity,
      chunkSize: 8,
      maxAttemptsPerChunk: 3,
      retryDelayMs: () => 0,
      fetch: async (input) => {
        const url = new URL(String(input));
        const range = url.searchParams.get('range');
        assert.ok(range);
        requestedRanges.push(range);
        const [start, end] = range.split('-').map(Number);
        const bytes = source.slice(start, end + 1);

        if (firstAttempt) {
          firstAttempt = false;
          const terminated = Object.assign(new TypeError('terminated'), {
            cause: Object.assign(new Error('other side closed'), {
              name: 'SocketError',
              code: 'UND_ERR_SOCKET'
            })
          });
          const body = new ReadableStream<Uint8Array>({
            start(controller) {
              controller.enqueue(bytes.slice(0, 4));
              controller.error(terminated);
            }
          });
          return new Response(body, {
            status: 200,
            headers: { 'Content-Length': String(bytes.byteLength) }
          });
        }

        return new Response(bytes, {
          status: 200,
          headers: { 'Content-Length': String(bytes.byteLength) }
        });
      }
    });

    assert.deepEqual(await readAll(stream), source);
    assert.deepEqual(requestedRanges, ['0-7', '0-7', '8-15', '16-19']);
  });

  it('refreshes after HTTP 403 and resumes with the same media identity', async () => {
    const source = Uint8Array.from([10, 20, 30, 40]);
    const identity: DirectMediaIdentity = {
      itag: 140,
      mimeType: 'audio/mp4; codecs="mp4a.40.2"',
      contentLength: source.byteLength,
      lastModified: '456'
    };
    let refreshCalls = 0;
    const requestedHosts: string[] = [];

    const stream = createResumableRangeStream({
      url: 'https://expired.example/videoplayback',
      identity,
      chunkSize: 4,
      retryDelayMs: () => 0,
      refreshResource: async () => {
        refreshCalls += 1;
        return {
          url: 'https://fresh.example/videoplayback?expire=9999999999',
          identity
        };
      },
      fetch: async (input) => {
        const url = new URL(String(input));
        requestedHosts.push(url.host);
        if (url.host === 'expired.example') {
          return new Response(null, { status: 403 });
        }
        return new Response(source, {
          status: 200,
          headers: { 'Content-Length': String(source.byteLength) }
        });
      }
    });

    assert.deepEqual(await readAll(stream), source);
    assert.equal(refreshCalls, 1);
    assert.deepEqual(requestedHosts, ['expired.example', 'fresh.example']);
  });

  it('refuses to append bytes when refreshed media identity changes', async () => {
    const identity: DirectMediaIdentity = {
      itag: 137,
      mimeType: 'video/mp4; codecs="avc1.640028"',
      contentLength: 8,
      lastModified: 'original'
    };
    const stream = createResumableRangeStream({
      url: 'https://expired.example/videoplayback',
      identity,
      chunkSize: 8,
      retryDelayMs: () => 0,
      fetch: async () => new Response(null, { status: 410 }),
      refreshResource: async () => ({
        url: 'https://fresh.example/videoplayback',
        identity: { ...identity, contentLength: 9 }
      })
    });

    await assert.rejects(
      () => readAll(stream),
      (error: any) => error?.code === 'MEDIA_IDENTITY_CHANGED'
    );
  });

  it('refreshes the URL after repeated transport termination of one block', async () => {
    const source = Uint8Array.from([1, 3, 5, 7]);
    const identity: DirectMediaIdentity = {
      itag: 137,
      mimeType: 'video/mp4; codecs="avc1.640028"',
      contentLength: source.byteLength,
      lastModified: 'same'
    };
    const requestedHosts: string[] = [];
    let refreshCalls = 0;
    const terminated = Object.assign(new TypeError('terminated'), {
      cause: Object.assign(new Error('other side closed'), {
        code: 'UND_ERR_SOCKET'
      })
    });

    const stream = createResumableRangeStream({
      url: 'https://flaky.example/videoplayback',
      identity,
      chunkSize: 4,
      maxAttemptsPerChunk: 4,
      retryDelayMs: () => 0,
      refreshResource: async () => {
        refreshCalls += 1;
        return {
          url: 'https://healthy.example/videoplayback',
          identity
        };
      },
      fetch: async (input) => {
        const host = new URL(String(input)).host;
        requestedHosts.push(host);
        if (host === 'flaky.example') throw terminated;
        return new Response(source, {
          status: 200,
          headers: { 'Content-Length': String(source.byteLength) }
        });
      }
    });

    assert.deepEqual(await readAll(stream), source);
    assert.equal(refreshCalls, 1);
    assert.deepEqual(requestedHosts, [
      'flaky.example',
      'flaky.example',
      'healthy.example'
    ]);
  });

  it('refreshes before opening a new block when the signed URL is near expiry', async () => {
    const source = Uint8Array.from([2, 4, 6, 8]);
    const identity: DirectMediaIdentity = {
      itag: 140,
      mimeType: 'audio/mp4; codecs="mp4a.40.2"',
      contentLength: source.byteLength,
      lastModified: 'same'
    };
    const requestedHosts: string[] = [];
    let refreshCalls = 0;
    const stream = createResumableRangeStream({
      url: 'https://expiring.example/videoplayback?expire=1060',
      identity,
      chunkSize: 4,
      nowMs: () => 1_000_000,
      refreshBeforeExpirySec: 300,
      refreshResource: async () => {
        refreshCalls += 1;
        return {
          url: 'https://fresh.example/videoplayback?expire=9999',
          identity
        };
      },
      fetch: async (input) => {
        requestedHosts.push(new URL(String(input)).host);
        return new Response(source, {
          status: 200,
          headers: { 'Content-Length': String(source.byteLength) }
        });
      }
    });

    assert.deepEqual(await readAll(stream), source);
    assert.equal(refreshCalls, 1);
    assert.deepEqual(requestedHosts, ['fresh.example']);
  });

  it('does not retry a permanent HTTP response', async () => {
    const identity: DirectMediaIdentity = {
      itag: 137,
      mimeType: 'video/mp4',
      contentLength: 4,
      lastModified: 'same'
    };
    let fetchCalls = 0;
    const stream = createResumableRangeStream({
      url: 'https://media.example/videoplayback',
      identity,
      chunkSize: 4,
      maxAttemptsPerChunk: 4,
      retryDelayMs: () => 0,
      fetch: async () => {
        fetchCalls += 1;
        return new Response(null, { status: 404 });
      }
    });

    await assert.rejects(
      () => readAll(stream),
      (error: any) =>
        error?.code === 'MEDIA_DOWNLOAD_FAILED' &&
        error?.diagnostics?.httpStatus === 404
    );
    assert.equal(fetchCalls, 1);
  });

  it('refreshes an authorization failure only once', async () => {
    const identity: DirectMediaIdentity = {
      itag: 140,
      mimeType: 'audio/mp4',
      contentLength: 4,
      lastModified: 'same'
    };
    let fetchCalls = 0;
    let refreshCalls = 0;
    const stream = createResumableRangeStream({
      url: 'https://expired.example/videoplayback',
      identity,
      chunkSize: 4,
      maxAttemptsPerChunk: 4,
      retryDelayMs: () => 0,
      refreshResource: async () => {
        refreshCalls += 1;
        return {
          url: 'https://still-expired.example/videoplayback',
          identity
        };
      },
      fetch: async () => {
        fetchCalls += 1;
        return new Response(null, { status: 403 });
      }
    });

    await assert.rejects(
      () => readAll(stream),
      (error: any) =>
        error?.code === 'MEDIA_DOWNLOAD_FAILED' &&
        error?.diagnostics?.httpStatus === 403
    );
    assert.equal(refreshCalls, 1);
    assert.equal(fetchCalls, 2);
  });

  it('does not report or retry an intentional abort', async () => {
    const identity: DirectMediaIdentity = {
      itag: 137,
      mimeType: 'video/mp4',
      contentLength: 4,
      lastModified: 'same'
    };
    const abortController = new AbortController();
    let fetchCalls = 0;
    const diagnostics: string[] = [];
    const stream = createResumableRangeStream({
      url: 'https://media.example/videoplayback',
      identity,
      signal: abortController.signal,
      retryDelayMs: () => 0,
      onDiagnostic: (diagnostic) => diagnostics.push(diagnostic.kind),
      fetch: async () => {
        fetchCalls += 1;
        abortController.abort();
        throw new DOMException('Aborted', 'AbortError');
      }
    });

    await assert.rejects(
      () => readAll(stream),
      (error: any) => error?.name === 'AbortError'
    );
    assert.equal(fetchCalls, 1);
    assert.deepEqual(diagnostics, []);
  });

  it('refreshes once after HTTP 416 before reporting a range mismatch', async () => {
    const identity: DirectMediaIdentity = {
      itag: 137,
      mimeType: 'video/mp4',
      contentLength: 4,
      lastModified: 'same'
    };
    let fetchCalls = 0;
    let refreshCalls = 0;
    const stream = createResumableRangeStream({
      url: 'https://stale.example/videoplayback',
      identity,
      maxAttemptsPerChunk: 4,
      retryDelayMs: () => 0,
      refreshResource: async () => {
        refreshCalls += 1;
        return {
          url: 'https://fresh.example/videoplayback',
          identity
        };
      },
      fetch: async () => {
        fetchCalls += 1;
        return new Response(null, { status: 416 });
      }
    });

    await assert.rejects(
      () => readAll(stream),
      (error: any) =>
        error?.code === 'MEDIA_DOWNLOAD_FAILED' &&
        error?.diagnostics?.httpStatus === 416
    );
    assert.equal(refreshCalls, 1);
    assert.equal(fetchCalls, 2);
  });

  it('rejects a refreshed URL whose clen conflicts with the media identity', async () => {
    const identity: DirectMediaIdentity = {
      itag: 140,
      mimeType: 'audio/mp4',
      contentLength: 4,
      lastModified: 'same'
    };
    const stream = createResumableRangeStream({
      url: 'https://expired.example/videoplayback',
      identity,
      retryDelayMs: () => 0,
      refreshResource: async () => ({
        url: 'https://fresh.example/videoplayback?clen=5',
        identity
      }),
      fetch: async () => new Response(null, { status: 403 })
    });

    await assert.rejects(
      () => readAll(stream),
      (error: any) => error?.code === 'MEDIA_IDENTITY_CHANGED'
    );
  });

  it('captures safe response headers and Retry-After on a transient response', async () => {
    const identity: DirectMediaIdentity = {
      itag: 137,
      mimeType: 'video/mp4',
      contentLength: 4,
      lastModified: 'same'
    };
    const diagnostics: any[] = [];
    let calls = 0;
    const stream = createResumableRangeStream({
      url: 'https://media.example/videoplayback',
      identity,
      retryDelayMs: () => 0,
      onDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
      fetch: async () => {
        calls += 1;
        if (calls === 1) {
          return new Response(null, {
            status: 429,
            headers: {
              'Retry-After': '0',
              'Accept-Ranges': 'bytes'
            }
          });
        }
        return new Response(Uint8Array.from([1, 2, 3, 4]), {
          headers: { 'Content-Length': '4' }
        });
      }
    });

    assert.deepEqual(await readAll(stream), Uint8Array.from([1, 2, 3, 4]));
    assert.equal(diagnostics[0]?.retryAfterMs, 0);
    assert.equal(diagnostics[0]?.responseHeaders?.acceptRanges, 'bytes');
  });

  it('bounds total attempts across a track', async () => {
    const identity: DirectMediaIdentity = {
      itag: 140,
      mimeType: 'audio/mp4',
      contentLength: 4,
      lastModified: 'same'
    };
    let fetchCalls = 0;
    const stream = createResumableRangeStream({
      url: 'https://media.example/videoplayback',
      identity,
      maxTotalAttempts: 1,
      retryDelayMs: () => 0,
      fetch: async () => {
        fetchCalls += 1;
        throw Object.assign(new TypeError('terminated'), {
          cause: Object.assign(new Error('closed'), {
            code: 'UND_ERR_SOCKET'
          })
        });
      }
    });

    await assert.rejects(
      () => readAll(stream),
      (error: any) =>
        error?.code === 'MEDIA_DOWNLOAD_FAILED' &&
        error?.diagnostics?.retryBudgetExceeded === true
    );
    assert.equal(fetchCalls, 1);
  });
});
