import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ConfigError, loadConfig, registerConfigSecrets } from '../src/config.js';
import { RedactingLogger } from '../src/observability/logger.js';

function baseEnv(): NodeJS.ProcessEnv {
  return {
    CONTENT_IDENTITY_MODE: 'selfhost', CONTENT_SERVICE_TOKEN: 'test-service-token-0123456789',
    MEDIA_API_TOKEN: 'test-media-token-0123456789',
    DASHSCOPE_API_KEY: 'test-dashscope-key-0123456789',
    TRANSLATION_API_KEY: 'test-translation-key-0123456789',
    TRANSLATION_MODEL: 'test-model',
    R2_ACCOUNT_ID: 'acct',
    R2_ACCESS_KEY_ID: 'r2-access',
    R2_SECRET_ACCESS_KEY: 'r2-secret-0123456789',
    R2_BUCKET: 'linguacast'
  };
}

test('valid env loads with loopback defaults', () => {
  const config = loadConfig(baseEnv());
  assert.equal(config.host, '127.0.0.1');
  assert.equal(config.port, 3220);
  assert.equal(config.identity.mode, 'selfhost');
  assert.equal(config.r2.prefix, 'content-pipeline');
  assert.equal(config.r2.signedUrlTtlSeconds, 3600);
  assert.equal(config.diskWatermarkBytes, 5 * 1024 * 1024 * 1024);
});

function catchConfigError(fn: () => unknown): ConfigError {
  try {
    fn();
  } catch (error) {
    assert.ok(error instanceof ConfigError, 'expected ConfigError');
    return error;
  }
  assert.fail('expected loadConfig to throw');
}

test('missing secret fails naming the variable only', () => {
  const env = baseEnv();
  delete env.DASHSCOPE_API_KEY;
  const error = catchConfigError(() => loadConfig(env));
  assert.equal(error.variable, 'DASHSCOPE_API_KEY');
  assert.ok(!error.message.includes('test-'), 'error must not contain any secret value');
});

test('non-loopback bind is rejected', () => {
  const error = catchConfigError(() => loadConfig({ ...baseEnv(), CONTENT_HOST: '0.0.0.0' }));
  assert.equal(error.variable, 'CONTENT_HOST');
  const other = catchConfigError(() => loadConfig({ ...baseEnv(), CONTENT_HOST: '192.168.1.10' }));
  assert.equal(other.variable, 'CONTENT_HOST');
});

test('container bind requires explicit acknowledgment', () => {
  const config = loadConfig({
    ...baseEnv(),
    CONTENT_HOST: '0.0.0.0',
    CONTENT_BIND_ALL_INTERFACES: '1'
  });
  assert.equal(config.host, '0.0.0.0');
  // A different non-loopback host is rejected even with the flag set.
  const error = catchConfigError(() =>
    loadConfig({ ...baseEnv(), CONTENT_HOST: '192.168.1.10', CONTENT_BIND_ALL_INTERFACES: '1' })
  );
  assert.equal(error.variable, 'CONTENT_HOST');
});

test('invalid URLs are rejected', () => {
  assert.equal(
    catchConfigError(() => loadConfig({ ...baseEnv(), MEDIA_API_BASE_URL: 'not-a-url' })).variable,
    'MEDIA_API_BASE_URL'
  );
  assert.equal(
    catchConfigError(() => loadConfig({ ...baseEnv(), MEDIA_API_BASE_URL: 'ftp://example.com' })).variable,
    'MEDIA_API_BASE_URL'
  );
});

test('invalid reasoning effort is rejected', () => {
  assert.equal(
    catchConfigError(() => loadConfig({ ...baseEnv(), TRANSLATION_REASONING_EFFORT: 'extreme' })).variable,
    'TRANSLATION_REASONING_EFFORT'
  );
});

test('short secrets are rejected', () => {
  assert.equal(
    catchConfigError(() => loadConfig({ ...baseEnv(), CONTENT_IDENTITY_MODE: 'selfhost', CONTENT_SERVICE_TOKEN: 'short' })).variable,
    'CONTENT_SERVICE_TOKEN'
  );
});

