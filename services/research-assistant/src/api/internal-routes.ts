import { rmSync } from 'node:fs';
import type { IncomingMessage, ServerResponse } from 'node:http';

import { ACCOUNT_ID_PATTERN, type IdentityResolver } from '../auth/identity.js';
import type { ServiceConfig } from '../config/index.js';
import type { V2Store } from '../db/v2/store.js';
import type { Logger } from '../observability/logger.js';
import type { V2ResearchOrchestrator } from '../research-v2/orchestrator.js';
import { parseUrl, sendError, sendJson } from './http-utils.js';
import { identityResolverFor } from './identity-gate.js';

const PURGE_RE = /^\/internal\/v1\/accounts\/([^/]+)\/purge$/;

export interface InternalRouteDeps {
  config: ServiceConfig;
  logger: Logger;
  identity?: IdentityResolver;
  v2: { store: V2Store; orchestrator: V2ResearchOrchestrator } | null;
}

/**
 * Internal routes (never publicly proxied). Account purge is idempotent:
 * running turns are cancelled and reported as 202 until no turn of the
 * account still executes; then workspaces, rows and the account's global
 * memory directory are removed and 200 {status:"done"} is returned.
 */
export async function handleInternalRoutes(
  req: IncomingMessage,
  res: ServerResponse,
  deps: InternalRouteDeps,
  traceId: string
): Promise<boolean> {
  const path = parseUrl(req).pathname;
  if (!path.startsWith('/internal/')) return false;

  const caller = (deps.identity ?? identityResolverFor(deps.config)).internalCaller(req);
  if (caller !== 'account-service') {
    sendError(res, 401, { code: 'AUTH_REQUIRED', message: 'internal service credential required', retryable: false }, traceId);
    return true;
  }
  const match = PURGE_RE.exec(path);
  if (!match || req.method !== 'POST') {
    sendError(res, 404, { code: 'NOT_FOUND', message: `No route for ${req.method} ${path}`, retryable: false }, traceId);
    return true;
  }
  const accountId = decodeURIComponent(match[1]!);
  if (!ACCOUNT_ID_PATTERN.test(accountId)) {
    sendError(
      res,
      400,
      { code: 'INVALID_REQUEST', message: 'accountId must be an acc_ identifier', retryable: false, params: { field: 'accountId' } },
      traceId
    );
    return true;
  }
  if (!deps.v2) {
    sendJson(res, 200, { status: 'done', deletedResearches: 0 });
    return true;
  }

  const { store, orchestrator } = deps.v2;
  const researchIds = store.researchIdsForOwner(accountId);
  let executing = 0;
  for (const researchId of researchIds) {
    const active = store.activeTurn(researchId);
    if (active) orchestrator.cancelTurn(active.turnId);
    executing += store.listTurns(researchId).filter((turn) => orchestrator.isTurnExecuting(turn.turnId)).length;
  }
  if (executing > 0) {
    sendJson(res, 202, { status: 'in_progress', executingTurns: executing });
    return true;
  }

  for (const researchId of researchIds) orchestrator.deleteResearch(researchId);
  const deleted = store.purgeOwnerRows(accountId);
  rmSync(orchestrator.globalMemory.rootFor(accountId), { recursive: true, force: true });
  deps.logger.info('account assistant data purged', { researches: String(deleted) });
  sendJson(res, 200, { status: 'done', deletedResearches: deleted });
  return true;
}
