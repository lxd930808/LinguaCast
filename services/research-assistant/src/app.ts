import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';

import type { ServiceConfig } from './config/index.js';
import type { Logger } from './observability/logger.js';
import {
  handleHealthLive,
  handleHealthReady,
  isHealthLiveRequest,
  isHealthReadyRequest,
  type ReadinessChecks
} from './api/health.js';
import { attachRequestContext, BodyTooLargeError, InvalidContentTypeError, parseUrl, sendError } from './api/http-utils.js';
import { authenticate } from './api/identity-gate.js';
import { handleInternalRoutes, type InternalRouteDeps } from './api/internal-routes.js';
import { handleV2Api } from './api/v2/routes.js';
import type { IdentityResolver } from './auth/identity.js';
import type { V2AssistantApplication } from './api/v2/application.js';

export const SERVICE_VERSION = '0.1.0';

export interface AppOptions {
  config: ServiceConfig;
  logger: Logger;
  readiness: ReadinessChecks;
  v2?: V2AssistantApplication;
  /** Defaults to a resolver built from `config.identity`. */
  identity?: IdentityResolver;
  /** Internal service routes (account purge). */
  internal?: InternalRouteDeps;
}

export interface AppHandle {
  server: Server;
  close: () => Promise<void>;
}

export function createApp(options: AppOptions): AppHandle {
  const { config, logger } = options;
  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const { traceId } = attachRequestContext(req, res);
    try {
      if (isHealthLiveRequest(req)) {
        handleHealthLive(res);
        return;
      }
      if (isHealthReadyRequest(req)) {
        await handleHealthReady(req, res, options.readiness);
        return;
      }
      const path = parseUrl(req).pathname;
      if (path.startsWith('/internal/')) {
        if (options.internal && (await handleInternalRoutes(req, res, options.internal, traceId))) return;
        sendError(res, 404, { code: 'NOT_FOUND', message: `No route for ${req.method} ${path}`, retryable: false }, traceId);
        return;
      }

      if (path.startsWith('/v2/assistant/')) {
        const caller = await authenticate(req, res, config, options.identity, traceId);
        if (!caller) return;
        if (caller.via !== 'public') {
          sendError(res, 401, { code: 'AUTH_REQUIRED', message: 'assistant routes require a user credential', retryable: false }, traceId);
          return;
        }
        if (!options.v2) {
          sendError(
            res,
            503,
            { code: 'ASSISTANT_V2_DISABLED', message: 'assistant v2 is not configured', retryable: false },
            traceId
          );
          return;
        }
        if (await handleV2Api(req, res, options.v2, config, traceId, caller.identity.accountId)) return;
      }
      // V18 removed the assistant V1 business API; /v1/assistant/* is an unknown route like any other.
      sendError(
        res,
        404,
        { code: 'NOT_FOUND', message: `No route for ${req.method} ${path}`, retryable: false },
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
      logger.info('assistant service listening', { host: config.host, port: config.port });
      resolve();
    });
  });
}
