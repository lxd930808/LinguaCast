import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  HttpMediaServiceClient,
  SingleFlightMediaGate
} from '../src/providers/media/client.js';
import {
  MediaServiceError,
  type MediaJobStatus,
  type MediaJobView,
  type MediaServiceClient,
  type PrepareMediaResult
} from '../src/providers/media/types.js';

// MediaServiceClient contract tests (WP7 Phase A). Requests are pinned
// against the media-api 0.2.0 wire contract; error mapping is the stable
// surface the pipeline depends on.

function jsonResponse(status: number, body: unknown, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...headers }
  });
}

function clientWith(handler: (url: string, init: RequestInit) => Promise<Response>) {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const fetchImpl = (async (url: string | URL, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    return handler(String(url), init ?? {});
  }) as typeof fetch;
  const client = new HttpMediaServiceClient({
    baseUrl: 'http://127.0.0.1:3210/',
    token: 'media-token-0123456789',
    fetchImpl
  });
  return { client, calls };
}

test('prepare posts the 0.2.0 contract and parses 202', async () => {
  const { client, calls } = clientWith(async () =>
    jsonResponse(202, {
      jobId: 'mj-1',
      status: 'queued',
      statusUrl: 'http://127.0.0.1:3210/v1/jobs/mj-1'
    })
  );
  const result = await client.prepare({ videoId: 'abcdefghijk', mode: 'mp4' });
  assert.deepEqual(result, { jobId: 'mj-1', status: 'queued' });

  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'http://127.0.0.1:3210/v1/videos/abcdefghijk/prepare');
  assert.equal(calls[0].init.method, 'POST');
  const headers = new Headers(calls[0].init.headers);
  assert.equal(headers.get('authorization'), 'Bearer media-token-0123456789');
  assert.deepEqual(JSON.parse(String(calls[0].init.body)), { mode: 'mp4' });
});

test('getJob parses playback with audioUrl and expiry', async () => {
  const { client } = clientWith(async () =>
    jsonResponse(200, {
      jobId: 'mj-1',
      videoId: 'abcdefghijk',
      mode: 'mp4',
      status: 'ready',
      progress: 1,
      createdAt: 1,
      updatedAt: 2,
      expiresAt: 2_700_000,
      errorCode: null,
      errorMessage: null,
      playback: {
        kind: 'mp4',
        url: 'http://127.0.0.1:3210/media/mj-1/output.mp4',
        audioUrl: 'http://127.0.0.1:3210/media/mj-1/audio.m4a',
        height: 720,
        durationSeconds: 600
      },
      diagnostics: {}
    })
  );
  const view = await client.getJob('mj-1');
  assert.equal(view.status, 'ready');
  assert.equal(view.expiresAt, 2_700_000);
  assert.equal(view.playback?.audioUrl, 'http://127.0.0.1:3210/media/mj-1/audio.m4a');
  assert.equal(view.playback?.durationSeconds, 600);
  assert.equal(view.playback?.videoCodec, null);
  assert.equal(view.playback?.audioCodec, null);
  assert.equal(view.playback?.itagVideo, null);
  assert.equal(view.playback?.itagAudio, null);
});

test('getJob preserves optional playback codec metadata and ignores unknown fields', async () => {
  const { client } = clientWith(async () =>
    jsonResponse(200, {
      jobId: 'mj-1',
      videoId: 'abcdefghijk',
      mode: 'mp4',
      status: 'ready',
      progress: 1,
      expiresAt: 2_700_000,
      playback: {
        kind: 'mp4',
        url: 'http://127.0.0.1:3210/media/mj-1/output.mp4',
        audioUrl: 'http://127.0.0.1:3210/media/mj-1/audio.m4a',
        height: 1080,
        durationSeconds: 90,
        videoCodec: 'avc1.640028',
        audioCodec: 'mp4a.40.2',
        itagVideo: 137,
        itagAudio: 140,
        futureHint: 'ignore-me'
      }
    })
  );
  const view = await client.getJob('mj-1');
  assert.equal(view.playback?.height, 1080);
  assert.equal(view.playback?.videoCodec, 'avc1.640028');
  assert.equal(view.playback?.audioCodec, 'mp4a.40.2');
  assert.equal(view.playback?.itagVideo, 137);
  assert.equal(view.playback?.itagAudio, 140);
});

test('getJob rejects a mismatched jobId defensively', async () => {
  const { client } = clientWith(async () =>
    jsonResponse(200, { jobId: 'mj-other', status: 'queued' })
  );
  await assert.rejects(
    () => client.getJob('mj-1'),
    (error: unknown) =>
      error instanceof MediaServiceError && error.kind === 'unavailable'
  );
});

