import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { AppleClient, defaultFetch } from './apple/apple-client.js';
import { AuthService } from './auth/auth-service.js';
import { ConfigError, loadConfig, registerConfigSecrets } from './config.js';
import { SecretBox } from './crypto/tokens.js';
import { openDatabase } from './db/migrations.js';
import { DeletionWorker } from './deletion/deletion-worker.js';
import { SELFHOST_ACCOUNT_ID } from './domain/ids.js';
import { RedactingLogger } from './observability/logger.js';
import { FixedWindowRateLimiter } from './api/rate-limit.js';
import { AccountStore } from './store/account-store.js';
import { QuotaStore } from './quota/quota-store.js';
import { createApp, listen } from './app.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR =
  [join(HERE, '..', 'migrations'), join(HERE, '..', '..', 'migrations')].find((path) => existsSync(path)) ??
  join(HERE, '..', 'migrations');

async function main(): Promise<void> {
  const logger = new RedactingLogger();
  let config;
  try {
    config = loadConfig();
  } catch (error) {
    if (error instanceof ConfigError) {
      logger.error('startup configuration invalid', { variable: error.variable, reason: error.message });
      process.exit(1);
    }
    throw error;
  }
  registerConfigSecrets(config, (value) => logger.registerSecret(value));

  const now = Date.now;
  const db = openDatabase(config.databasePath, MIGRATIONS_DIR);
  const store = new AccountStore(db);
  const quota = new QuotaStore(db);
  if (config.authMode === 'selfhost') store.ensureAccount(SELFHOST_ACCOUNT_ID, 'selfhost', now());

  const apple = config.apple
    ? new AppleClient({
        teamId: config.apple.teamId,
        keyId: config.apple.keyId,
        privateKeyPem: config.apple.privateKeyPem,
        clientIds: config.apple.clientIds,
        baseUrl: config.apple.baseUrl,
        issuer: config.apple.issuer,
        now
      })
    : null;
  const secretBox = config.apple ? new SecretBox(config.apple.tokenEncryptionKey) : null;
  const auth = new AuthService({ config, store, apple, secretBox, now });
  const deletion = new DeletionWorker({
    store,
    quota,
    apple,
    secretBox,
    purgeTargets: config.purgeTargets,
    purgeToken: config.purgeToken,
    fetchImpl: defaultFetch,
    logger,
    now,
    intervalMs: config.deletionIntervalMs
  });

  const app = createApp({
    config,
    store,
    auth,
    quota,
    now,
    logger,
    authRateLimiter: new FixedWindowRateLimiter(config.authRateLimitPerMinute, now)
  });
  await listen(app, config, logger);
  deletion.start();
  logger.info('account service ready', { authMode: config.authMode, purgeTargets: config.purgeTargets.length });

  let shuttingDown = false;
  const shutdown = (signal: string) => {
    if (shuttingDown) return;
    shuttingDown = true;
    logger.info('shutdown requested', { signal });
    deletion.stop();
    app
      .close()
      .then(() => {
        store.close();
        process.exit(0);
      })
      .catch((error) => {
        logger.error('shutdown failed', { err: String(error) });
        process.exit(1);
      });
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((error) => {
  process.stderr.write(`fatal: ${String(error)}\n`);
  process.exit(1);
});
