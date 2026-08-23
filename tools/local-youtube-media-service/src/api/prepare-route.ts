import type { IncomingMessage, ServerResponse } from 'node:http';

import type { MediaMode, ServiceConfig } from '../config.js';
import { assertDiskBudget } from '../jobs/disk-budget.js';
import { isValidVideoId, type PrepareRequest } from '../jobs/job-model.js';
import { deleteJobArtifacts, type JobRunner } from '../jobs/job-runner.js';
import type { JobStore } from '../jobs/job-store.js';
import { requireBearer } from './auth.js';
import { parseUrl, readJsonBody, sendJson } from './http-utils.js';

const PREPARE_RE = /^\/v1\/videos\/([^/]+)\/prepare$/;

export async function handlePrepare(
  req: IncomingMessage,
  res: ServerResponse,
  config: ServiceConfig,
  store: JobStore,
  runner: JobRunner
): Promise<boolean> {
  const url = parseUrl(req);
  const match = PREPARE_RE.exec(url.pathname);
  if (!match || req.method !== 'POST') return false;
  if (!requireBearer(req, res, config.bearerToken)) return true;

  const videoId = match[1]!;
  if (!isValidVideoId(videoId)) {
    sendJson(res, 400, {
      error: 'INVALID_VIDEO_ID',
      message: 'videoId must be a standard 11-character YouTube ID'
    });
    return true;
  }

  let body: PrepareRequest = {};
  try {
    body = await readJsonBody<PrepareRequest>(req);
  } catch {
    sendJson(res, 400, {
      error: 'INVALID_JSON',
      message: 'Request body must be JSON'
    });
    return true;
  }

  const mode: MediaMode = body.mode === 'hls' ? 'hls' : 'mp4';
  const preferredHeight =
    typeof body.preferredHeight === 'number' && body.preferredHeight > 0
      ? Math.floor(body.preferredHeight)
      : config.preferredHeight;

  const existing = store.findActiveDedupe(videoId, mode, preferredHeight);
  if (!existing) {
    try {
      await assertDiskBudget({
        mediaRoot: config.mediaRoot,
        minFreeBytes: config.minFreeBytes
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      sendJson(res, 507, {
        error: 'DISK_FULL',
        message
      });
      return true;
    }

    if (runner.activeCount() >= config.maxConcurrentJobs) {
      const terminal = store
        .list()
        .filter((job) => job.status === 'ready' || job.status === 'failed')
        .sort((a, b) => a.updatedAt - b.updatedAt);
      if (terminal[0]) {
        await deleteJobArtifacts(store, config, terminal[0].jobId);
      }
    }
  }

  const job = await store.create(videoId, mode, preferredHeight);
  const shouldStart = job.status === 'queued';
  if (shouldStart) {
    runner.enqueue(job.jobId);
  }

  sendJson(res, 202, {
    jobId: job.jobId,
    status: shouldStart ? 'queued' : job.status,
    statusUrl: `${config.publicBaseUrl}/v1/jobs/${job.jobId}`
  });
  return true;
}
