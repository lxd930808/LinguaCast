import type { IncomingMessage, ServerResponse } from 'node:http';

import type { ServiceConfig } from '../config.js';
import { playbackForCurrentService } from '../jobs/job-model.js';
import { deleteJobArtifacts, type JobRunner } from '../jobs/job-runner.js';
import type { JobStore } from '../jobs/job-store.js';
import { requireBearer } from './auth.js';
import { parseUrl, sendJson } from './http-utils.js';

const JOB_RE = /^\/v1\/jobs\/([^/]+)$/;

export async function handleJob(
  req: IncomingMessage,
  res: ServerResponse,
  config: ServiceConfig,
  store: JobStore,
  runner?: JobRunner
): Promise<boolean> {
  const url = parseUrl(req);
  const match = JOB_RE.exec(url.pathname);
  if (!match) return false;

  if (req.method === 'DELETE') {
    if (!requireBearer(req, res, config.bearerToken)) return true;
    const jobId = match[1]!;
    const job = store.get(jobId);
    if (!job) {
      sendJson(res, 404, {
        error: 'JOB_NOT_FOUND',
        message: `Unknown jobId: ${jobId}`
      });
      return true;
    }
    runner?.cancel(jobId);
    await deleteJobArtifacts(store, config, jobId);
    sendJson(res, 200, { jobId, deleted: true });
    return true;
  }

  if (req.method !== 'GET') return false;
  if (!requireBearer(req, res, config.bearerToken)) return true;

  const jobId = match[1]!;
  const job = store.get(jobId);
  if (!job) {
    sendJson(res, 404, {
      error: 'JOB_NOT_FOUND',
      message: `Unknown jobId: ${jobId}`
    });
    return true;
  }

  const incompleteStreamingHls =
    job.mode === 'hls' && job.status === 'ready' && job.progress < 1;
  if (
    Date.now() >= job.expiresAt &&
    (job.status === 'failed' ||
      (job.status === 'ready' && !incompleteStreamingHls))
  ) {
    sendJson(res, 410, {
      error: 'MEDIA_EXPIRED',
      message: 'Job media has expired'
    });
    return true;
  }

  sendJson(res, 200, {
    jobId: job.jobId,
    videoId: job.videoId,
    mode: job.mode,
    preferredHeight: job.preferredHeight,
    status: job.status,
    progress: job.progress,
    createdAt: job.createdAt,
    updatedAt: job.updatedAt,
    expiresAt: job.expiresAt,
    errorCode: job.errorCode ?? null,
    errorMessage: job.errorMessage ?? null,
    playback: playbackForCurrentService(
      job.playback,
      config.publicBaseUrl,
      job.jobId,
      config.requireMediaAuth ? config.bearerToken : null
    ),
    diagnostics: {
      selected: {
        videoItag: job.diagnostics.videoItag ?? null,
        audioItag: job.diagnostics.audioItag ?? null,
        videoCodec: job.diagnostics.videoCodec ?? null,
        audioCodec: job.diagnostics.audioCodec ?? null,
        videoHeight: job.diagnostics.videoHeight ?? job.diagnostics.height ?? null,
        videoBytes: job.diagnostics.videoBytes ?? null,
        audioBytes: job.diagnostics.audioBytes ?? null
      },
      timings: {
        fetchElapsedMs: job.diagnostics.fetchElapsedMs ?? null,
        packageElapsedMs: job.diagnostics.packageElapsedMs ?? null
      },
      download: {
        transport: job.diagnostics.transport ?? job.diagnostics.engine ?? null,
        videoTarget: job.diagnostics.videoTarget ?? null,
        audioTarget: job.diagnostics.audioTarget ?? null,
        resumedVideoBytes: job.diagnostics.resumedVideoBytes ?? null,
        resumedAudioBytes: job.diagnostics.resumedAudioBytes ?? null,
        lastEvent:
          job.diagnostics.directFailure ??
          job.diagnostics.directDownload ??
          null,
        failure: job.diagnostics.failure ?? null
      }
    }
  });
  return true;
}
