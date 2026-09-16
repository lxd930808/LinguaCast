import { resolveTranscriptSource } from './api/v2/sources.js';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { ConfigError, loadConfig, registerConfigSecrets } from './config/index.js';
import { loadSystemPrompt } from './prompts/load.js';
import { createApp, listen } from './app.js';
import { RedactingLogger } from './observability/logger.js';
import { openDatabase } from './db/migrations.js';
import {
  configPresenceCheck,
  piConfigCheck,
  tempDirWritableCheck,
  ytdlpCheck,
  youtubeApiCheck,
  podcastIndexCheck,
  appleSearchCheck,
  rssCheck,
  workspaceCheck,
  skillsCheck,
  rgCheck,
  webCheck
} from './api/health.js';
import {
  ApplePodcastSearchProvider,
  YouTubeDataApiProvider,
  YtDlpSearchProvider
} from './search/providers.js';
import { FakeAgentRuntime } from './agent/runtime.js';
import { PiAgentRuntime } from './agent/pi-adapter.js';
import { JsonFileCredentialStore, listAuthProviders } from './agent/pi-credentials.js';
import { PodcastIndexClient } from './search/podcast/podcast-index-client.js';
import { PodcastSearchOrchestrator } from './search/podcast/orchestrator.js';
import { SearchOrchestrator } from './search/orchestrator.js';
import { SqliteSearchCache } from './search/cache.js';
import { defaultHttpGet } from './search/http.js';
import { HttpV10ContentClient } from './content/v10-client.js';
import { createPiSessionTitleGenerator } from './research-v2/session-title.js';
import { createV2Stack } from './api/v2/assemble.js';
import { loadSkillRegistry } from './skills/registry.js';
import { isWebSearchConfigured } from './web/provider.js';
import { identityResolverFor } from './api/identity-gate.js';
import { HttpQuotaClient } from './quota/quota-client.js';
import { TurnSettlementDispatcher } from './quota/settlement-dispatcher.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = [join(HERE, '..', 'migrations'), join(HERE, '..', '..', 'migrations')].find((path) =>
  existsSync(path)
) ?? join(HERE, '..', 'migrations');

