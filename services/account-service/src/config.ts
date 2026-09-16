import { createPrivateKey } from 'node:crypto';
import { readFileSync } from 'node:fs';

/**
 * Environment-driven configuration with strict startup validation.
 *  - bind host defaults to 127.0.0.1; 0.0.0.0 requires ACCOUNT_BIND_ALL_INTERFACES=1
 *  - AUTH_MODE is explicit: apple (official / self-host with own Apple keys) or
 *    selfhost (single fixed account, deployment token)
 *  - validation errors name the offending VARIABLE, never its value
 */

export type AuthMode = 'apple' | 'selfhost';
export type InternalServiceName = 'content-pipeline' | 'research-assistant' | 'media-service';
export const INTERNAL_SERVICE_NAMES: readonly InternalServiceName[] = [
  'content-pipeline',
  'research-assistant',
  'media-service'
];

export interface AppleConfig {
  teamId: string;
  keyId: string;
  privateKeyPem: string;
  clientIds: string[];
  baseUrl: string;
  issuer: string;
  tokenEncryptionKey: Buffer;
}

export interface InternalToken {
  service: InternalServiceName;
  token: string;
}

export interface PurgeTarget {
  name: string;
  baseUrl: string;
}

export interface ServiceConfig {
  host: string;
  port: number;
  databasePath: string;
  maxBodyBytes: number;
  authMode: AuthMode;
  selfhostAccessToken: string | null;
  internalTokens: InternalToken[];
  apple: AppleConfig | null;
  challengeTtlSeconds: number;
  accessTokenTtlSeconds: number;
  sessionMaxAgeSeconds: number;
  refreshGraceSeconds: number;
  publicUrls: {
    account: string;
    content: string;
    assistant: string;
    media: string | null;
  };
  videoMediaEnabled: boolean;
  quotaEnforced: boolean;
  quotaLimits: {
    mediaSecondsPerDay: number;
    assistantTurnsPerDay: number;
    mediaConcurrency: number;
    assistantConcurrency: number;
  };
  maxMediaDurationSeconds: number;
  purgeTargets: PurgeTarget[];
  purgeToken: string | null;
  deletionIntervalMs: number;
  authRateLimitPerMinute: number;
  trustProxy: boolean;
  allowInsecureUpstream: boolean;
}

export class ConfigError extends Error {
  readonly variable: string;
  constructor(variable: string, reason: string) {
    super(`Invalid configuration for ${variable}: ${reason}`);
    this.name = 'ConfigError';
    this.variable = variable;
  }
}

export const LOOPBACK_HOST = '127.0.0.1';
export const CONTAINER_BIND_HOST = '0.0.0.0';
export const DEFAULT_PORT = 3240;
const SERVICE_TOKEN_MIN_LENGTH = 32;
const APPLE_ISSUER = 'https://appleid.apple.com';

function optionalVar(env: NodeJS.ProcessEnv, name: string): string | null {
  const value = env[name]?.trim();
  return value ? value : null;
}

function requiredVar(env: NodeJS.ProcessEnv, name: string): string {
  const value = optionalVar(env, name);
  if (value === null) throw new ConfigError(name, 'required variable is missing or empty');
  return value;
}

function requiredSecret(env: NodeJS.ProcessEnv, name: string, minLength = SERVICE_TOKEN_MIN_LENGTH): string {
  const value = requiredVar(env, name);
  if (value.length < minLength) throw new ConfigError(name, `must be at least ${minLength} characters`);
  return value;
}

function integerVar(env: NodeJS.ProcessEnv, name: string, fallback: number, min: number, max: number): number {
  const raw = optionalVar(env, name);
  if (raw === null) return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new ConfigError(name, `must be an integer between ${min} and ${max}`);
  }
  return value;
}

function booleanVar(env: NodeJS.ProcessEnv, name: string, fallback: boolean): boolean {
  const raw = optionalVar(env, name)?.toLowerCase();
  if (raw === undefined || raw === null) return fallback;
  if (raw === '1' || raw === 'true' || raw === 'yes') return true;
  if (raw === '0' || raw === 'false' || raw === 'no') return false;
  throw new ConfigError(name, 'must be true or false');
}

function urlVar(env: NodeJS.ProcessEnv, name: string, allowInsecure: boolean, fallback?: string): string {
  const value = optionalVar(env, name) ?? fallback;
  if (value === undefined) throw new ConfigError(name, 'required variable is missing or empty');
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new ConfigError(name, 'must be a valid URL');
  }
  if (url.protocol === 'https:' || (url.protocol === 'http:' && allowInsecure)) {
    return value.replace(/\/+$/, '');
  }
  throw new ConfigError(name, allowInsecure ? 'must use http or https' : 'must use https');
}