test('video media settings default safely and reject out-of-range values', () => {
  const config = loadConfig(baseEnv());
  assert.equal(config.videoMediaPromotionEnabled, false);
  assert.equal(config.videoMediaRetentionDays, 30);
  assert.equal(config.videoMediaCleanupIntervalSeconds, 21_600);
  assert.equal(config.videoMediaCleanupBatchSize, 50);
  assert.equal(config.videoMediaBudgetBytes, 100 * 1024 * 1024 * 1024);

  const enabled = loadConfig({ ...baseEnv(), VIDEO_MEDIA_PROMOTION_ENABLED: 'true' });
  assert.equal(enabled.videoMediaPromotionEnabled, true);

  assert.equal(
    catchConfigError(() => loadConfig({ ...baseEnv(), CONTENT_VIDEO_MEDIA_RETENTION_DAYS: '0' })).variable,
    'CONTENT_VIDEO_MEDIA_RETENTION_DAYS'
  );
  assert.equal(
    catchConfigError(() => loadConfig({ ...baseEnv(), CONTENT_VIDEO_MEDIA_RETENTION_DAYS: '400' })).variable,
    'CONTENT_VIDEO_MEDIA_RETENTION_DAYS'
  );
  assert.equal(
    catchConfigError(() => loadConfig({ ...baseEnv(), CONTENT_VIDEO_MEDIA_CLEANUP_BATCH_SIZE: '0' })).variable,
    'CONTENT_VIDEO_MEDIA_CLEANUP_BATCH_SIZE'
  );
  assert.equal(
    catchConfigError(() => loadConfig({ ...baseEnv(), VIDEO_MEDIA_PROMOTION_ENABLED: 'maybe' })).variable,
    'VIDEO_MEDIA_PROMOTION_ENABLED'
  );
  const error = catchConfigError(() =>
    loadConfig({ ...baseEnv(), CONTENT_VIDEO_MEDIA_BUDGET_BYTES: '-1' })
  );
  assert.equal(error.variable, 'CONTENT_VIDEO_MEDIA_BUDGET_BYTES');
  assert.ok(!error.message.includes('-1'), 'config errors must not echo the rejected value');
});

test('registered secrets are redacted from logs', () => {
  const lines: string[] = [];
  const logger = new RedactingLogger((line) => lines.push(line));
  const config = loadConfig(baseEnv());
  registerConfigSecrets(config, (value) => logger.registerSecret(value));

  logger.info('token leak attempt', { token: config.serviceToken });
  logger.info('signed url', { url: 'https://r2.example.com/x?X-Amz-Signature=abc123&X-Amz-Expires=3600' });
  logger.info('auth header', { header: `Bearer ${config.mediaApi.token}` });

  const joined = lines.join('\n');
  assert.ok(!joined.includes(config.serviceToken), 'service token must be redacted');
  assert.ok(!joined.includes(config.mediaApi.token), 'media token must be redacted');
  assert.ok(!joined.includes('abc123'), 'signed URL query must be redacted');
});

test('DeepSeek defaults mirror the App and allow max effort', () => {
  const env = { ...baseEnv(), TRANSLATION_PROVIDER: ' DeepSeek ', TRANSLATION_MODEL: '' };
  const config = loadConfig(env).translation;
  assert.equal(config.provider, 'deepseek');
  assert.equal(config.baseUrl, 'https://api.deepseek.com');
  assert.equal(config.model, 'deepseek-v4-flash');
  assert.equal(config.reasoningEffort, 'high');
  assert.equal(config.requestTimeoutMs, 300_000);
  assert.equal(config.networkRetries, 2);
  assert.equal(loadConfig({ ...env, TRANSLATION_REASONING_EFFORT: 'max' }).translation.reasoningEffort, 'max');
  assert.equal(catchConfigError(() => loadConfig({ ...env, TRANSLATION_REASONING_EFFORT: 'low' })).variable, 'TRANSLATION_REASONING_EFFORT');
  assert.equal(loadConfig({ ...env, TRANSLATION_MODEL: 'custom-model', TRANSLATION_BASE_URL: 'https://gateway.example/v1' }).translation.model, 'custom-model');
});

test('translation transport limits are configurable and validated', () => {
  const config = loadConfig({ ...baseEnv(), TRANSLATION_REQUEST_TIMEOUT_MS: '180000', TRANSLATION_NETWORK_RETRIES: '0' });
  assert.equal(config.translation.requestTimeoutMs, 180000);
  assert.equal(config.translation.networkRetries, 0);
  for (const [key, value] of [['TRANSLATION_REQUEST_TIMEOUT_MS', '0'], ['TRANSLATION_REQUEST_TIMEOUT_MS', '900001'], ['TRANSLATION_NETWORK_RETRIES', '-1'], ['TRANSLATION_NETWORK_RETRIES', '6']]) {
    assert.equal(catchConfigError(() => loadConfig({ ...baseEnv(), [key]: value })).variable, key);
  }
  assert.equal(catchConfigError(() => loadConfig({ ...baseEnv(), TRANSLATION_PROVIDER: 'unknown' })).variable, 'TRANSLATION_PROVIDER');
});
