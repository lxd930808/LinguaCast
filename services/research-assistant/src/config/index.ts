import { homedir } from 'node:os';
import { join } from 'node:path';

export class ConfigError extends Error {
  readonly variable: string;
  constructor(variable: string, reason: string) {
    super(`Invalid configuration for ${variable}: ${reason}`);
    this.name = 'ConfigError';
    this.variable = variable;
  }
}

export interface InternalCallerConfig {
  name: 'account-service';
  token: string;
}

/** V18 identity: explicit selfhost deployment token, or account-service introspection. */
export interface IdentityConfig {
  mode: 'selfhost' | 'account';
  accountServiceUrl: string | null;
  introspectionToken: string | null;
  internalCallers: InternalCallerConfig[];
  contextSigningKey: string | null;
}

export interface ServiceConfig {
  host: string;
  port: number;
  /** Selfhost deployment token; empty in account mode. */
  serviceToken: string;
  identity: IdentityConfig;
  /** V18 WP04: daily assistant turn quota (account mode). */
  quotaEnabled: boolean;
  /** Running turns per account; `globalPiTurns` caps the whole process. */
  accountTurnConcurrency: number;
  v10: { baseUrl: string; token: string; pipelineVersion: string };
  youtubeApiKey: string;
  youtubeApiBaseUrl: string;
  appleSearchBaseUrl: string;
  appleSearchCountry: string;
  piConfigDir: string;
  piAuthPath: string;
  ytdlpPath: string;
  databasePath: string;
  tempRoot: string;
  maxBodyBytes: number;
  ytdlpTimeoutMs: number;
  ytdlpStdoutMaxBytes: number;
  ytdlpStderrMaxBytes: number;
  searchLimit: number;
  globalPiTurns: number;
  globalYtdlp: number;
  allowInsecureUpstream: boolean;
  systemPromptPath: string;
  searchV2: boolean;
  podcastIndexEnabled: boolean;
  youtubeHydrationEnabled: boolean;
  podcastIndexApiKey: string;
  podcastIndexApiSecret: string;
  podcastIndexBaseUrl: string;
  podcastIndexTimeoutMs: number;
  searchSuccessTtlSeconds: number;
  searchEmptyTtlSeconds: number;
  workspaceRoot: string;
  globalMemoryRoot: string;
  sharedGrantsPath: string;
  sharedVersionRoot: string;
  sharedWriteEnabled: boolean;
  rgPath: string;
  maxGrepMatches: number;
  maxGrepMs: number;
  assistantWebEnabled: boolean;
  webProvider: string;
  webApiKey: string;
  maxWebPageBytes: number;
}

const REQUIRED_SECRET_MIN_LENGTH = 8;
const INTERNAL_SECRET_MIN_LENGTH = 32;

function internalUrl(env: NodeJS.ProcessEnv, name: string): string {
  const value = requiredVar(env, name).trim();
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new ConfigError(name, 'must be a valid URL');
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new ConfigError(name, 'must use http or https');
  return value.replace(/\/+$/, '');
}

function loadIdentity(env: NodeJS.ProcessEnv): { identity: IdentityConfig; serviceToken: string } {
  const mode = requiredVar(env, 'ASSISTANT_IDENTITY_MODE').trim().toLowerCase();
  if (mode !== 'selfhost' && mode !== 'account') throw new ConfigError('ASSISTANT_IDENTITY_MODE', 'must be selfhost or account');
  const signingKey = env.ACCOUNT_CONTEXT_SIGNING_KEY?.trim() || null;
  if (signingKey !== null && signingKey.length < INTERNAL_SECRET_MIN_LENGTH) {
    throw new ConfigError('ACCOUNT_CONTEXT_SIGNING_KEY', `must be at least ${INTERNAL_SECRET_MIN_LENGTH} characters`);
  }
  const internalCallers = (env.ASSISTANT_INTERNAL_CALLERS ?? '')
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry): InternalCallerConfig => {
      const separator = entry.indexOf(':');
      const name = separator > 0 ? entry.slice(0, separator) : '';
      const token = separator > 0 ? entry.slice(separator + 1) : '';
      if (name !== 'account-service') throw new ConfigError('ASSISTANT_INTERNAL_CALLERS', 'caller must be account-service');
      if (token.length < INTERNAL_SECRET_MIN_LENGTH) {
        throw new ConfigError('ASSISTANT_INTERNAL_CALLERS', `each token must be at least ${INTERNAL_SECRET_MIN_LENGTH} characters`);
      }
      return { name, token };
    });
  if (internalCallers.length > 1) throw new ConfigError('ASSISTANT_INTERNAL_CALLERS', 'each caller may appear once');
  if (mode === 'selfhost') {
    return {
      serviceToken: requiredSecret(env, 'ASSISTANT_SERVICE_TOKEN'),
      identity: { mode, accountServiceUrl: null, introspectionToken: null, internalCallers, contextSigningKey: signingKey }
    };
  }
  if (signingKey === null) throw new ConfigError('ACCOUNT_CONTEXT_SIGNING_KEY', 'required variable is missing or empty');
  const introspectionToken = requiredVar(env, 'ASSISTANT_ACCOUNT_TOKEN');
  if (introspectionToken.length < INTERNAL_SECRET_MIN_LENGTH) {
    throw new ConfigError('ASSISTANT_ACCOUNT_TOKEN', `must be at least ${INTERNAL_SECRET_MIN_LENGTH} characters`);
  }
  return {
    serviceToken: '',
    identity: {
      mode,
      accountServiceUrl: internalUrl(env, 'ACCOUNT_SERVICE_URL'),
      introspectionToken,
      internalCallers,
      contextSigningKey: signingKey
    }
  };
}
export const LOOPBACK_HOST = '127.0.0.1';
export const CONTAINER_BIND_HOST = '0.0.0.0';
export const DEFAULT_PORT = 3230;

