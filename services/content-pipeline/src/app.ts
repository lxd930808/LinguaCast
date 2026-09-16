import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';

import type { ServiceConfig } from './config.js';
import type { Logger } from './observability/logger.js';
import {
  handleHealthLive,
  handleHealthReady,
  isHealthLiveRequest,
  isHealthReadyRequest,
  objectStoreConfigCheck,
  tempDirWritableCheck,
  type ReadinessChecks
} from './api/health-route.js';
import {
  attachRequestContext,
  BodyTooLargeError,
  InvalidContentTypeError,
  parseUrl,
  sendError
} from './api/http-utils.js';
import { handleJobRoutes, type JobRouteDeps } from './api/job-routes.js';
import { handleArtifactRoutes, type ArtifactRouteDeps } from './api/artifact-routes.js';
import { handleContentMediaRoutes, type ContentMediaRouteDeps } from './api/content-media-route.js';
import { handleInternalRoutes, type InternalRouteDeps } from './api/internal-routes.js';

export const SERVICE_VERSION = '0.1.0';

export interface AppOptions {
  config: ServiceConfig;
  logger: Logger;
  /** WP2 wires real database/lease checks; defaults keep the scaffold bootable. */
  readinessOverrides?: Partial<ReadinessChecks>;
  /** Job API dependencies; absent in bare scaffold mode. */
  jobRoutes?: JobRouteDeps;
  /** Artifact/playback API dependencies (WP3). */
  artifactRoutes?: ArtifactRouteDeps;
  /** Content-key video media playback (V12). */
  contentMediaRoutes?: ContentMediaRouteDeps;
  /** Internal service routes: account purge (V18). */
  internalRoutes?: InternalRouteDeps;
}

export interface AppHandle {
  server: Server;
  close: () => Promise<void>;
}

export function createApp(options: AppOptions): AppHandle {
  const { config, logger } = options;
  const checks: ReadinessChecks = {
    database: async () => ({ ok: true, detail: 'not yet wired (WP2)' }),
    objectStoreConfig: objectStoreConfigCheck(config),
    tempDirWritable: tempDirWritableCheck(config.tempRoot),
    workerLease: async () => ({ ok: true, detail: 'not yet wired (WP2)' }),
    ...options.readinessOverrides
  };

  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const { traceId } = attachRequestContext(res);
    try {
      if (isHealthLiveRequest(req)) {
        handleHealthLive(res, SERVICE_VERSION);
        return;
      }
      if (isHealthReadyRequest(req)) {
        await handleHealthReady(req, res, SERVICE_VERSION, checks);
        return;
      }
      if (options.internalRoutes && (await handleInternalRoutes(req, res, options.internalRoutes))) {
        return;
      }
      if (options.jobRoutes && (await handleJobRoutes(req, res, options.jobRoutes))) {
        return;
      }
      if (options.artifactRoutes && (await handleArtifactRoutes(req, res, options.artifactRoutes))) {
        return;
      }
      if (options.contentMediaRoutes && (await handleContentMediaRoutes(req, res, options.contentMediaRoutes))) {
        return;
      }
      sendError(
        res,
        404,
        { code: 'JOB_NOT_FOUND', message: `No route for ${req.method} ${parseUrl(req).pathname}`, retryable: false },
        traceId
      );
    } catch (error) {
      if (error instanceof BodyTooLargeError) {
        sendError(res, 413, { code: 'INVALID_REQUEST', message: 'request body too large', retryable: false }, traceId);
        return;
      }
      if (error instanceof InvalidContentTypeError) {
        sendError(res, 400, { code: 'INVALID_REQUEST', message: error.message, retryable: false }, traceId);
        return;
      }
      logger.error('unhandled request error', { traceId, err: String(error) });
      sendError(res, 500, { code: 'INTERNAL_ERROR', message: 'unhandled server error', retryable: false }, traceId);
    }
  });

  let closePromise: Promise<void> | null = null;
  return {
    server,
    close: () => {
      // Idempotent: SIGTERM, test teardown and operator stop may race.
      closePromise ??= new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
      return closePromise;
    }
  };
}

export function listen(app: AppHandle, config: ServiceConfig, logger: Logger): Promise<void> {
  return new Promise((resolve, reject) => {
    app.server.once('error', reject);
    app.server.listen(config.port, config.host, () => {
      logger.info('content service listening', { host: config.host, port: config.port });
      resolve();
    });
  });
}
