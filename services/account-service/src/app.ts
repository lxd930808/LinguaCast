import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';

import type { ServiceConfig } from './config.js';
import { AccountError } from './domain/errors.js';
import type { Logger } from './observability/logger.js';
import {
  BodyTooLargeError,
  InvalidContentTypeError,
  newTraceId,
  parseUrl,
  sendAccountError,
  sendError
} from './api/http-utils.js';
import { handleRoutes, type RouteDeps } from './api/routes.js';

export interface AppOptions extends RouteDeps {
  logger: Logger;
}

export interface AppHandle {
  server: Server;
  close: () => Promise<void>;
}

export function createApp(options: AppOptions): AppHandle {
  const { logger } = options;
  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const traceId = newTraceId();
    res.setHeader('x-trace-id', traceId);
    try {
      if (await handleRoutes(req, res, options)) return;
      sendError(
        res,
        404,
        { code: 'NOT_FOUND', message: `No route for ${req.method} ${parseUrl(req).pathname}`, retryable: false },
        traceId
      );
    } catch (error) {
      if (error instanceof AccountError) {
        if (error.status >= 500) logger.warn('request failed', { traceId, code: error.code });
        sendAccountError(res, error, traceId);
        return;
      }
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

export function listen(app: AppHandle, config: Pick<ServiceConfig, 'host' | 'port'>, logger: Logger): Promise<void> {
  return new Promise((resolve, reject) => {
    app.server.once('error', reject);
    app.server.listen(config.port, config.host, () => {
      logger.info('account service listening', { host: config.host, port: config.port });
      resolve();
    });
  });
}
