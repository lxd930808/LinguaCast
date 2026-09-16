import type { IncomingMessage, ServerResponse } from 'node:http';

import type { ServiceConfig } from '../config.js';
import { IdentityError, IdentityResolver, type ResolvedCaller } from '../auth/identity.js';
import { sendError } from './http-utils.js';

/**
 * Authentication gate for every content route (V18 WP03). Job IDs, content
 * keys and file names never imply authorization: callers are resolved to a
 * RequestIdentity and every lookup is filtered by its accountId.
 */

const resolvers = new WeakMap<ServiceConfig, IdentityResolver>();

export function identityResolverFor(config: ServiceConfig): IdentityResolver {
  let resolver = resolvers.get(config);
  if (!resolver) {
    resolver = new IdentityResolver({
      mode: config.identity.mode,
      selfhostToken: config.serviceToken || null,
      accountServiceUrl: config.identity.accountServiceUrl,
      introspectionToken: config.identity.introspectionToken,
      internalCallers: config.identity.internalCallers,
      contextSigningKey: config.identity.contextSigningKey
    });
    resolvers.set(config, resolver);
  }
  return resolver;
}

export interface AuthDeps {
  config: ServiceConfig;
  identity?: IdentityResolver;
}

/** Resolves the caller or writes the contract error and returns null. */
export async function authenticate(
  req: IncomingMessage,
  res: ServerResponse,
  deps: AuthDeps,
  traceId: string
): Promise<ResolvedCaller | null> {
  try {
    return await (deps.identity ?? identityResolverFor(deps.config)).resolve(req);
  } catch (error) {
    if (!(error instanceof IdentityError)) throw error;
    sendError(
      res,
      error.status,
      {
        code: error.code,
        message: error.message,
        retryable: error.retryable,
        ...(error.retryAfterSeconds !== undefined ? { retryAfterSeconds: error.retryAfterSeconds } : {})
      },
      traceId
    );
    return null;
  }
}
