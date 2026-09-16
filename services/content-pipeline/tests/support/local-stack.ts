/**
 * WP15 Step 1 local stack: boots the REAL content service HTTP app in-process
 * (createApp + ContentWorker + real provider clients) with every external
 * dependency replaced by a loopback fake. Nothing leaves 127.0.0.1.
 *
 * The executor is created with short polling intervals via a cast — the
 * stages read optional timing knobs (pollIntervalMs) off their deps, and the
 * executor forwards the deps object verbatim.
 */

import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { createApp, type AppHandle } from '../../src/app.js';
import { loadConfig, type ServiceConfig } from '../../src/config.js';
import { openDatabase } from '../../src/jobs/migrations.js';
import { JobStore } from '../../src/jobs/job-store.js';
import { ContentMediaStore } from '../../src/domain/content-media-store.js';
import { ContentWorker } from '../../src/jobs/worker.js';
import { RedactingLogger } from '../../src/observability/logger.js';
import { KeyLayout } from '../../src/storage/keys.js';
import { DashScopeTranscriptionProvider } from '../../src/providers/asr/dashscope.js';
import { OpenAICompatibleTranslationProvider } from '../../src/providers/translation/chat-client.js';
import { HttpMediaServiceClient, SingleFlightMediaGate } from '../../src/providers/media/client.js';
import {
  createPipelineExecutor,
  type PipelineExecutorDeps
} from '../../src/pipeline/executor.js';
import type { PipelineExecutor } from '../../src/jobs/worker.js';

import { FakeDashScopeServer, FakeMediaServer, FakePodcastServer, FakeTranslationServer } from './fake-upstreams.js';
import { FakeS3ObjectStore } from './fake-s3.js';

const MIGRATIONS_DIR = new URL('../../migrations/', import.meta.url).pathname;

export const SERVICE_TOKEN = 'integration-service-token-0123456789';

export interface LocalStackOptions {
  /** Start the worker immediately (default true). */
  autoStartWorker?: boolean;
  workerId?: string;
}

export interface JobSnapshot {
  jobId: string;
  status: string;
  stage?: string;
  progress: number;
  audioReady: boolean;
  subtitlesReady: boolean;
  error: { code: string; message: string; retryable: boolean } | null;
  artifacts: { files?: Array<{ name: string; status: string }> } | null;
}

export class LocalStack {
  private constructor(
    readonly baseUrl: string,
    readonly config: ServiceConfig,
    readonly store: JobStore,
    readonly executor: PipelineExecutor,
    readonly fakes: {
      dashscope: FakeDashScopeServer;
      translation: FakeTranslationServer;
      media: FakeMediaServer;
      podcast: FakePodcastServer;
      s3: FakeS3ObjectStore;
    },
    private readonly app: AppHandle,
    private worker: ContentWorker | null,
    private readonly workerId: string,
    private readonly tempRoot: string
  ) {}

