import { mkdir, open } from 'node:fs/promises';
import { join } from 'node:path';
import type { IncomingMessage, ServerResponse } from 'node:http';

import type { ServiceConfig } from '../config.js';
import { parseUrl, sendJson } from './http-utils.js';

export interface ReadinessCheckResult {
  ok: boolean;
  detail?: string;
}

export type ReadinessCheck = () => Promise<ReadinessCheckResult>;

export interface ReadinessChecks {
  database: ReadinessCheck;
  objectStoreConfig: ReadinessCheck;
  tempDirWritable: ReadinessCheck;
  workerLease: ReadinessCheck;
}

export const SERVICE_NAME = 'linguacast-content';

export function tempDirWritableCheck(tempRoot: string): ReadinessCheck {
  return async () => {
    try {
      await mkdir(tempRoot, { recursive: true });
      const probe = join(tempRoot, `.ready-${process.pid}.tmp`);
      const handle = await open(probe, 'w');
      await handle.close();
      const { unlink } = await import('node:fs/promises');
      await unlink(probe);
      return { ok: true };
    } catch (error) {
      return { ok: false, detail: `temp dir not writable: ${(error as NodeJS.ErrnoException).code ?? 'unknown'}` };
    }
  };
}

export function objectStoreConfigCheck(config: ServiceConfig): ReadinessCheck {
  // Presence-only check: never calls the (potentially billed) remote API.
  return async () => ({
    ok: Boolean(config.r2.accountId && config.r2.bucket && config.r2.accessKeyId && config.r2.secretAccessKey),
    detail: config.r2.bucket ? `bucket=${config.r2.bucket}` : 'bucket missing'
  });
}

export function handleHealthLive(res: ServerResponse, version: string): void {
  sendJson(res, 200, { status: 'live', service: SERVICE_NAME, version });
}

export async function handleHealthReady(
  req: IncomingMessage,
  res: ServerResponse,
  version: string,
  checks: ReadinessChecks
): Promise<void> {
  void req;
  const [database, objectStoreConfig, tempDirWritable, workerLease] = await Promise.all([
    checks.database(),
    checks.objectStoreConfig(),
    checks.tempDirWritable(),
    checks.workerLease()
  ]);
  const allOk = database.ok && objectStoreConfig.ok && tempDirWritable.ok && workerLease.ok;
  sendJson(res, allOk ? 200 : 503, {
    status: allOk ? 'ready' : 'degraded',
    service: SERVICE_NAME,
    version,
    checks: { database, objectStoreConfig, tempDirWritable, workerLease }
  });
}

export function isHealthLiveRequest(req: IncomingMessage): boolean {
  return req.method === 'GET' && parseUrl(req).pathname === '/v1/content-health/live';
}

export function isHealthReadyRequest(req: IncomingMessage): boolean {
  return req.method === 'GET' && parseUrl(req).pathname === '/v1/content-health/ready';
}
