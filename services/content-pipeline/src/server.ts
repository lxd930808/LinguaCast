import { ConfigError, loadConfig, registerConfigSecrets } from './config.js';
import { createApp, listen } from './app.js';
import { RedactingLogger } from './observability/logger.js';
import { openDatabase } from './jobs/migrations.js';
import { JobStore } from './jobs/job-store.js';
import { ContentWorker } from './jobs/worker.js';
import { VideoMediaTaskStore } from './domain/video-media-task-store.js';
import { MediaTaskRunner } from './pipeline/video/media-task-runner.js';
import { ContentMediaStore } from './domain/content-media-store.js';
import { KeyLayout } from './storage/keys.js';
import { MediaRetentionWorker } from './storage/media-retention.js';
import { R2ObjectStore } from './storage/r2-store.js';
import { DashScopeTranscriptionProvider } from './providers/asr/dashscope.js';
import { OpenAICompatibleTranslationProvider } from './providers/translation/chat-client.js';
import { HttpMediaServiceClient, SingleFlightMediaGate } from './providers/media/client.js';
import { identityResolverFor } from './api/auth.js';
import { HttpQuotaClient } from './quota/quota-client.js';
import { DefaultDurationProber } from './quota/duration-probe.js';
import { QuotaSettlementDispatcher } from './quota/settlement-dispatcher.js';
import { createPipelineExecutor } from './pipeline/executor.js';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'migrations');

async function main(): Promise<void> {
  const logger = new RedactingLogger();
  let config;
  try {
    config = loadConfig();
  } catch (error) {
    if (error instanceof ConfigError) {
      // Names the variable only; values are never printed.
      logger.error('startup configuration invalid', { variable: error.variable, reason: error.message });
      process.exit(1);
    }
    throw error;
  }
  registerConfigSecrets(config, (value) => logger.registerSecret(value));

  const db = openDatabase(config.databasePath, MIGRATIONS_DIR);
  const store = new JobStore(db);
  const mediaStore = new ContentMediaStore(db);
  const keys = new KeyLayout(config.r2);
  const objects = new R2ObjectStore(config.r2);
  const asrProvider = new DashScopeTranscriptionProvider({
    apiKey: config.dashscope.apiKey,
    baseUrl: config.dashscope.baseUrl
  });
  const translationProvider = new OpenAICompatibleTranslationProvider({
    provider: config.translation.provider,
    baseUrl: config.translation.baseUrl,
    apiKey: config.translation.apiKey,
    model: config.translation.model,
    reasoningEffort: config.translation.reasoningEffort,
    requestTimeoutMs: config.translation.requestTimeoutMs,
    networkRetries: config.translation.networkRetries
  });
  const mediaClient = new SingleFlightMediaGate(
    new HttpMediaServiceClient({
      baseUrl: config.mediaApi.baseUrl,
      token: config.mediaApi.token,
      contextSigningKey: config.identity.contextSigningKey
    })
  );
  const mediaTasks=new VideoMediaTaskStore(db);
  const mediaRunner=new MediaTaskRunner(mediaTasks,{store,layout:keys,objectStore:objects,config,logger,mediaClient,mediaStore});
  const workerOptions = {
    store,
    logger,
    workerId: `worker-${process.pid}`,
    executor: createPipelineExecutor({
      store,
      layout: keys,
      objectStore: objects,
      config,
      logger,
      asrProvider,
      translationProvider,
      mediaClient,
      mediaStore,
      mediaRunner
    })
  };
  const claimLimits = { perOwner: config.quota.accountConcurrency, global: config.quota.globalConcurrency };
  const workers = Array.from(
    { length: config.quota.globalConcurrency },
    (_, index) => new ContentWorker({ ...workerOptions, workerId: `worker-${process.pid}-${index}`, claimLimits })
  );
  for (const worker of workers) worker.start();
  mediaRunner.start();
  const retention = new MediaRetentionWorker({
    mediaStore,
    objects,
    keys,
    logger,
    intervalMs: config.videoMediaCleanupIntervalSeconds * 1000,
    batchSize: config.videoMediaCleanupBatchSize,
    mediaTasks,
    cleanupCache: () => mediaRunner.cleanupCache(),
    enabled: () => config.videoMediaPromotionEnabled
  });
  retention.start();

  const identity = identityResolverFor(config);
  const quotaClient = config.quota.enabled
    ? new HttpQuotaClient({ baseUrl: config.identity.accountServiceUrl ?? '', token: config.identity.introspectionToken ?? '' })
    : null;
  const quota = quotaClient
    ? {
        client: quotaClient,
        prober: new DefaultDurationProber({ tempRoot: config.tempRoot, mediaClient, headBytes: config.quota.probeHeadBytes })
      }
    : undefined;
  const settlements = quotaClient ? new QuotaSettlementDispatcher({ store, client: quotaClient, logger }) : null;
  settlements?.start();
  logger.info('identity mode', { mode: config.identity.mode, internalCallers: config.identity.internalCallers.length });
  const app = createApp({
    config,
    logger,
    internalRoutes: { config, store, objects, keys, logger, identity, workers, mediaRunner },
    jobRoutes: { config, store, identity, quota },
    artifactRoutes: { config, store, objects, keys, identity },
    contentMediaRoutes: { config, store, mediaStore, objects, keys, mediaTasks, identity },
    readinessOverrides: {
      database: async () => {
        try {
          db.prepare('SELECT 1').get();
          return { ok: true };
        } catch (error) {
          return { ok: false, detail: (error as NodeJS.ErrnoException).code ?? 'query failed' };
        }
      },
      workerLease: async () => ({ ok: true, detail: workers.some((worker) => worker.busy) ? 'busy' : 'idle' })
    }
  });
  await listen(app, config, logger);

  let shuttingDown = false;
  const shutdown = (signal: string) => {
    if (shuttingDown) return;
    shuttingDown = true;
    logger.info('shutdown requested', { signal });
    for (const worker of workers) worker.stop();
    settlements?.stop();
    retention.stop();
    mediaRunner.stop();
    // Stop accepting new connections; wait for in-flight requests to finish.
    app
      .close()
      .then(() => {
        store.close();
        logger.info('shutdown complete');
        process.exit(0);
      })
      .catch((error) => {
        logger.error('shutdown failed', { err: String(error) });
        process.exit(1);
      });
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((error) => {
  process.stderr.write(`fatal: ${String(error)}\n`);
  process.exit(1);
});