async function main(): Promise<void> {
  const logger = new RedactingLogger();
  let config;
  try {
    config = loadConfig();
    loadSystemPrompt(config.systemPromptPath);
  } catch (error) {
    if (error instanceof ConfigError) {
      logger.error('startup configuration invalid', { variable: error.variable, reason: error.message });
      process.exit(1);
    }
    throw error;
  }
  registerConfigSecrets(config, (value) => logger.registerSecret(value));
  logger.registerSecret(process.env.DEEPSEEK_API_KEY);
  logger.registerSecret(process.env.OPENROUTER_API_KEY);
  logger.registerSecret(config.podcastIndexApiKey);
  logger.registerSecret(config.podcastIndexApiSecret);
  const authProviders = listAuthProviders(config.piAuthPath);
  const credStore = new JsonFileCredentialStore(config.piAuthPath);
  for (const providerId of authProviders) {
    const cred = await credStore.read(providerId);
    if (cred?.type === 'oauth') {
      if ('access' in cred && typeof cred.access === 'string') logger.registerSecret(cred.access);
      if ('refresh' in cred && typeof cred.refresh === 'string') logger.registerSecret(cred.refresh);
    }
  }
  logger.info('pi credentials available', { providers: authProviders.join(',') || 'none' });

  const db = openDatabase(config.databasePath, MIGRATIONS_DIR);

  const ytdlp = new YtDlpSearchProvider(config);
  const youtubeApi = config.youtubeApiKey ? new YouTubeDataApiProvider(config) : null;
  const apple = new ApplePodcastSearchProvider(config);
  const podcastIndex =
    config.podcastIndexEnabled && config.podcastIndexApiKey && config.podcastIndexApiSecret
      ? new PodcastIndexClient({
          apiKey: config.podcastIndexApiKey,
          apiSecret: config.podcastIndexApiSecret,
          baseUrl: config.podcastIndexBaseUrl,
          timeoutMs: config.podcastIndexTimeoutMs
        })
      : null;
  const podcast = new PodcastSearchOrchestrator({
    index: podcastIndex,
    apple,
    httpGet: defaultHttpGet,
    enabled: config.podcastIndexEnabled
  });
  const orchestrator = new SearchOrchestrator({
    youtube: ytdlp,
    youtubeApi,
    podcast,
    cache: new SqliteSearchCache(db),
    searchV2: config.searchV2,
    hydrationEnabled: config.youtubeHydrationEnabled,
    successTtlMs: config.searchSuccessTtlSeconds * 1000,
    emptyTtlMs: config.searchEmptyTtlSeconds * 1000
  });
  const agent = process.env.ASSISTANT_FAKE_AGENT === '1' ? new FakeAgentRuntime() : new PiAgentRuntime(config);
  const v10 = new HttpV10ContentClient(config.v10.baseUrl, config.v10.token, fetch, config.identity.contextSigningKey);
  const quotaClient = config.quotaEnabled
    ? new HttpQuotaClient({ baseUrl: config.identity.accountServiceUrl ?? '', token: config.identity.introspectionToken ?? '' })
    : null;
  const v2 = createV2Stack({
    db,
    config,
    agent,
    v10,
    quota: quotaClient,
    searchOrchestrator: orchestrator,
    titleGenerator:
      process.env.ASSISTANT_FAKE_AGENT === '1' ? undefined : createPiSessionTitleGenerator(config)
  });

  const identity = identityResolverFor(config);
  logger.info('identity mode', { mode: config.identity.mode, internalCallers: String(config.identity.internalCallers.length) });
  const app = createApp({
    config,
    logger,
    v2: v2.application,
    identity,
    internal: { config, identity, logger, v2: { store: v2.store, orchestrator: v2.orchestrator } },
    readiness: {
      config: configPresenceCheck(config),
      database: async () => {
        try {
          db.prepare('SELECT 1').get();
          return { ok: true };
        } catch (error) {
          return { ok: false, detail: (error as NodeJS.ErrnoException).code ?? 'query failed' };
        }
      },
      tempDir: tempDirWritableCheck(config.tempRoot),
      piConfig: piConfigCheck(config.piConfigDir),
      ytdlp: ytdlpCheck(config.ytdlpPath),
      youtubeApi: youtubeApiCheck(config),
      podcastIndex: podcastIndexCheck(config),
      apple: appleSearchCheck(config),
      rss: rssCheck(),
      workspace: workspaceCheck(
        config.workspaceRoot || join(dirname(config.databasePath), 'workspaces'),
        true
      ),
      skills: skillsCheck(true, () => loadSkillRegistry()),
      rg: rgCheck(config.rgPath, true),
      web: webCheck(config.assistantWebEnabled, isWebSearchConfigured(config))
    }
  });
  logger.info('search flags', {
    searchV2: config.searchV2 ? '1' : '0',
    podcastIndex: config.podcastIndexEnabled ? (podcastIndex ? 'configured' : 'misconfigured') : 'disabled',
    youtubeHydration: config.youtubeHydrationEnabled ? '1' : '0'
  });
  await listen(app, config, logger);
  v2.scheduler.enqueue();
  v2.orchestrator.transcriptJobs.startRecovery((job) => resolveTranscriptSource(
    v2.store, v2.orchestrator.writerFor(job.researchId), job.researchId, job.sourceId
  ));
  const settlements = quotaClient ? new TurnSettlementDispatcher({ store: v2.store, client: quotaClient, logger }) : null;
  settlements?.start();

  let shuttingDown = false;
  const shutdown = (signal: string) => {
    if (shuttingDown) return;
    shuttingDown = true;
    logger.info('shutdown requested', { signal });
    settlements?.stop();
    v2.orchestrator.transcriptJobs.stopRecovery()
      .then(() => app.close())
      .then(() => {
        db.close();
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
