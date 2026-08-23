import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { networkInterfaces } from 'node:os';
import { mkdir } from 'node:fs/promises';

import { handleHealth } from './api/health-route.js';
import { handleJob } from './api/job-route.js';
import { handleMedia } from './api/media-route.js';
import { handlePrepare } from './api/prepare-route.js';
import { parseUrl, sendJson } from './api/http-utils.js';
import { loadConfig, SERVICE_VERSION } from './config.js';
import { JobRunner } from './jobs/job-runner.js';
import { JobStore } from './jobs/job-store.js';

function lanIPv4Addresses(): string[] {
  const nets = networkInterfaces();
  const addresses: string[] = [];
  for (const entries of Object.values(nets)) {
    for (const entry of entries ?? []) {
      if (entry.family === 'IPv4' && !entry.internal) {
        addresses.push(entry.address);
      }
    }
  }
  return addresses;
}

async function main(): Promise<void> {
  const config = loadConfig();
  await mkdir(config.mediaRoot, { recursive: true });

  const store = new JobStore(config);
  const runner = new JobRunner(store, config);
  const resumableJobs = await store.restore();
  store.startCleanupLoop();
  for (const job of resumableJobs) {
    console.log(
      `[job ${job.jobId}] restored videoId=${job.videoId} progress=${job.progress.toFixed(3)}`
    );
    runner.enqueue(job.jobId);
  }

  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    try {
      res.setHeader('Access-Control-Allow-Origin', '*');
      res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type, Range');
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, DELETE, HEAD, OPTIONS');
      if (req.method === 'OPTIONS') {
        res.statusCode = 204;
        res.end();
        return;
      }

      const url = parseUrl(req);
      if (url.pathname === '/health' && req.method === 'GET') {
        await handleHealth(req, res, config);
        return;
      }
      if (await handlePrepare(req, res, config, store, runner)) return;
      if (await handleJob(req, res, config, store, runner)) return;
      if (await handleMedia(req, res, config, store)) return;

      sendJson(res, 404, { error: 'NOT_FOUND', message: 'Unknown route' });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error('[server] unhandled', message);
      if (!res.headersSent) {
        sendJson(res, 500, { error: 'INTERNAL_ERROR', message });
      } else {
        res.end();
      }
    }
  });

  server.listen(config.port, config.host, () => {
    const lan = lanIPv4Addresses();
    console.log('=== local-youtube-media-service ===');
    console.log(`version: ${SERVICE_VERSION}`);
    console.log(`listening: http://${config.host}:${config.port}`);
    console.log(`publicBaseUrl: ${config.publicBaseUrl}`);
    console.log(`downloadEngine: ${config.downloadEngine}`);
    console.log(`preferredHeight: ${config.preferredHeight}`);
    console.log(`maxConcurrentJobs: ${config.maxConcurrentJobs}`);
    console.log(`r2: ${config.r2 ? 'enabled' : 'disabled'}`);
    console.log(`requireMediaAuth: ${config.requireMediaAuth}`);
    for (const ip of lan) {
      console.log(`lan: http://${ip}:${config.port}`);
    }
    console.log(`mediaRoot: <configured>`);
    console.log('Set iOS/tvOS Debug env:');
    console.log('  YT_PLAYBACK_BACKEND=local-service');
    console.log(`  YT_LOCAL_MEDIA_BASE_URL=${config.publicBaseUrl}`);
    console.log('  YT_LOCAL_MEDIA_TOKEN=<AUTH_TOKEN value>');
    console.log('  YT_LOCAL_MEDIA_MODE=mp4');
    console.log(`  YT_LOCAL_MEDIA_PREFERRED_HEIGHT=${config.preferredHeight}`);
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