function requiredVar(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (value === undefined || value.trim() === '') {
    throw new ConfigError(name, 'required variable is missing or empty');
  }
  return value;
}

function requiredSecret(env: NodeJS.ProcessEnv, name: string): string {
  const value = requiredVar(env, name);
  if (value.length < REQUIRED_SECRET_MIN_LENGTH) {
    throw new ConfigError(name, `must be at least ${REQUIRED_SECRET_MIN_LENGTH} characters`);
  }
  return value;
}

function integerVar(
  env: NodeJS.ProcessEnv,
  name: string,
  fallback: number,
  min: number,
  max: number
): number {
  const raw = env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new ConfigError(name, `must be an integer between ${min} and ${max}`);
  }
  return value;
}

function httpsUrl(env: NodeJS.ProcessEnv, name: string, fallback: string, allowInsecure: boolean): string {
  const value = env[name] ?? fallback;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new ConfigError(name, 'must be a valid URL');
  }
  if (url.protocol === 'https:') return value.replace(/\/+$/, '');
  if (url.protocol === 'http:' && allowInsecure) return value.replace(/\/+$/, '');
  throw new ConfigError(name, allowInsecure ? 'must use http or https' : 'must use https');
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ServiceConfig {
  const host = env.ASSISTANT_HOST ?? LOOPBACK_HOST;
  if (host !== LOOPBACK_HOST) {
    const containerBindOk = host === CONTAINER_BIND_HOST && env.ASSISTANT_BIND_ALL_INTERFACES === '1';
    if (!containerBindOk) {
      throw new ConfigError(
        'ASSISTANT_HOST',
        'service must bind to 127.0.0.1; 0.0.0.0 requires ASSISTANT_BIND_ALL_INTERFACES=1 with a loopback-only port publish'
      );
    }
  }

  const allowInsecure =
    env.ASSISTANT_ALLOW_INSECURE_UPSTREAM === '1' || env.NODE_ENV === 'test';

  const { identity, serviceToken } = loadIdentity(env);
  const quotaRaw = env.ASSISTANT_QUOTA_ENABLED?.trim();
  const quotaEnabled = quotaRaw ? quotaRaw === '1' : identity.mode === 'account';
  if (quotaEnabled && identity.mode !== 'account') {
    throw new ConfigError('ASSISTANT_QUOTA_ENABLED', 'quota requires ASSISTANT_IDENTITY_MODE=account');
  }

  return {
    host,
    port: integerVar(env, 'ASSISTANT_PORT', DEFAULT_PORT, 1, 65535),
    serviceToken,
    identity,
    quotaEnabled,
    accountTurnConcurrency: integerVar(env, 'ASSISTANT_ACCOUNT_TURNS', 1, 1, 8),
    v10: {
      baseUrl: httpsUrl(env, 'V10_BASE_URL', 'https://127.0.0.1:3220', allowInsecure),
      token: requiredSecret(env, 'V10_SERVICE_TOKEN'),
      pipelineVersion: env.V10_PIPELINE_VERSION?.trim() || 'v10.1'
    },
    youtubeApiKey: env.YOUTUBE_API_KEY?.trim() || '',
    youtubeApiBaseUrl: httpsUrl(
      env,
      'YOUTUBE_API_BASE_URL',
      'https://www.googleapis.com/youtube/v3',
      allowInsecure
    ),
    appleSearchBaseUrl: httpsUrl(env, 'APPLE_SEARCH_BASE_URL', 'https://itunes.apple.com', allowInsecure),
    appleSearchCountry: (env.APPLE_SEARCH_COUNTRY?.trim() || 'US').toUpperCase(),
    piConfigDir: env.PI_CONFIG_DIR?.trim() || '/var/lib/linguacast-assistant/pi',
    piAuthPath: env.PI_AUTH_PATH?.trim() || join(homedir(), '.pi', 'agent', 'auth.json'),
    ytdlpPath: env.YTDLP_PATH?.trim() || 'yt-dlp',
    databasePath: env.ASSISTANT_DATABASE_PATH?.trim() || '/var/lib/linguacast-assistant/data/assistant.db',
    tempRoot: env.ASSISTANT_TEMP_ROOT?.trim() || '/var/lib/linguacast-assistant/tmp',
    maxBodyBytes: integerVar(env, 'ASSISTANT_MAX_BODY_BYTES', 64 * 1024, 1024, 1024 * 1024),
    ytdlpTimeoutMs: integerVar(env, 'ASSISTANT_YTDLP_TIMEOUT_MS', 30_000, 1000, 120_000),
    ytdlpStdoutMaxBytes: integerVar(env, 'ASSISTANT_YTDLP_STDOUT_MAX_BYTES', 2 * 1024 * 1024, 4096, 8 * 1024 * 1024),
    ytdlpStderrMaxBytes: 64 * 1024,
    searchLimit: integerVar(env, 'ASSISTANT_SEARCH_LIMIT', 10, 1, 10),
    globalPiTurns: integerVar(env, 'ASSISTANT_GLOBAL_PI_TURNS', 1, 1, 8),
    globalYtdlp: integerVar(env, 'ASSISTANT_GLOBAL_YTDLP', 2, 1, 8),
    allowInsecureUpstream: allowInsecure,
    systemPromptPath: env.ASSISTANT_SYSTEM_PROMPT_PATH?.trim() || '',
    searchV2: env.ASSISTANT_SEARCH_V2 === '1',
    podcastIndexEnabled: env.PODCASTINDEX_ENABLED === '1',
    youtubeHydrationEnabled: env.YOUTUBE_HYDRATION_ENABLED === '1',
    podcastIndexApiKey: env.PODCASTINDEX_API_KEY?.trim() || '',
    podcastIndexApiSecret: env.PODCASTINDEX_API_SECRET?.trim() || '',
    podcastIndexBaseUrl: env.PODCASTINDEX_API_BASE_URL?.trim() || 'https://api.podcastindex.org/api/1.0',
    podcastIndexTimeoutMs: integerVar(env, 'PODCASTINDEX_TIMEOUT_MS', 10_000, 1000, 30_000),
    searchSuccessTtlSeconds: integerVar(env, 'SEARCH_SUCCESS_TTL_SECONDS', 1800, 60, 86_400),
    searchEmptyTtlSeconds: integerVar(env, 'SEARCH_EMPTY_TTL_SECONDS', 300, 30, 3600),
    workspaceRoot: env.ASSISTANT_WORKSPACE_ROOT?.trim() || '',
    globalMemoryRoot: env.ASSISTANT_GLOBAL_MEMORY_ROOT?.trim() || '',
    sharedGrantsPath: env.ASSISTANT_SHARED_GRANTS_PATH?.trim() || '',
    sharedVersionRoot: env.ASSISTANT_SHARED_VERSION_ROOT?.trim() || '',
    sharedWriteEnabled: env.ASSISTANT_SHARED_WRITE_ENABLED === '1',
    rgPath: env.ASSISTANT_RG_PATH?.trim() || 'rg',
    maxGrepMatches: integerVar(env, 'ASSISTANT_MAX_GREP_MATCHES', 200, 1, 1000),
    maxGrepMs: integerVar(env, 'ASSISTANT_MAX_GREP_MS', 5000, 100, 30_000),
    assistantWebEnabled: env.ASSISTANT_WEB_ENABLED === '1',
    webProvider: env.ASSISTANT_WEB_PROVIDER?.trim() || '',
    webApiKey: env.ASSISTANT_WEB_API_KEY?.trim() || '',
    maxWebPageBytes: integerVar(env, 'ASSISTANT_MAX_WEB_PAGE_BYTES', 4 * 1024 * 1024, 4096, 8 * 1024 * 1024)
  };
}

export function registerConfigSecrets(config: ServiceConfig, register: (value: string) => void): void {
  if (config.serviceToken) register(config.serviceToken);
  if (config.identity.introspectionToken) register(config.identity.introspectionToken);
  if (config.identity.contextSigningKey) register(config.identity.contextSigningKey);
  for (const caller of config.identity.internalCallers) register(caller.token);
  register(config.v10.token);
  register(config.youtubeApiKey);
  register(config.podcastIndexApiKey);
  register(config.podcastIndexApiSecret);
  register(config.webApiKey);
}