function parseInternalTokens(raw: string): InternalToken[] {
  const entries = raw.split(',').map((entry) => entry.trim()).filter(Boolean);
  if (entries.length === 0) throw new ConfigError('ACCOUNT_INTERNAL_TOKENS', 'must list at least one service:token');
  const seen = new Set<string>();
  return entries.map((entry) => {
    const separator = entry.indexOf(':');
    const service = separator > 0 ? entry.slice(0, separator) : '';
    const token = separator > 0 ? entry.slice(separator + 1) : '';
    if (!INTERNAL_SERVICE_NAMES.includes(service as InternalServiceName)) {
      throw new ConfigError('ACCOUNT_INTERNAL_TOKENS', `service must be one of ${INTERNAL_SERVICE_NAMES.join('|')}`);
    }
    if (token.length < SERVICE_TOKEN_MIN_LENGTH) {
      throw new ConfigError('ACCOUNT_INTERNAL_TOKENS', `each token must be at least ${SERVICE_TOKEN_MIN_LENGTH} characters`);
    }
    if (seen.has(service)) throw new ConfigError('ACCOUNT_INTERNAL_TOKENS', 'each service may appear once');
    seen.add(service);
    return { service: service as InternalServiceName, token };
  });
}

function parsePurgeTargets(raw: string | null, allowInsecure: boolean): PurgeTarget[] {
  if (raw === null) return [];
  return raw
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => {
      const separator = entry.indexOf('=');
      const name = separator > 0 ? entry.slice(0, separator) : '';
      if (!/^[a-z][a-z0-9-]{1,40}$/.test(name)) {
        throw new ConfigError('ACCOUNT_PURGE_TARGETS', 'entries must be name=url with a lowercase name');
      }
      const baseUrl = urlVar({ ACCOUNT_PURGE_TARGETS: entry.slice(separator + 1) }, 'ACCOUNT_PURGE_TARGETS', allowInsecure);
      return { name, baseUrl };
    });
}

function loadApplePrivateKey(env: NodeJS.ProcessEnv): string {
  const path = optionalVar(env, 'APPLE_PRIVATE_KEY_PATH');
  let pem: string;
  if (path !== null) {
    try {
      pem = readFileSync(path, 'utf8');
    } catch {
      throw new ConfigError('APPLE_PRIVATE_KEY_PATH', 'file is not readable');
    }
  } else {
    pem = requiredVar(env, 'APPLE_PRIVATE_KEY').replace(/\\n/g, '\n');
  }
  const variable = path !== null ? 'APPLE_PRIVATE_KEY_PATH' : 'APPLE_PRIVATE_KEY';
  try {
    const key = createPrivateKey(pem);
    if (key.asymmetricKeyType !== 'ec') throw new Error('not ec');
  } catch {
    throw new ConfigError(variable, 'must be a PKCS#8 EC (P-256) private key');
  }
  return pem;
}

