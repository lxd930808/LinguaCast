import type { IncomingMessage, ServerResponse } from 'node:http';

import type { ServiceConfig } from '../config.js';
import type { JobStore } from '../jobs/job-store.js';
import type { KeyLayout } from '../storage/keys.js';
import { ObjectStoreError, type ObjectStore } from '../storage/object-store.js';
import { authenticate } from './auth.js';
import type { IdentityResolver } from '../auth/identity.js';
import {
  attachRequestContext,
  parseUrl,
  sendError,
  sendJson
} from './http-utils.js';

const ARTIFACT_RE = /^\/v1\/content-artifacts\/([^/]+)\/([^/]+)$/;
const PLAYBACK_URL_RE = /^\/v1\/content-jobs\/([^/]+)\/audio-playback-url$/;

export interface ArtifactRouteDeps {
  config: ServiceConfig;
  store: JobStore;
  objects: ObjectStore;
  keys: KeyLayout;
  identity?: IdentityResolver;
}

interface ManifestFile {
  name: string;
  role: string;
  required: boolean;
  status: string;
  mimeType: string;
  bytes: number;
  sha256: string;
  etag?: string;
}

/** Returns true when the request was handled. */
export async function handleArtifactRoutes(
  req: IncomingMessage,
  res: ServerResponse,
  deps: ArtifactRouteDeps
): Promise<boolean> {
  const url = parseUrl(req);
  const path = url.pathname;
  const artifactMatch = ARTIFACT_RE.exec(path);
  const playbackMatch = PLAYBACK_URL_RE.exec(path);
  if (!artifactMatch && !playbackMatch) return false;

  const { traceId } = attachRequestContext(res);
  const caller = await authenticate(req, res, deps, traceId);
  if (!caller) return true;
  const owner = caller.identity.accountId;

  if (playbackMatch && req.method === 'POST') {
    await issuePlaybackUrl(playbackMatch[1]!, res, deps, owner, traceId);
    return true;
  }
  if (artifactMatch && req.method === 'GET') {
    await downloadArtifact(artifactMatch[1]!, artifactMatch[2]!, req, res, deps, owner, traceId);
    return true;
  }
  sendError(
    res,
    404,
    { code: 'ARTIFACT_NOT_FOUND', message: `No route for ${req.method} ${path}`, retryable: false },
    traceId
  );
  return true;
}

async function issuePlaybackUrl(
  jobId: string,
  res: ServerResponse,
  deps: ArtifactRouteDeps,
  owner: string,
  traceId: string
): Promise<void> {
  const job = deps.store.getJobForOwner(jobId, owner);
  if (!job) {
    sendError(res, 404, { code: 'JOB_NOT_FOUND', message: `Unknown jobId: ${jobId}`, retryable: false }, traceId);
    return;
  }
  const audio = deps.store.audioArtifactForJob(jobId);
  if (!job.audioReady || !audio) {
    sendError(
      res,
      409,
      { code: 'INVALID_JOB_STATE', message: 'audio is not ready for this job', retryable: false },
      traceId
    );
    return;
  }
  deps.keys.assertAllowed(audio.objectKey);
  // The signed URL is returned to the caller only: never persisted, never logged.
  const url = await deps.objects.presignGet(audio.objectKey, deps.config.r2.signedUrlTtlSeconds);
  const expiresAt = new Date(Date.now() + deps.config.r2.signedUrlTtlSeconds * 1000).toISOString();
  sendJson(res, 200, {
    url,
    expiresAt,
    mimeType: audio.mimeType,
    bytes: audio.bytes,
    durationSeconds: audio.durationSeconds,
    sha256: audio.sha256,
    acceptRanges: 'bytes'
  });
}

async function downloadArtifact(
  jobId: string,
  fileName: string,
  req: IncomingMessage,
  res: ServerResponse,
  deps: ArtifactRouteDeps,
  owner: string,
  traceId: string
): Promise<void> {
  const job = deps.store.getJobForOwner(jobId, owner);
  if (!job) {
    sendError(res, 404, { code: 'JOB_NOT_FOUND', message: `Unknown jobId: ${jobId}`, retryable: false }, traceId);
    return;
  }
  const manifest = job.artifacts as { files?: ManifestFile[] } | null;
  const file = manifest?.files?.find((f) => f.name === fileName);
  if (!file || file.status !== 'ready') {
    sendError(
      res,
      404,
      { code: 'ARTIFACT_NOT_FOUND', message: `No artifact ${fileName} for job ${jobId}`, retryable: false },
      traceId
    );
    return;
  }
  const etag = file.etag ?? `"${file.sha256}"`;
  if (req.headers['if-none-match'] === etag) {
    res.writeHead(304, { etag });
    res.end();
    return;
  }
  const key = deps.keys.forAccount(job.ownerScope).jobArtifact(jobId, fileName);
  try {
    const data = await deps.objects.getRange(key);
    res.writeHead(200, {
      'content-type': file.mimeType,
      'content-length': data.length,
      etag,
      'cache-control': 'private, no-cache'
    });
    res.end(data);
  } catch (error) {
    if (error instanceof ObjectStoreError && error.code === 'NOT_FOUND') {
      sendError(
        res,
        404,
        { code: 'ARTIFACT_NOT_FOUND', message: `artifact object missing for ${fileName}`, retryable: false },
        traceId
      );
      return;
    }
    throw error;
  }
}
