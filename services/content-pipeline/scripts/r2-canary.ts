/**
 * R2 canary: upload a test object to the canary prefix, sign a URL, HEAD,
 * full read, Range read, then delete the exact object. Refuses to operate
 * outside the canary prefix. This is a DEPLOYMENT GATE, not a CI test.
 *
 * Usage: npm run r2:canary  (requires full env config)
 */
import { loadConfig, registerConfigSecrets } from '../src/config.js';
import { RedactingLogger } from '../src/observability/logger.js';
import { KeyLayout } from '../src/storage/keys.js';
import { R2ObjectStore } from '../src/storage/r2-store.js';

async function main(): Promise<void> {
  const logger = new RedactingLogger();
  const config = loadConfig();
  registerConfigSecrets(config, (value) => logger.registerSecret(value));

  const keys = new KeyLayout(config.r2);
  const store = new R2ObjectStore(config.r2);
  const payload = Buffer.from(`linguacast-content canary ${new Date().toISOString()}\n`);
  const key = keys.canary(`canary-${Date.now()}.txt`);
  keys.assertCanary(key);

  logger.info('canary: put', { key });
  await store.put(key, payload, 'text/plain');

  const head = await store.head(key);
  if (!head || head.bytes !== payload.length) {
    throw new Error('canary: HEAD mismatch');
  }

  const full = await store.getRange(key);
  if (!full.equals(payload)) {
    throw new Error('canary: full read mismatch');
  }

  const range = await store.getRange(key, 0, 9);
  if (range.length !== 10 || !range.equals(payload.subarray(0, 10))) {
    throw new Error('canary: range read mismatch');
  }

  const tail = await store.getRange(key, payload.length - 5, payload.length - 1);
  if (!tail.equals(payload.subarray(-5))) {
    throw new Error('canary: tail range mismatch');
  }

  const signed = await store.presignGet(key, 300);
  if (!signed.includes('X-Amz-Signature=')) {
    throw new Error('canary: presigned URL missing signature');
  }
  logger.info('canary: presigned URL issued', { expiresInSeconds: 300 });

  await store.delete(key);
  const after = await store.head(key);
  if (after) {
    throw new Error('canary: delete did not remove the object');
  }

  logger.info('canary: OK', { key });
}

main().catch((error) => {
  process.stderr.write(`canary failed: ${String(error)}\n`);
  process.exit(1);
});
