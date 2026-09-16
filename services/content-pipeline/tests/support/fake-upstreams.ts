/**
 * WP15 Step 1 fake upstreams: in-process HTTP servers that mimic the real
 * provider wire contracts so the integration suite exercises the REAL
 * provider clients (DashScope ASR, OpenAI-compatible translation, media-api
 * 0.2.0) end to end without any external network access.
 *
 * Each fake exposes fault-injection flags and request counters the
 * scenarios assert on.
 */

import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';

export interface FakeHttpServer {
  readonly baseUrl: string;
  close(): Promise<void>;
}

async function readBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  return Buffer.concat(chunks).toString('utf8');
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const data = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(data);
}

async function startServer(
  handler: (req: IncomingMessage, res: ServerResponse, body: string) => void | Promise<void>
): Promise<{ server: Server; baseUrl: string }> {
  const server = createServer((req, res) => {
    void (async () => {
      try {
        const body = req.method === 'GET' || req.method === 'HEAD' ? '' : await readBody(req);
        await handler(req, res, body);
      } catch (error) {
        sendJson(res, 500, { error: `fake server failure: ${String(error)}` });
      }
    })();
  });
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  if (address === null || typeof address === 'string') throw new Error('fake server has no address');
  return { server, baseUrl: `http://127.0.0.1:${address.port}` };
}