function loadAppleConfig(env: NodeJS.ProcessEnv, allowInsecure: boolean): AppleConfig {
  const clientIds = requiredVar(env, 'APPLE_CLIENT_IDS')
    .split(',')
    .map((id) => id.trim())
    .filter(Boolean);
  if (clientIds.length === 0 || clientIds.some((id) => !/^[A-Za-z0-9.-]+$/.test(id))) {
    throw new ConfigError('APPLE_CLIENT_IDS', 'must be a comma-separated list of bundle or service IDs');
  }
  const keyRaw = requiredVar(env, 'APPLE_TOKEN_ENCRYPTION_KEY');
  const tokenEncryptionKey = Buffer.from(keyRaw, 'base64');
  if (tokenEncryptionKey.length !== 32) {
    throw new ConfigError('APPLE_TOKEN_ENCRYPTION_KEY', 'must be 32 bytes encoded as base64');
  }
  const teamId = requiredVar(env, 'APPLE_TEAM_ID');
  const keyId = requiredVar(env, 'APPLE_KEY_ID');
  if (!/^[A-Z0-9]{10}$/.test(teamId)) throw new ConfigError('APPLE_TEAM_ID', 'must be a 10-character team identifier');
  if (!/^[A-Z0-9]{10}$/.test(keyId)) throw new ConfigError('APPLE_KEY_ID', 'must be a 10-character key identifier');
  const baseUrl = urlVar(env, 'APPLE_BASE_URL', allowInsecure, APPLE_ISSUER);
  return {
    teamId,
    keyId,
    privateKeyPem: loadApplePrivateKey(env),
    clientIds,
    baseUrl,
    issuer: optionalVar(env, 'APPLE_ISSUER') ?? APPLE_ISSUER,
    tokenEncryptionKey
  };
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ServiceConfig {
  const host = optionalVar(env, 'ACCOUNT_HOST') ?? LOOPBACK_HOST;
  if (host !== LOOPBACK_HOST) {
    const containerBindOk = host === CONTAINER_BIND_HOST && env.ACCOUNT_BIND_ALL_INTERFACES === '1';
    if (!containerBindOk) {
      throw new ConfigError(
        'ACCOUNT_HOST',
        'service must bind to 127.0.0.1; 0.0.0.0 requires ACCOUNT_BIND_ALL_INTERFACES=1 inside a private container network'
      );
    }
  }
  const allowInsecure = env.ACCOUNT_ALLOW_INSECURE_UPSTREAM === '1' || env.NODE_ENV === 'test';

  const authModeRaw = requiredVar(env, 'AUTH_MODE').toLowerCase();
  if (authModeRaw !== 'apple' && authModeRaw !== 'selfhost') {
    throw new ConfigError('AUTH_MODE', 'must be apple or selfhost');
  }
  const authMode: AuthMode = authModeRaw;

  const purgeTargets = parsePurgeTargets(optionalVar(env, 'ACCOUNT_PURGE_TARGETS'), allowInsecure);

  return {
    host,
    port: integerVar(env, 'ACCOUNT_PORT', DEFAULT_PORT, 1, 65535),
    databasePath: optionalVar(env, 'ACCOUNT_DATABASE_PATH') ?? '/var/lib/linguacast-account/data/account.db',
    maxBodyBytes: integerVar(env, 'ACCOUNT_MAX_BODY_BYTES', 64 * 1024, 16 * 1024, 1024 * 1024),
    authMode,
    selfhostAccessToken: authMode === 'selfhost' ? requiredSecret(env, 'SELFHOST_ACCESS_TOKEN') : null,
    internalTokens: parseInternalTokens(requiredVar(env, 'ACCOUNT_INTERNAL_TOKENS')),
    apple: authMode === 'apple' ? loadAppleConfig(env, allowInsecure) : null,
    challengeTtlSeconds: integerVar(env, 'ACCOUNT_CHALLENGE_TTL_SECONDS', 300, 60, 900),
    accessTokenTtlSeconds: integerVar(env, 'ACCOUNT_ACCESS_TOKEN_TTL_SECONDS', 900, 60, 3600),
    sessionMaxAgeSeconds: integerVar(env, 'ACCOUNT_SESSION_MAX_AGE_SECONDS', 30 * 24 * 3600, 3600, 90 * 24 * 3600),
    refreshGraceSeconds: integerVar(env, 'ACCOUNT_REFRESH_GRACE_SECONDS', 30, 0, 120),
    publicUrls: {
      account: urlVar(env, 'PUBLIC_ACCOUNT_BASE_URL', allowInsecure),
      content: urlVar(env, 'PUBLIC_CONTENT_BASE_URL', allowInsecure),
      assistant: urlVar(env, 'PUBLIC_ASSISTANT_BASE_URL', allowInsecure),
      media: optionalVar(env, 'PUBLIC_MEDIA_BASE_URL') ? urlVar(env, 'PUBLIC_MEDIA_BASE_URL', allowInsecure) : null
    },
    videoMediaEnabled: booleanVar(env, 'CAPABILITY_VIDEO_MEDIA', false),
    quotaEnforced: booleanVar(env, 'QUOTA_ENFORCED', authMode === 'apple'),
    quotaLimits: {
      mediaSecondsPerDay: integerVar(env, 'QUOTA_MEDIA_SECONDS_PER_DAY', 1800, 0, 24 * 3600),
      assistantTurnsPerDay: integerVar(env, 'QUOTA_ASSISTANT_TURNS_PER_DAY', 20, 0, 10_000),
      mediaConcurrency: integerVar(env, 'QUOTA_MEDIA_CONCURRENCY', 1, 1, 32),
      assistantConcurrency: integerVar(env, 'QUOTA_ASSISTANT_CONCURRENCY', 1, 1, 32)
    },
    maxMediaDurationSeconds: integerVar(env, 'CONTENT_MAX_MEDIA_DURATION_SECONDS', 4 * 3600, 60, 12 * 3600),
    purgeTargets,
    purgeToken: purgeTargets.length > 0 ? requiredSecret(env, 'ACCOUNT_PURGE_TOKEN') : null,
    deletionIntervalMs: integerVar(env, 'ACCOUNT_DELETION_INTERVAL_SECONDS', 30, 5, 3600) * 1000,
    authRateLimitPerMinute: integerVar(env, 'ACCOUNT_AUTH_RATE_LIMIT_PER_MINUTE', 60, 1, 10_000),
    trustProxy: env.ACCOUNT_TRUST_PROXY === '1',
    allowInsecureUpstream: allowInsecure
  };
}

/** Register every secret with the redacting logger (values, never names). */
export function registerConfigSecrets(config: ServiceConfig, register: (value: string) => void): void {
  if (config.selfhostAccessToken) register(config.selfhostAccessToken);
  for (const entry of config.internalTokens) register(entry.token);
  if (config.purgeToken) register(config.purgeToken);
  if (config.apple) {
    register(config.apple.privateKeyPem);
    register(config.apple.tokenEncryptionKey.toString('base64'));
  }
}
