import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ConfigError, loadConfig, registerConfigSecrets } from '../src/config/index.js';
import { RedactingLogger } from '../src/observability/logger.js';

function baseEnv(): NodeJS.ProcessEnv {
  return {
    ASSISTANT_IDENTITY_MODE: 'selfhost', ASSISTANT_SERVICE_TOKEN: 'test-assistant-token-0123456789',
    V10_SERVICE_TOKEN: 'test-v10-token-0123456789',
    V10_BASE_URL: 'https://content.example.test',
    NODE_ENV: 'test'
  };
}

test('valid env loads loopback defaults on 3230', () => {
  const config = loadConfig(baseEnv());
  assert.equal(config.host, '127.0.0.1');
  assert.equal(config.port, 3230);
  assert.equal(config.identity.mode, 'selfhost');
  assert.equal(config.systemPromptPath, '');
  assert.match(config.piAuthPath, /\.pi\/agent\/auth\.json$/);
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

test('missing token names the variable only', () => {
  const env = baseEnv();
  delete env.ASSISTANT_SERVICE_TOKEN;
  const error = catchConfigError(() => loadConfig(env));
  assert.equal(error.variable, 'ASSISTANT_SERVICE_TOKEN');
  assert.ok(!error.message.includes('test-'));
});

test('HTTP V10 URL is rejected unless insecure upstream is allowed', () => {
  const error = catchConfigError(() =>
    loadConfig({
      ASSISTANT_IDENTITY_MODE: 'selfhost', ASSISTANT_SERVICE_TOKEN: 'test-assistant-token-0123456789',
      V10_SERVICE_TOKEN: 'test-v10-token-0123456789',
      V10_BASE_URL: 'http://127.0.0.1:3220',
      ASSISTANT_ALLOW_INSECURE_UPSTREAM: '0',
      NODE_ENV: 'production'
    })
  );
  assert.equal(error.variable, 'V10_BASE_URL');
});

test('non-loopback bind is rejected', () => {
  const error = catchConfigError(() => loadConfig({ ...baseEnv(), ASSISTANT_HOST: '0.0.0.0' }));
  assert.equal(error.variable, 'ASSISTANT_HOST');
});

test('container bind requires explicit acknowledgment', () => {
  const config = loadConfig({ ...baseEnv(), ASSISTANT_HOST: '0.0.0.0', ASSISTANT_BIND_ALL_INTERFACES: '1' });
  assert.equal(config.host, '0.0.0.0');
});

test('search v2 flags default off and PI secrets are registered', () => {
  const config = loadConfig(baseEnv());
  assert.equal(config.searchV2, false);
  assert.equal(config.sharedWriteEnabled, false);
  assert.equal(config.assistantWebEnabled, false);
  assert.equal(config.rgPath, 'rg');
  assert.equal(config.maxGrepMatches, 200);
  assert.equal(config.podcastIndexEnabled, false);
  assert.equal(config.youtubeHydrationEnabled, false);
  const secrets: string[] = [];
  registerConfigSecrets(
    loadConfig({ ...baseEnv(), PODCASTINDEX_API_KEY: 'pi-key-abcdefgh', PODCASTINDEX_API_SECRET: 'pi-secret-ijklmnop' }),
    (value) => secrets.push(value)
  );
  assert.ok(secrets.includes('pi-key-abcdefgh'));
  assert.ok(secrets.includes('pi-secret-ijklmnop'));
});

test('logger redacts tokens and never prints the user question', () => {
  const lines: string[] = [];
  const logger = new RedactingLogger((line) => lines.push(line));
  const config = loadConfig(baseEnv());
  registerConfigSecrets(config, (value) => logger.registerSecret(value));
  logger.info('Authorization Bearer test-assistant-token-0123456789', {
    text: 'this is a very long user question that must not leak into ordinary logs at all'
  });
  const joined = lines.join('\n');
  assert.ok(joined.includes('[REDACTED]'));
  assert.ok(!joined.includes('test-assistant-token-0123456789'));
  assert.ok(!joined.includes('very long user question'));
});
