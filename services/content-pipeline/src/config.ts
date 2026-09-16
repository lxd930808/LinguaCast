/**
 * Environment-driven configuration with strict startup validation.
 * Rules (WP1):
 *  - bind host is forced to 127.0.0.1; 0.0.0.0 is accepted only together with
 *    CONTENT_BIND_ALL_INTERFACES=1 (container deploys with a loopback-only
 *    host port publish); anything else fails startup
 *  - all secrets come from the environment only
 *  - validation errors name the offending VARIABLE, never its value
 */

export interface MediaApiConfig {
  baseUrl: string;
  token: string;
}

export interface DashScopeConfig {
  apiKey: string;
  baseUrl: string;
}

export interface TranslationConfig {
  provider: 'dashscope' | 'openrouter' | 'deepseek';
  baseUrl: string;
  apiKey: string;
  model: string;
  reasoningEffort: 'none' | 'low' | 'medium' | 'high' | 'max' | null;
  requestTimeoutMs: number;
  networkRetries: number;
}

export interface R2Config {
  accountId: string;
  accessKeyId: string;
  secretAccessKey: string;
  bucket: string;
  prefix: string;
  environment: string;
  signedUrlTtlSeconds: number;
}

export interface InternalCallerConfig {
  name: 'research-assistant' | 'account-service';
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
  /** V18 WP04 daily quota and queueing. */
  quota: {
    enabled: boolean;
    accountConcurrency: number;
    globalConcurrency: number;
    probeHeadBytes: number;
  };
  pipelineVersion: string;
  mediaApi: MediaApiConfig;
  dashscope: DashScopeConfig;
  translation: TranslationConfig;
  r2: R2Config;
  maxBodyBytes: number;
  maxMediaBytes: number;
  maxMediaDurationSeconds: number;
  mediaConcurrency: number;
  workerConcurrency: number;
  diskWatermarkBytes: number;
  tempRoot: string;
  databasePath: string;
  videoMediaPromotionEnabled: boolean;
  videoMediaRetentionDays: number;
  videoMediaCleanupIntervalSeconds: number;
  videoMediaCleanupBatchSize: number;
  videoMediaBudgetBytes: number;
}

export class ConfigError extends Error {
  readonly variable: string;
  constructor(variable: string, reason: string) {
    super(`Invalid configuration for ${variable}: ${reason}`);
    this.name = 'ConfigError';
    this.variable = variable;
  }
}

const REQUIRED_SECRET_MIN_LENGTH = 8;
const INTERNAL_SECRET_MIN_LENGTH = 32;
const INTERNAL_CALLER_NAMES: ReadonlyArray<InternalCallerConfig['name']> = ['research-assistant', 'account-service'];

function parseInternalCallers(raw: string | undefined): InternalCallerConfig[] {
  const entries = (raw ?? '').split(',').map((entry) => entry.trim()).filter(Boolean);
  const seen = new Set<string>();
  return entries.map((entry) => {
    const separator = entry.indexOf(':');
    const name = separator > 0 ? entry.slice(0, separator) : '';
    const token = separator > 0 ? entry.slice(separator + 1) : '';
    if (!INTERNAL_CALLER_NAMES.includes(name as InternalCallerConfig['name'])) {
      throw new ConfigError('CONTENT_INTERNAL_CALLERS', `caller must be one of ${INTERNAL_CALLER_NAMES.join('|')}`);
    }
    if (token.length < INTERNAL_SECRET_MIN_LENGTH) {
      throw new ConfigError('CONTENT_INTERNAL_CALLERS', `each token must be at least ${INTERNAL_SECRET_MIN_LENGTH} characters`);
    }
    if (seen.has(name)) throw new ConfigError('CONTENT_INTERNAL_CALLERS', 'each caller may appear once');
    seen.add(name);
    return { name: name as InternalCallerConfig['name'], token };
  });
}

function loadIdentity(env: NodeJS.ProcessEnv): { identity: IdentityConfig; serviceToken: string } {
  const modeRaw = requiredVar(env, 'CONTENT_IDENTITY_MODE').trim().toLowerCase();
  if (modeRaw !== 'selfhost' && modeRaw !== 'account') {
    throw new ConfigError('CONTENT_IDENTITY_MODE', 'must be selfhost or account');
  }
  const signingKey = env.ACCOUNT_CONTEXT_SIGNING_KEY?.trim() || null;
  if (signingKey !== null && signingKey.length < INTERNAL_SECRET_MIN_LENGTH) {
    throw new ConfigError('ACCOUNT_CONTEXT_SIGNING_KEY', `must be at least ${INTERNAL_SECRET_MIN_LENGTH} characters`);
  }
  const internalCallers = parseInternalCallers(env.CONTENT_INTERNAL_CALLERS);
  if (modeRaw === 'selfhost') {
    return {
      serviceToken: requiredSecret(env, 'CONTENT_SERVICE_TOKEN'),
      identity: { mode: 'selfhost', accountServiceUrl: null, introspectionToken: null, internalCallers, contextSigningKey: signingKey }
    };
  }
  if (signingKey === null) throw new ConfigError('ACCOUNT_CONTEXT_SIGNING_KEY', 'required variable is missing or empty');
  const introspectionToken = requiredVar(env, 'CONTENT_ACCOUNT_TOKEN');
  if (introspectionToken.length < INTERNAL_SECRET_MIN_LENGTH) {
    throw new ConfigError('CONTENT_ACCOUNT_TOKEN', `must be at least ${INTERNAL_SECRET_MIN_LENGTH} characters`);
  }
  return {
    serviceToken: '',
    identity: {
      mode: 'account',
      accountServiceUrl: optionalUrl(env, 'ACCOUNT_SERVICE_URL', ''),
      introspectionToken,
      internalCallers,
      contextSigningKey: signingKey
    }
  };
}

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

