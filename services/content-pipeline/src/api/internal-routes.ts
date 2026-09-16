import type { IncomingMessage, ServerResponse } from 'node:http';

import type { ServiceConfig } from '../config.js';
import { ACCOUNT_ID_PATTERN, type IdentityResolver } from '../auth/identity.js';
import type { JobStore } from '../jobs/job-store.js';
import type { Logger } from '../observability/logger.js';
import type { KeyLayout } from '../storage/keys.js';
import type { ObjectStore } from '../storage/object-store.js';
import { identityResolverFor } from './auth.js';
import { attachRequestContext, parseUrl, sendError, sendJson } from './http-utils.js';

const PURGE_RE = /^\/internal\/v1\/accounts\/([^/]+)\/purge$/;

export interface OwnerActivity {
  readonly currentOwnerScope: string | null;
  abortCurrent?(): void;
}

export interface InternalRouteDeps {
  config: ServiceConfig;
  store: JobStore;
  objects: ObjectStore;
  keys: KeyLayout;
  logger: Logger;
  identity?: IdentityResolver;
  worker?: OwnerActivity;
  workers?: OwnerActivity[];
  mediaRunner?: OwnerActivity;
}

/**
 * Internal routes (never publicly proxied). Account purge is idempotent:
 * 202 while the account still has executing work, 200 {status:"done"} once
 * rows and every object under the account prefix are gone.
 */
export async function handleInternalRoutes(
  req: IncomingMessage,
  res: ServerResponse,
  deps: InternalRouteDeps
): Promise<boolean> {
  const path = parseUrl(req).pathname;
  if (!path.startsWith('/internal/')) return false;
  const { traceId } = attachRequestContext(res);

  const caller = (deps.identity ?? identityResolverFor(deps.config)).internalCaller(req);
  const match = PURGE_RE.exec(path);
  if (caller !== 'account-service') {
    sendError(res, 401, { code: 'AUTH_REQUIRED', message: 'internal service credential required', retryable: false }, traceId);
    return true;
  }
  if (!match || req.method !== 'POST') {
    sendError(res, 404, { code: 'NOT_FOUND', message: `No route for ${req.method} ${path}`, retryable: false }, traceId);
    return true;
  }
  const accountId = decodeURIComponent(match[1]!);
  if (!ACCOUNT_ID_PATTERN.test(accountId)) {
    sendError(res, 400, { code: 'INVALID_REQUEST', message: 'accountId must be an acc_ identifier', retryable: false, params: { field: 'accountId' } }, traceId);
    return true;
  }

  const cancelled = deps.store.cancelActiveJobsForOwner(accountId);
  const busy = [deps.worker, deps.mediaRunner, ...(deps.workers ?? [])].filter(
    (activity) => activity?.currentOwnerScope === accountId
  );
  if (busy.length > 0) {
    for (const activity of busy) activity?.abortCurrent?.();
    sendJson(res, 202, { status: 'in_progress', cancelledJobs: cancelled.length });
    return true;
  }

  const { objectKeys, jobIds } = deps.store.purgeOwnerRows(accountId);
  const prefix = deps.keys.accountPrefix(accountId);
  const listed = await deps.objects.listKeys(prefix);
  const keys = [...new Set([...objectKeys.filter((key) => key.startsWith(prefix)), ...listed])];
  for (const key of keys) await deps.objects.delete(key);
  deps.logger.info('account content purged', { jobs: jobIds.length, objects: keys.length });
  sendJson(res, 200, { status: 'done', cancelledJobs: cancelled.length, deletedJobs: jobIds.length, deletedObjects: keys.length });
  return true;
}