function closable(server: Server): () => Promise<void> {
  return () =>
    new Promise((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
}

// ---------------------------------------------------------------------------
// Fake DashScope recorded transcription (see src/providers/asr/dashscope.ts).
// ---------------------------------------------------------------------------

export const FAKE_TRANSCRIPT_PAYLOAD = {
  transcripts: [
    {
      sentences: [
        {
          begin_time: 100,
          end_time: 1400,
          text: 'Hello world.',
          words: [
            { text: 'Hello', begin_time: 100, end_time: 400 },
            { text: 'world', begin_time: 420, end_time: 900, punctuation: '.' }
          ]
        },
        {
          begin_time: 2000,
          end_time: 3100,
          text: 'How are you?',
          words: [
            { text: 'How', begin_time: 2000, end_time: 2300 },
            { text: 'are', begin_time: 2320, end_time: 2600 },
            { text: 'you', begin_time: 2620, end_time: 3000, punctuation: '?' }
          ]
        }
      ]
    }
  ]
};

export class FakeDashScopeServer implements FakeHttpServer {
  /** Number of poll requests answered with HTTP 500 before normal service. */
  failPolls = 0;
  /** While true, tasks stay PENDING forever (crash-injection scenarios). */
  holdPending = false;
  /** Number of polls that report PENDING before SUCCEEDED (per task). */
  pendingPollsPerTask = 1;

  submitCount = 0;
  pollCount = 0;
  private taskSeq = 0;
  private readonly taskPolls = new Map<string, number>();

  private constructor(
    public readonly baseUrl: string,
    private readonly server: Server
  ) {}

  static async start(): Promise<FakeDashScopeServer> {
    let self: FakeDashScopeServer;
    const { server, baseUrl } = await startServer((req, res) => {
      const url = new URL(req.url ?? '/', 'http://fake');
      if (req.method === 'POST' && url.pathname === '/api/v1/services/audio/asr/transcription') {
        self.submitCount += 1;
        const taskId = `task-${++self.taskSeq}`;
        self.taskPolls.set(taskId, 0);
        sendJson(res, 200, { output: { task_id: taskId, task_status: 'PENDING' } });
        return;
      }
      const taskMatch = /^\/api\/v1\/tasks\/([^/]+)$/.exec(url.pathname);
      if (req.method === 'GET' && taskMatch) {
        const taskId = decodeURIComponent(taskMatch[1]!);
        if (!self.taskPolls.has(taskId)) {
          sendJson(res, 404, { code: 'InvalidTask', message: 'unknown task' });
          return;
        }
        self.pollCount += 1;
        if (self.failPolls > 0) {
          self.failPolls -= 1;
          sendJson(res, 500, { code: 'InternalError', message: 'injected poll failure' });
          return;
        }
        if (self.holdPending) {
          sendJson(res, 200, { output: { task_id: taskId, task_status: 'PENDING' } });
          return;
        }
        const seen = self.taskPolls.get(taskId)! + 1;
        self.taskPolls.set(taskId, seen);
        if (seen <= self.pendingPollsPerTask) {
          sendJson(res, 200, { output: { task_id: taskId, task_status: 'PENDING' } });
          return;
        }
        sendJson(res, 200, {
          output: {
            task_id: taskId,
            task_status: 'SUCCEEDED',
            results: [{ transcription_url: `${self.baseUrl}/transcripts/${taskId}.json` }]
          }
        });
        return;
      }
      const transcriptMatch = /^\/transcripts\/[^/]+\.json$/.exec(url.pathname);
      if (req.method === 'GET' && transcriptMatch) {
        sendJson(res, 200, FAKE_TRANSCRIPT_PAYLOAD);
        return;
      }
      sendJson(res, 404, { error: `no fake route for ${req.method} ${url.pathname}` });
    });
    self = new FakeDashScopeServer(baseUrl, server);
    return self;
  }

  close(): Promise<void> {
    return closable(this.server)();
  }
}

// ---------------------------------------------------------------------------
// Fake OpenAI-compatible chat translation (see providers/translation).
// Numbered batch prompts get exact-origin JSON; anything else (context
// extraction, refinement splits) gets '{}', matching the stage parsers.
// ---------------------------------------------------------------------------

export class FakeTranslationServer implements FakeHttpServer {
  /** While true, every request fails with HTTP 500. */
  failAll = false;
  requestCount = 0;
  /** User prompts received, for scenario assertions. */
  readonly userPrompts: string[] = [];

  private constructor(
    public readonly baseUrl: string,
    private readonly server: Server
  ) {}

  static async start(): Promise<FakeTranslationServer> {
    let self: FakeTranslationServer;
    const { server, baseUrl } = await startServer((req, res, body) => {
      const url = new URL(req.url ?? '/', 'http://fake');
      if (req.method !== 'POST' || !url.pathname.endsWith('/chat/completions')) {
        sendJson(res, 404, { error: `no fake route for ${req.method} ${url.pathname}` });
        return;
      }
      self.requestCount += 1;
      if (self.failAll) {
        sendJson(res, 500, { error: { message: 'injected translation failure' } });
        return;
      }
      const parsed = JSON.parse(body) as { messages?: Array<{ role: string; content: string }> };
      const userPrompt = parsed.messages?.find((m) => m.role === 'user')?.content ?? '';
      self.userPrompts.push(userPrompt);
      sendJson(res, 200, {
        choices: [{ message: { role: 'assistant', content: answerPrompt(userPrompt) } }]
      });
    });
    self = new FakeTranslationServer(baseUrl, server);
    return self;
  }

  close(): Promise<void> {
    return closable(this.server)();
  }
}

function answerPrompt(userPrompt: string): string {
  const lines = userPrompt
    .split('\n')
    .map((line) => /^(\d+)\.\s(.*)$/.exec(line))
    .filter((m): m is RegExpExecArray => m !== null);
  if (lines.length === 0) return '{}';
  const out: Record<string, { origin: string; direct: string }> = {};
  for (const [, seq, text] of lines) {
    out[seq] = { origin: text, direct: `译文${seq}` };
  }
  return JSON.stringify(out);
}

// ---------------------------------------------------------------------------
// Fake media-api 0.2.0 (see src/providers/media/client.ts) + audio hosting.
// Serves the media audio bytes too, so the pipeline's trusted-host download
// (audioUrl host == media host) works against 127.0.0.1.
// ---------------------------------------------------------------------------

export class FakeMediaServer implements FakeHttpServer {
  prepareCount = 0;
  getCount = 0;
  cancelCount = 0;
  /** Job IDs prepared, in order. */
  readonly preparedVideoIds: string[] = [];
  /** While true, jobs stay in 'fetching' (used to hold a job mid-flight). */
  holdFetching = false;

  private jobSeq = 0;
  private readonly jobPolls = new Map<string, number>();
  private readonly jobVideos = new Map<string, string>();

  private constructor(
    public readonly baseUrl: string,
    private readonly server: Server,
    private readonly audioBytes: Buffer
  ) {}

  static async start(audioBytes: Buffer): Promise<FakeMediaServer> {
    let self: FakeMediaServer;
    const { server, baseUrl } = await startServer((req, res) => {
      const url = new URL(req.url ?? '/', 'http://fake');
      const prepareMatch = /^\/v1\/videos\/([^/]+)\/prepare$/.exec(url.pathname);
      if (req.method === 'POST' && prepareMatch) {
        const videoId = decodeURIComponent(prepareMatch[1]!);
        self.prepareCount += 1;
        self.preparedVideoIds.push(videoId);
        const jobId = `mj-${++self.jobSeq}`;
        self.jobPolls.set(jobId, 0);
        self.jobVideos.set(jobId, videoId);
        sendJson(res, 202, {
          jobId,
          status: 'queued',
          statusUrl: `${self.baseUrl}/v1/jobs/${jobId}`
        });
        return;
      }
      const jobMatch = /^\/v1\/jobs\/([^/]+)$/.exec(url.pathname);
      if (jobMatch && req.method === 'GET') {
        const jobId = decodeURIComponent(jobMatch[1]!);
        if (!self.jobPolls.has(jobId)) {
          sendJson(res, 404, { error: 'NOT_FOUND', message: 'unknown job' });
          return;
        }
        self.getCount += 1;
        const polls = self.jobPolls.get(jobId)! + 1;
        self.jobPolls.set(jobId, polls);
        const ready = !self.holdFetching && polls >= 2;
        sendJson(res, 200, {
          jobId,
          videoId: self.jobVideos.get(jobId),
          status: ready ? 'ready' : 'fetching',
          progress: ready ? 1 : 0.5,
          expiresAt: Date.now() + 2_700_000,
          errorCode: null,
          errorMessage: null,
          playback: ready
            ? {
                kind: 'mp4',
                url: `${self.baseUrl}/media/${jobId}/video.mp4`,
                audioUrl: `${self.baseUrl}/media/${jobId}/audio.mp3`,
                height: null,
                durationSeconds: 3
              }
            : null
        });
        return;
      }
      if (jobMatch && req.method === 'DELETE') {
        self.cancelCount += 1;
        sendJson(res, 200, { ok: true });
        return;
      }
      const mediaMatch = /^\/media\/[^/]+\/(audio\.mp3|video\.mp4)$/.exec(url.pathname);
      if (req.method === 'GET' && mediaMatch) {
        const isVideo = mediaMatch[1] === 'video.mp4';
        res.writeHead(200, {
          'content-type': isVideo ? 'video/mp4' : 'audio/mpeg',
          'content-length': self.audioBytes.length,
          'accept-ranges': 'bytes'
        });
        res.end(self.audioBytes);
        return;
      }
      sendJson(res, 404, { error: `no fake route for ${req.method} ${url.pathname}` });
    });
    self = new FakeMediaServer(baseUrl, server, audioBytes);
    return self;
  }

  close(): Promise<void> {
    return closable(this.server)();
  }
}

// ---------------------------------------------------------------------------
// Fake podcast origin: serves the episode MP3.
// ---------------------------------------------------------------------------

export class FakePodcastServer implements FakeHttpServer {
  downloadCount = 0;

  private constructor(
    public readonly baseUrl: string,
    private readonly server: Server,
    private readonly audioBytes: Buffer
  ) {}

  get episodeUrl(): string {
    return `${this.baseUrl}/episode.mp3`;
  }

  static async start(audioBytes: Buffer): Promise<FakePodcastServer> {
    let self: FakePodcastServer;
    const { server, baseUrl } = await startServer((req, res) => {
      const url = new URL(req.url ?? '/', 'http://fake');
      if (req.method === 'GET' && url.pathname === '/episode.mp3') {
        self.downloadCount += 1;
        res.writeHead(200, {
          'content-type': 'audio/mpeg',
          'content-length': self.audioBytes.length
        });
        res.end(self.audioBytes);
        return;
      }
      sendJson(res, 404, { error: `no fake route for ${req.method} ${url.pathname}` });
    });
    self = new FakePodcastServer(baseUrl, server, audioBytes);
    return self;
  }

  close(): Promise<void> {
    return closable(this.server)();
  }
}
