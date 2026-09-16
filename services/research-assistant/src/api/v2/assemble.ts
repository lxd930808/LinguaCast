import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { lookup as dnsLookup } from 'node:dns/promises';
import type { DatabaseSync } from 'node:sqlite';

import type { AgentRuntime } from '../../agent/runtime.js';
import type { ServiceConfig } from '../../config/index.js';
import type { V10ContentClient } from '../../content/v10-client.js';
import { V2Store } from '../../db/v2/store.js';
import { reclaimExpiredTurnLeases } from '../../db/v2/recovery.js';
import { V2ResearchOrchestrator } from '../../research-v2/orchestrator.js';
import type { SearchOrchestrator } from '../../search/orchestrator.js';
import type { SessionTitleGenerator } from '../../research-v2/session-title.js';
import { loadAdminGrants } from '../../workspace/grants.js';
import { WorkspaceManager } from '../../workspace/manager.js';
import { createWebSearchProvider } from '../../web/provider.js';
import { WebResearch } from '../../web/service.js';
import type { DnsLookup } from '../../web/policy.js';
import type { PageFetch } from '../../web/fetch-client.js';
import { V2AssistantApplication } from './application.js';
import { mediaSearchFromOrchestrator } from './media-search.js';
import type { QuotaClient } from '../../quota/quota-client.js';
import { TurnScheduler } from '../../quota/turn-scheduler.js';

export interface V2Stack {
  store: V2Store;
  workspace: WorkspaceManager;
  orchestrator: V2ResearchOrchestrator;
  application: V2AssistantApplication;
  scheduler: TurnScheduler;
}

const publicLookup: DnsLookup = async (hostname) => {
  const all = await dnsLookup(hostname, { all: true });
  return all.map((row) => row.address);
};

const defaultFetch: PageFetch = async (url, init) => {
  const response = await fetch(url, init);
  return {
    status: response.status,
    headers: response.headers,
    arrayBuffer: () => response.arrayBuffer()
  };
};

export function createV2Stack(options: {
  db: DatabaseSync;
  config: ServiceConfig;
  agent: AgentRuntime;
  v10: V10ContentClient;
  searchOrchestrator?: SearchOrchestrator | null;
  titleGenerator?: SessionTitleGenerator | null;
  quota?: QuotaClient | null;
}): V2Stack {
  const dataDir = dirname(options.config.databasePath);
  const workspaceRoot = options.config.workspaceRoot || join(dataDir, 'workspaces');
  const globalMemoryRoot = options.config.globalMemoryRoot || join(dataDir, 'global-memory');
  const sharedVersionRoot = options.config.sharedVersionRoot || join(dataDir, 'shared-versions');
  mkdirSync(workspaceRoot, { recursive: true });
  mkdirSync(globalMemoryRoot, { recursive: true });
  mkdirSync(sharedVersionRoot, { recursive: true });

  const store = new V2Store(options.db);
  reclaimExpiredTurnLeases(store);
  const workspace = new WorkspaceManager({ root: workspaceRoot, store });
  workspace.reconcile();
  // Admin shared directories are deployment-wide; they are never exposed across accounts.
  const adminGrants =
    options.config.identity.mode === 'selfhost' && options.config.sharedGrantsPath
      ? loadAdminGrants(options.config.sharedGrantsPath)
      : [];
  const webProvider = createWebSearchProvider(options.config);
  const orchestrator = new V2ResearchOrchestrator({
    store,
    workspace,
    agent: options.agent,
    v10: options.v10,
    adminGrants,
    mediaSearch: mediaSearchFromOrchestrator(options.searchOrchestrator),
    titleGenerator: options.titleGenerator ?? null,
    webFor: (_researchId, writer) => {
      if (!options.config.assistantWebEnabled) return null;
      return new WebResearch({
        enabled: true,
        provider: webProvider,
        writer,
        lookup: publicLookup,
        fetchImpl: defaultFetch,
        maxPageBytes: options.config.maxWebPageBytes
      });
    },
    config: {
      assistantWebEnabled: options.config.assistantWebEnabled,
      sharedWriteEnabled: options.config.sharedWriteEnabled,
      rgPath: options.config.rgPath,
      maxGrepMatches: options.config.maxGrepMatches,
      maxGrepMs: options.config.maxGrepMs,
      globalMemoryRoot,
      sharedVersionRoot
    }
  });
  const scheduler = new TurnScheduler({
    store,
    run: (turnId) => orchestrator.runTurn(turnId),
    limits: { perOwner: options.config.accountTurnConcurrency, global: options.config.globalPiTurns }
  });
  const application = new V2AssistantApplication({
    store,
    orchestrator,
    adminGrants,
    sharedWriteEnabled: options.config.sharedWriteEnabled,
    quota: options.quota ?? null,
    scheduler
  });
  return { store, workspace, orchestrator, application, scheduler };
}