  static async start(audioBytes: Buffer, options: LocalStackOptions = {}): Promise<LocalStack> {
    const tempRoot = await mkdtemp(join(tmpdir(), 'wp15-integration-'));
    const podcast = await FakePodcastServer.start(audioBytes);
    const media = await FakeMediaServer.start(audioBytes);
    const dashscope = await FakeDashScopeServer.start();
    const translation = await FakeTranslationServer.start();
    const s3 = await FakeS3ObjectStore.start();

    const config = loadConfig({
      CONTENT_IDENTITY_MODE: 'selfhost', CONTENT_SERVICE_TOKEN: SERVICE_TOKEN,
      MEDIA_API_TOKEN: 'integration-media-token-0123456789',
      MEDIA_API_BASE_URL: media.baseUrl,
      DASHSCOPE_API_KEY: 'integration-dashscope-key-0123456789',
      DASHSCOPE_BASE_URL: dashscope.baseUrl,
      TRANSLATION_PROVIDER: 'dashscope',
      TRANSLATION_BASE_URL: translation.baseUrl,
      TRANSLATION_API_KEY: 'integration-translation-key-0123456789',
      TRANSLATION_MODEL: 'integration-model',
      R2_ACCOUNT_ID: 'integration-account',
      R2_ACCESS_KEY_ID: 'integration-r2-access',
      R2_SECRET_ACCESS_KEY: 'integration-r2-secret-0123456789',
      R2_BUCKET: 'linguacast-integration',
      R2_SIGNED_URL_TTL_SECONDS: '60',
      CONTENT_TEMP_ROOT: tempRoot,
      CONTENT_DATABASE_PATH: join(tempRoot, 'content.db')
    });

    const logger = new RedactingLogger(() => {});
    const db = openDatabase(config.databasePath, MIGRATIONS_DIR);
    const store = new JobStore(db);
    const mediaStore = new ContentMediaStore(db);
    const layout = new KeyLayout(config.r2);

    const asrProvider = new DashScopeTranscriptionProvider({
      apiKey: config.dashscope.apiKey,
      baseUrl: config.dashscope.baseUrl,
      submitTimeoutMs: 5_000,
      pollTimeoutMs: 5_000
    });
    const translationProvider = new OpenAICompatibleTranslationProvider({
      provider: config.translation.provider,
      baseUrl: config.translation.baseUrl,
      apiKey: config.translation.apiKey,
      model: config.translation.model,
      reasoningEffort: config.translation.reasoningEffort,
      networkRetries: config.translation.networkRetries,
      // Instant retry backoff keeps fault-injection scenarios fast.
      sleepImpl: () => Promise.resolve(),
      maxAttempts: 2,
      requestTimeoutMs: 5_000
    });
    const mediaClient = new SingleFlightMediaGate(
      new HttpMediaServiceClient({ baseUrl: config.mediaApi.baseUrl, token: config.mediaApi.token })
    );

    const executor = createPipelineExecutor({
      store,
      layout,
      objectStore: s3,
      config,
      logger,
      asrProvider,
      translationProvider,
      mediaClient,
      mediaStore,
      // Loopback fakes are explicitly allowed; the SSRF guard stays on for
      // everything else.
      ssrf: { allowAddress: (address) => address === '127.0.0.1' || address === '::1' },
      // Forwarded to the ASR/video polling loops (not part of the public
      // deps type — hence the cast).
      ...{ pollIntervalMs: 120 }
    } as PipelineExecutorDeps);

    const app = createApp({
      config,
      logger,
      jobRoutes: { config, store },
      artifactRoutes: { config, store, objects: s3, keys: layout },
      contentMediaRoutes: { config, store, mediaStore, objects: s3, keys: layout }
    });
    await new Promise<void>((resolve, reject) => {
      app.server.once('error', reject);
      app.server.listen(0, '127.0.0.1', resolve);
    });
    const address = app.server.address();
    if (address === null || typeof address === 'string') throw new Error('app has no address');
    const baseUrl = `http://127.0.0.1:${address.port}`;

    const workerId = options.workerId ?? `worker-${process.pid}`;
    const stack = new LocalStack(
      baseUrl,
      config,
      store,
      executor,
      { dashscope, translation, media, podcast, s3 },
      app,
      null,
      workerId,
      tempRoot
    );
    if (options.autoStartWorker !== false) stack.startWorker(workerId);
    return stack;
  }

  /** Starts (or restarts) a worker against the same store. */
  startWorker(workerId = this.workerId): ContentWorker {
    const worker = new ContentWorker({
      store: this.store,
      logger: new RedactingLogger(() => {}),
      workerId,
      executor: this.executor,
      leaseMs: 5_000,
      pollIntervalMs: 100,
      heartbeatIntervalMs: 1_000
    });
    worker.start();
    this.worker = worker;
    return worker;
  }

  stopWorker(): void {
    this.worker?.stop();
    this.worker = null;
  }

  /** Authenticated API call against the local service. */
  async api(
    method: string,
    path: string,
    body?: unknown
  ): Promise<{ status: number; json: Record<string, unknown> }> {
    const res = await fetch(`${this.baseUrl}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${SERVICE_TOKEN}`,
        ...(body !== undefined ? { 'content-type': 'application/json' } : {})
      },
      body: body !== undefined ? JSON.stringify(body) : undefined
    });
    return { status: res.status, json: (await res.json()) as Record<string, unknown> };
  }

  async getJob(jobId: string): Promise<JobSnapshot> {
    const { status, json } = await this.api('GET', `/v1/content-jobs/${jobId}`);
    if (status !== 200) throw new Error(`GET job ${jobId} failed: HTTP ${status}`);
    return json as unknown as JobSnapshot;
  }

  /** Polls the job until the predicate holds or the deadline expires. */
  async waitForJob(
    jobId: string,
    predicate: (job: JobSnapshot) => boolean,
    timeoutMs = 60_000
  ): Promise<{ job: JobSnapshot; history: JobSnapshot[] }> {
    const deadline = Date.now() + timeoutMs;
    const history: JobSnapshot[] = [];
    for (;;) {
      const job = await this.getJob(jobId);
      const last = history[history.length - 1];
      if (!last || last.status !== job.status || last.stage !== job.stage ||
          last.audioReady !== job.audioReady || last.progress !== job.progress) {
        history.push(job);
      }
      if (predicate(job)) return { job, history };
      if (Date.now() > deadline) {
        throw new Error(
          `job ${jobId} did not reach expected state within ${timeoutMs}ms; ` +
            `last: ${JSON.stringify(job)}`
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 60));
    }
  }

  async cleanup(): Promise<void> {
    this.stopWorker();
    await this.app.close();
    this.store.close();
    await Promise.all([
      this.fakes.dashscope.close(),
      this.fakes.translation.close(),
      this.fakes.media.close(),
      this.fakes.podcast.close(),
      this.fakes.s3.close()
    ]);
    await rm(this.tempRoot, { recursive: true, force: true });
  }
}