function optionalUrl(env: NodeJS.ProcessEnv, name: string, fallback: string): string {
  const value = env[name] ?? fallback;
  try {
    const url = new URL(value);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') {
      throw new ConfigError(name, 'must use http or https');
    }
  } catch (error) {
    if (error instanceof ConfigError) throw error;
    throw new ConfigError(name, 'must be a valid URL');
  }
  return value.replace(/\/+$/, '');
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

function booleanVar(env: NodeJS.ProcessEnv, name: string, fallback: boolean): boolean {
  const raw = env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  const value = raw.trim().toLowerCase();
  if (value === '1' || value === 'true' || value === 'yes') return true;
  if (value === '0' || value === 'false' || value === 'no') return false;
  throw new ConfigError(name, 'must be true or false');
}

export const LOOPBACK_HOST = '127.0.0.1';
export const CONTAINER_BIND_HOST = '0.0.0.0';
export const DEFAULT_PORT = 3220;
export const DEFAULT_PIPELINE_VERSION = 'v10.1';
export const DEFAULT_DISK_WATERMARK_BYTES = 5 * 1024 * 1024 * 1024; // 5 GiB hard guardrail

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ServiceConfig {
  const host = env.CONTENT_HOST ?? LOOPBACK_HOST;
  if (host !== LOOPBACK_HOST) {
    // 0.0.0.0 is only acceptable inside a container whose runtime publishes the
    // port on the host loopback exclusively (see deploy/dmit compose file:
    // "127.0.0.1:3220:3220"). The operator must acknowledge that arrangement
    // explicitly; bare-metal 0.0.0.0 stays rejected.
    const containerBindOk =
      host === CONTAINER_BIND_HOST && env.CONTENT_BIND_ALL_INTERFACES === '1';
    if (!containerBindOk) {
      throw new ConfigError(
        'CONTENT_HOST',
        'service must bind to 127.0.0.1 (loopback only); 0.0.0.0 requires CONTENT_BIND_ALL_INTERFACES=1 with a loopback-only port publish'
      );
    }
  }
  const port = integerVar(env, 'CONTENT_PORT', DEFAULT_PORT, 1, 65535);
  const { identity, serviceToken } = loadIdentity(env);
  const quotaEnabled = booleanVar(env, 'CONTENT_QUOTA_ENABLED', identity.mode === 'account');
  if (quotaEnabled && identity.mode !== 'account') {
    throw new ConfigError('CONTENT_QUOTA_ENABLED', 'quota requires CONTENT_IDENTITY_MODE=account');
  }

  const providerRaw = (env.TRANSLATION_PROVIDER ?? 'dashscope').trim().toLowerCase();
  if (providerRaw !== 'dashscope' && providerRaw !== 'openrouter' && providerRaw !== 'deepseek') {
    throw new ConfigError('TRANSLATION_PROVIDER', 'must be dashscope, openrouter or deepseek');
  }
  const reasoningRaw = env.TRANSLATION_REASONING_EFFORT?.trim().toLowerCase();
  let reasoningEffort: TranslationConfig['reasoningEffort'] = providerRaw === 'deepseek' ? 'high' : null;
  const allowedEfforts = providerRaw === 'deepseek' ? ['high', 'max'] : ['none', 'low', 'medium', 'high'];
  if (reasoningRaw) {
    if (!allowedEfforts.includes(reasoningRaw)) {
      throw new ConfigError('TRANSLATION_REASONING_EFFORT', `must be one of ${allowedEfforts.join('|')}`);
    }
    reasoningEffort = reasoningRaw as TranslationConfig['reasoningEffort'];
  }

  return {
    host,
    port,
    serviceToken,
    identity,
    quota: {
      enabled: quotaEnabled,
      accountConcurrency: integerVar(env, 'CONTENT_ACCOUNT_CONCURRENCY', 1, 1, 16),
      globalConcurrency: integerVar(env, 'CONTENT_GLOBAL_CONCURRENCY', 1, 1, 16),
      probeHeadBytes: integerVar(env, 'CONTENT_PROBE_HEAD_BYTES', 2 * 1024 * 1024, 64 * 1024, 16 * 1024 * 1024)
    },
    pipelineVersion: env.CONTENT_PIPELINE_VERSION?.trim() || DEFAULT_PIPELINE_VERSION,
    mediaApi: {
      baseUrl: optionalUrl(env, 'MEDIA_API_BASE_URL', 'http://127.0.0.1:3210'),
      token: requiredSecret(env, 'MEDIA_API_TOKEN')
    },
    dashscope: {
      apiKey: requiredSecret(env, 'DASHSCOPE_API_KEY'),
      baseUrl: optionalUrl(env, 'DASHSCOPE_BASE_URL', 'https://dashscope.aliyuncs.com')
    },
    translation: {
      provider: providerRaw,
      baseUrl: optionalUrl(
        env,
        'TRANSLATION_BASE_URL',
        providerRaw === 'deepseek' ? 'https://api.deepseek.com'
          : providerRaw === 'openrouter' ? 'https://openrouter.ai/api' : 'https://dashscope.aliyuncs.com'
      ),
      apiKey: requiredSecret(env, 'TRANSLATION_API_KEY'),
      model: providerRaw === 'deepseek' ? (env.TRANSLATION_MODEL?.trim() || 'deepseek-v4-flash')
        : requiredVar(env, 'TRANSLATION_MODEL'),
      reasoningEffort,
      requestTimeoutMs: integerVar(env, 'TRANSLATION_REQUEST_TIMEOUT_MS', 300_000, 1000, 900_000),
      networkRetries: integerVar(env, 'TRANSLATION_NETWORK_RETRIES', 2, 0, 5)
    },
    r2: {
      accountId: requiredVar(env, 'R2_ACCOUNT_ID'),
      accessKeyId: requiredVar(env, 'R2_ACCESS_KEY_ID'),
      secretAccessKey: requiredSecret(env, 'R2_SECRET_ACCESS_KEY'),
      bucket: requiredVar(env, 'R2_BUCKET'),
      prefix: (env.R2_PREFIX?.trim() || 'content-pipeline').replace(/^\/+|\/+$/g, ''),
      environment: env.R2_ENVIRONMENT?.trim() || 'prod',
      signedUrlTtlSeconds: integerVar(env, 'R2_SIGNED_URL_TTL_SECONDS', 3600, 60, 86400)
    },
    maxBodyBytes: integerVar(env, 'CONTENT_MAX_BODY_BYTES', 64 * 1024, 1024, 1024 * 1024),
    maxMediaBytes: integerVar(env, 'CONTENT_MAX_MEDIA_BYTES', 400 * 1024 * 1024, 1024 * 1024, 2 * 1024 * 1024 * 1024),
    maxMediaDurationSeconds: integerVar(env, 'CONTENT_MAX_MEDIA_DURATION_SECONDS', 4 * 3600, 60, 12 * 3600),
    mediaConcurrency: 1,
    workerConcurrency: 1,
    diskWatermarkBytes: integerVar(
      env,
      'CONTENT_DISK_WATERMARK_BYTES',
      DEFAULT_DISK_WATERMARK_BYTES,
      1024 * 1024 * 1024,
      64 * 1024 * 1024 * 1024
    ),
    tempRoot: env.CONTENT_TEMP_ROOT?.trim() || '/var/lib/linguacast-content/tmp',
    databasePath: env.CONTENT_DATABASE_PATH?.trim() || '/var/lib/linguacast-content/data/content.db',
    videoMediaPromotionEnabled: booleanVar(env, 'VIDEO_MEDIA_PROMOTION_ENABLED', false),
    videoMediaRetentionDays: integerVar(env, 'CONTENT_VIDEO_MEDIA_RETENTION_DAYS', 30, 1, 365),
    videoMediaCleanupIntervalSeconds: integerVar(
      env,
      'CONTENT_VIDEO_MEDIA_CLEANUP_INTERVAL_SECONDS',
      21_600,
      60,
      86400
    ),
    videoMediaCleanupBatchSize: integerVar(env, 'CONTENT_VIDEO_MEDIA_CLEANUP_BATCH_SIZE', 50, 1, 500),
    videoMediaBudgetBytes: integerVar(
      env,
      'CONTENT_VIDEO_MEDIA_BUDGET_BYTES',
      100 * 1024 * 1024 * 1024,
      0,
      Number.MAX_SAFE_INTEGER
    )
  };
}

/** Register every secret with the redacting logger (values, never names). */
export function registerConfigSecrets(config: ServiceConfig, register: (value: string) => void): void {
  register(config.serviceToken);
  if (config.identity.introspectionToken) register(config.identity.introspectionToken);
  if (config.identity.contextSigningKey) register(config.identity.contextSigningKey);
  for (const caller of config.identity.internalCallers) register(caller.token);
  register(config.mediaApi.token);
  register(config.dashscope.apiKey);
  register(config.translation.apiKey);
  register(config.r2.secretAccessKey);
  register(config.r2.accessKeyId);
}
