import type { IncomingMessage, ServerResponse } from 'node:http';

import { IdentityError, IdentityResolver, type ResolvedCaller } from '../auth/identity.js';
import type { ServiceConfig } from '../config/index.js';
import { sendError } from './http-utils.js';

/**
 * Authentication gate for assistant routes (V18 WP03). Research, turn,
 * artifact and proposal IDs never imply authorization: callers resolve to a
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

/** Resolves the caller or writes the contract error and returns null. */
export async function authenticate(
  req: IncomingMessage,
  res: ServerResponse,
  config: ServiceConfig,
  identity: IdentityResolver | undefined,
  traceId: string
): Promise<ResolvedCaller | null> {
  try {
    return await (identity ?? identityResolverFor(config)).resolve(req);
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
