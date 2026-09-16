import type { IncomingMessage, ServerResponse } from 'node:http';

import { PLATFORMS, accountSummary, type AuthService, type Platform, type RequestIdentity } from '../auth/auth-service.js';
import type { InternalServiceName, ServiceConfig } from '../config.js';
import { constantTimeEqual } from '../crypto/tokens.js';
import { AccountError, invalidRequest } from '../domain/errors.js';
import { ACCOUNT_ID_PATTERN, CHALLENGE_ID_PATTERN } from '../domain/ids.js';
import type { AccountStore } from '../store/account-store.js';
import {
  QUOTA_KINDS,
  SETTLE_REASONS,
  projectReservation,
  type QuotaKind,
  type QuotaLimits,
  type QuotaStore,
  type SettleReason
} from '../quota/quota-store.js';
import type { FixedWindowRateLimiter } from './rate-limit.js';
import {
  ACCOUNT_CONTEXT_HEADER,
  bearerToken,
  clientAddress,
  parseUrl,
  readJsonObject,
  sendJson,
  sendNoContent
} from './http-utils.js';

export const SERVICE_VERSION = '0.1.0';

export interface RouteDeps {
  config: ServiceConfig;
  store: AccountStore;
  auth: AuthService;
  quota: QuotaStore;
  authRateLimiter: FixedWindowRateLimiter;
  now: () => number;
}