test('error mapping covers the media-api failure surface', async () => {
  const cases: Array<{
    name: string;
    respond: () => Response;
    kind: string;
    retryAfter?: number;
  }> = [
    {
      name: '401 → unauthorized',
      respond: () => jsonResponse(401, { error: 'UNAUTHORIZED', message: 'bad token' }),
      kind: 'unauthorized'
    },
    {
      name: '404 → not_found',
      respond: () => jsonResponse(404, { error: 'JOB_NOT_FOUND', message: 'unknown' }),
      kind: 'not_found'
    },
    {
      name: '410 → expired',
      respond: () => jsonResponse(410, { error: 'MEDIA_EXPIRED', message: 'gone' }),
      kind: 'expired'
    },
    {
      name: '507 DISK_FULL → disk_full',
      respond: () => jsonResponse(507, { error: 'DISK_FULL', message: 'no space' }),
      kind: 'disk_full'
    },
    {
      name: '429 with Retry-After → busy + retryAfterSeconds',
      respond: () =>
        jsonResponse(429, { error: 'BUSY', message: 'slow down' }, { 'retry-after': '45' }),
      kind: 'busy',
      retryAfter: 45
    },
    {
      name: '400 → invalid_request',
      respond: () => jsonResponse(400, { error: 'INVALID_VIDEO_ID', message: 'bad id' }),
      kind: 'invalid_request'
    },
    {
      name: '500 → unavailable',
      respond: () => jsonResponse(500, { error: 'INTERNAL_ERROR', message: 'boom' }),
      kind: 'unavailable'
    }
  ];

  for (const c of cases) {
    const { client } = clientWith(async () => c.respond());
    await assert.rejects(
      () => client.getJob('mj-1'),
      (error: unknown) => {
        assert.ok(error instanceof MediaServiceError, `${c.name}: wrong error type`);
        assert.equal(error.kind, c.kind, c.name);
        if (c.retryAfter !== undefined) {
          assert.equal(error.options.retryAfterSeconds, c.retryAfter, c.name);
        }
        return true;
      }
    );
  }
});

test('network failures map to unavailable without leaking internals', async () => {
  const { client } = clientWith(async () => {
    throw new Error('ECONNREFUSED');
  });
  await assert.rejects(
    () => client.prepare({ videoId: 'abcdefghijk' }),
    (error: unknown) => error instanceof MediaServiceError && error.kind === 'unavailable'
  );
});

test('cancel tolerates 404 (already evicted) and propagates other errors', async () => {
  const { client: tolerant } = clientWith(async () =>
    jsonResponse(404, { error: 'JOB_NOT_FOUND', message: 'unknown' })
  );
  await tolerant.cancel('mj-gone');

  const { client: strict } = clientWith(async () =>
    jsonResponse(500, { error: 'INTERNAL_ERROR', message: 'boom' })
  );
  await assert.rejects(
    () => strict.cancel('mj-1'),
    (error: unknown) => error instanceof MediaServiceError && error.kind === 'unavailable'
  );
});

// --- SingleFlightMediaGate ---

function scriptedClient(views: MediaJobView[]): MediaServiceClient & { prepares: number; cancels: number } {
  const state = { prepares: 0, cancels: 0 };
  return {
    prepares: 0,
    cancels: 0,
    async prepare(): Promise<PrepareMediaResult> {
      state.prepares += 1;
      this.prepares = state.prepares;
      return { jobId: 'mj-1', status: 'queued' };
    },
    async getJob(): Promise<MediaJobView> {
      return views.shift() ?? views[views.length - 1]!;
    },
    async cancel(): Promise<void> {
      state.cancels += 1;
      this.cancels = state.cancels;
    }
  };
}

function view(status: MediaJobStatus): MediaJobView {
  return {
    jobId: 'mj-1',
    videoId: 'abcdefghijk',
    status,
    progress: status === 'ready' ? 1 : 0.5,
    expiresAt: Date.now() + 2_700_000,
    errorCode: null,
    errorMessage: null,
    playback: null
  };
}

test('single-flight gate refuses a second prepare while one is in flight', async () => {
  const inner = scriptedClient([view('fetching'), view('ready')]);
  const gate = new SingleFlightMediaGate(inner);

  await gate.prepare({ videoId: 'abcdefghijk' });
  await assert.rejects(
    () => gate.prepare({ videoId: 'zzzzzzzzzzz' }),
    (error: unknown) =>
      error instanceof MediaServiceError &&
      error.kind === 'busy' &&
      typeof error.options.retryAfterSeconds === 'number'
  );

  // Terminal status releases the gate.
  await gate.getJob('mj-1'); // fetching — still in flight
  await assert.rejects(() => gate.prepare({ videoId: 'zzzzzzzzzzz' }));
  await gate.getJob('mj-1'); // ready — released
  await gate.prepare({ videoId: 'zzzzzzzzzzz' });
});

test('single-flight gate releases on cancel and on failed prepare', async () => {
  const failing: MediaServiceClient = {
    async prepare() {
      throw new MediaServiceError('disk_full', 'no space');
    },
    async getJob() {
      throw new Error('unreached');
    },
    async cancel() {}
  };
  const gate = new SingleFlightMediaGate(failing);
  await assert.rejects(() => gate.prepare({ videoId: 'abcdefghijk' }));
  // A failed prepare must not wedge the gate.
  await assert.rejects(() => gate.prepare({ videoId: 'abcdefghijk' }));

  const inner = scriptedClient([view('queued')]);
  const gate2 = new SingleFlightMediaGate(inner);
  await gate2.prepare({ videoId: 'abcdefghijk' });
  await gate2.cancel('mj-1');
  await gate2.prepare({ videoId: 'zzzzzzzzzzz' });
});