const RESERVATION_RE = /^\/internal\/v1\/quota\/reservations\/(qr_[0-9A-HJKMNP-TV-Z]{26})$/;
const SETTLE_RE = /^\/internal\/v1\/quota\/reservations\/(qr_[0-9A-HJKMNP-TV-Z]{26})\/settle$/;
const OPERATION_KEY = /^[A-Za-z0-9:._#-]{1,200}$/;

export function quotaLimits(config: ServiceConfig): QuotaLimits {
  return { enforced: config.quotaEnforced, ...config.quotaLimits };
}

interface FieldRule {
  min?: number;
  max: number;
  pattern?: RegExp;
}

function requiredString(body: Record<string, unknown>, field: string, rule: FieldRule): string {
  const value = body[field];
  if (typeof value !== 'string') throw invalidRequest(field, 'must be a string');
  return checkString(value, field, rule);
}

function optionalString(body: Record<string, unknown>, field: string, rule: FieldRule): string | null {
  const value = body[field];
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') throw invalidRequest(field, 'must be a string');
  return checkString(value, field, rule);
}

function checkString(value: string, field: string, rule: FieldRule): string {
  if (value.length < (rule.min ?? 1) || value.length > rule.max) throw invalidRequest(field, 'has an invalid length');
  if (rule.pattern && !rule.pattern.test(value)) throw invalidRequest(field, 'has an invalid format');
  return value;
}

function rejectUnknownFields(body: Record<string, unknown>, allowed: readonly string[]): void {
  const unknown = Object.keys(body).find((key) => !allowed.includes(key));
  if (unknown !== undefined) throw invalidRequest(unknown, 'is not allowed');
}

function platformField(body: Record<string, unknown>): Platform {
  const value = body.platform;
  if (typeof value !== 'string' || !PLATFORMS.includes(value as Platform)) {
    throw invalidRequest('platform', `must be one of ${PLATFORMS.join('|')}`);
  }
  return value as Platform;
}

function rateLimit(req: IncomingMessage, deps: RouteDeps): void {
  const retryAfter = deps.authRateLimiter.hit(clientAddress(req, deps.config.trustProxy));
  if (retryAfter > 0) {
    throw new AccountError(429, 'RATE_LIMITED', 'too many authentication requests', true, undefined, retryAfter);
  }
}

function internalCaller(req: IncomingMessage, config: ServiceConfig): InternalServiceName {
  const token = bearerToken(req);
  const match = token === null ? undefined : config.internalTokens.find((entry) => constantTimeEqual(token, entry.token));
  if (!match) throw new AccountError(401, 'AUTH_REQUIRED', 'internal service credential required');
  return match.service;
}

function authenticatePublic(req: IncomingMessage, deps: RouteDeps): RequestIdentity {
  return deps.auth.authenticate(bearerToken(req));
}

function meConfig(identity: RequestIdentity, deps: RouteDeps): Record<string, unknown> {
  const { config } = deps;
  return {
    schemaVersion: 1,
    account: accountSummary(deps.auth.account(identity)),
    services: {
      accountBaseUrl: config.publicUrls.account,
      contentBaseUrl: config.publicUrls.content,
      assistantBaseUrl: config.publicUrls.assistant,
      mediaBaseUrl: config.publicUrls.media
    },
    capabilities: {
      contentJobs: true,
      assistantV2: true,
      videoMedia: config.videoMediaEnabled,
      quota: config.quotaEnforced,
      accountDeletion: config.authMode === 'apple'
    },
    limits: { maxMediaDurationSeconds: config.maxMediaDurationSeconds }
  };
}

/** Returns true when the request was handled. Throws AccountError for contract errors. */
export async function handleRoutes(req: IncomingMessage, res: ServerResponse, deps: RouteDeps): Promise<boolean> {
  const path = parseUrl(req).pathname;
  const method = req.method ?? 'GET';

  if (path === '/v1/account-health/live' && method === 'GET') {
    sendJson(res, 200, { status: 'ok', version: SERVICE_VERSION });
    return true;
  }
  if (path === '/v1/account-health/ready' && method === 'GET') {
    try {
      deps.store.ping();
      sendJson(res, 200, { status: 'ok', version: SERVICE_VERSION, checks: { database: 'ok', authMode: deps.config.authMode } });
    } catch {
      sendJson(res, 503, { status: 'unavailable', version: SERVICE_VERSION, checks: { database: 'failed' } });
    }
    return true;
  }

  if (path.startsWith('/internal/')) {
    const caller = internalCaller(req, deps.config);
    if (path === '/internal/v1/quota/reservations' && method === 'POST') {
      const body = await readJsonObject(req, deps.config.maxBodyBytes);
      rejectUnknownFields(body, ['accountId', 'kind', 'operationKey', 'amount', 'service', 'subjectRef']);
      const accountId = requiredString(body, 'accountId', { max: 40, pattern: ACCOUNT_ID_PATTERN });
      const kind = requiredString(body, 'kind', { max: 16 }) as QuotaKind;
      if (!QUOTA_KINDS.includes(kind)) throw invalidRequest('kind', `must be one of ${QUOTA_KINDS.join('|')}`);
      const operationKey = requiredString(body, 'operationKey', { max: 200, pattern: OPERATION_KEY });
      const amount = body.amount;
      if (typeof amount !== 'number' || !Number.isInteger(amount) || amount < 1 || amount > 24 * 3600) {
        throw invalidRequest('amount', 'must be a positive integer');
      }
      const service = requiredString(body, 'service', { max: 40 });
      if (service !== caller) throw new AccountError(403, 'FORBIDDEN', 'service must match the calling credential');
      const subjectRef = optionalString(body, 'subjectRef', { max: 200 });
      const { created, reservation } = deps.quota.reserve(
        { accountId, kind, operationKey, amount, service, subjectRef },
        quotaLimits(deps.config),
        deps.now()
      );
      sendJson(res, created ? 201 : 200, projectReservation(reservation));
      return true;
    }
    const reservationMatch = RESERVATION_RE.exec(path);
    if (reservationMatch && method === 'GET') {
      const reservation = deps.quota.get(reservationMatch[1]!);
      if (!reservation) throw new AccountError(404, 'RESERVATION_NOT_FOUND', 'reservation is unknown');
      sendJson(res, 200, projectReservation(reservation));
      return true;
    }
    const settleMatch = SETTLE_RE.exec(path);
    if (settleMatch && method === 'POST') {
      const body = await readJsonObject(req, deps.config.maxBodyBytes);
      rejectUnknownFields(body, ['outcome', 'reason']);
      const outcome = requiredString(body, 'outcome', { max: 16 });
      if (outcome !== 'consumed' && outcome !== 'released') throw invalidRequest('outcome', 'must be consumed or released');
      const reason = requiredString(body, 'reason', { max: 40 }) as SettleReason;
      if (!SETTLE_REASONS.includes(reason)) throw invalidRequest('reason', 'is not a known settlement reason');
      sendJson(res, 200, projectReservation(deps.quota.settle(settleMatch[1]!, outcome, reason, deps.now())));
      return true;
    }
    if (path === '/internal/v1/auth/introspect' && method === 'POST') {
      const body = await readJsonObject(req, deps.config.maxBodyBytes);
      rejectUnknownFields(body, ['token']);
      const token = requiredString(body, 'token', { min: 8, max: 256 });
      sendJson(res, 200, deps.auth.introspect(token));
      return true;
    }
    return false;
  }

  if (req.headers[ACCOUNT_CONTEXT_HEADER] !== undefined) {
    throw invalidRequest(ACCOUNT_CONTEXT_HEADER, 'is not accepted on public routes');
  }

  if (path === '/v1/auth/apple/challenge' && method === 'POST') {
    rateLimit(req, deps);
    const body = await readJsonObject(req, deps.config.maxBodyBytes);
    rejectUnknownFields(body, ['platform', 'clientVersion']);
    optionalString(body, 'clientVersion', { max: 32 });
    sendJson(res, 201, deps.auth.createChallenge(platformField(body)));
    return true;
  }

  if (path === '/v1/auth/apple/exchange' && method === 'POST') {
    rateLimit(req, deps);
    const body = await readJsonObject(req, deps.config.maxBodyBytes);
    rejectUnknownFields(body, ['challengeId', 'identityToken', 'authorizationCode', 'platform', 'deviceName', 'clientVersion']);
    const input = {
      challengeId: requiredString(body, 'challengeId', { max: 30, pattern: CHALLENGE_ID_PATTERN }),
      identityToken: requiredString(body, 'identityToken', { min: 16, max: 8192 }),
      authorizationCode: requiredString(body, 'authorizationCode', { max: 1024 }),
      platform: platformField(body),
      deviceName: optionalString(body, 'deviceName', { max: 80 })
    };
    optionalString(body, 'clientVersion', { max: 32 });
    sendJson(res, 200, await deps.auth.exchange(input));
    return true;
  }

  if (path === '/v1/auth/refresh' && method === 'POST') {
    rateLimit(req, deps);
    const body = await readJsonObject(req, deps.config.maxBodyBytes);
    rejectUnknownFields(body, ['refreshToken']);
    sendJson(res, 200, deps.auth.refresh(requiredString(body, 'refreshToken', { min: 16, max: 256 })));
    return true;
  }

  if (path === '/v1/auth/logout' && method === 'POST') {
    deps.auth.logout(authenticatePublic(req, deps));
    sendNoContent(res);
    return true;
  }

  if (path === '/v1/me/quota' && method === 'GET') {
    const identity = authenticatePublic(req, deps);
    sendJson(res, 200, deps.quota.snapshot(identity.accountId, quotaLimits(deps.config), deps.now()));
    return true;
  }

  if (path === '/v1/me/config' && method === 'GET') {
    sendJson(res, 200, meConfig(authenticatePublic(req, deps), deps));
    return true;
  }

  if (path === '/v1/me' && method === 'DELETE') {
    const identity = authenticatePublic(req, deps);
    sendJson(res, 202, deps.auth.requestDeletion(identity));
    return true;
  }

  return false;
}
