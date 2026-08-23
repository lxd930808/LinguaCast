import { createReadStream } from 'node:fs';
import { open, stat } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import path from 'node:path';

import type { ServiceConfig } from '../config.js';
import type { JobStore } from '../jobs/job-store.js';
import { requireBearer } from './auth.js';
import { parseUrl, sendJson } from './http-utils.js';

const MEDIA_RE = /^\/media\/([^/]+)\/(.+)$/;

const MIME_BY_EXT: Record<string, string> = {
  '.mp4': 'video/mp4',
  '.m4s': 'video/iso.segment',
  '.m3u8': 'application/vnd.apple.mpegurl',
  '.m4a': 'audio/mp4',
  '.webm': 'video/webm'
};

function contentTypeFor(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase();
  return MIME_BY_EXT[ext] ?? 'application/octet-stream';
}

export function resolveByteRange(
  header: string,
  total: number
): { start: number; end: number } | null {
  const match = /^bytes=(\d*)-(\d*)$/.exec(header);
  if (!match || (!match[1] && !match[2]) || total <= 0) return null;
  const suffixLength =
    !match[1] && match[2] ? Number.parseInt(match[2], 10) : null;
  const start =
    suffixLength !== null
      ? Math.max(0, total - suffixLength)
      : Number.parseInt(match[1]!, 10);
  const requestedEnd =
    suffixLength !== null || !match[2]
      ? total - 1
      : Number.parseInt(match[2], 10);
  const end = Math.min(requestedEnd, total - 1);
  if (
    Number.isNaN(start) ||
    Number.isNaN(end) ||
    suffixLength === 0 ||
    start < 0 ||
    start >= total ||
    end < start
  ) {
    return null;
  }
  return { start, end };
}

function pipeMediaFile(
  filePath: string,
  res: ServerResponse,
  range?: { start: number; end: number }
): void {
  const stream = createReadStream(filePath, range);
  stream.on('error', (error) => {
    if (!res.headersSent) {
      sendJson(res, 500, {
        error: 'MEDIA_READ_FAILED',
        message: 'Media file could not be read'
      });
    } else {
      res.destroy(error);
    }
  });
  res.on('close', () => stream.destroy());
  stream.pipe(res);
}

function resolveSafeMediaPath(workDir: string, relativePath: string): string | null {
  if (
    !relativePath ||
    relativePath.includes('\0') ||
    path.isAbsolute(relativePath) ||
    relativePath.split(/[\\/]/).some((part) => part === '..')
  ) {
    return null;
  }
  const resolved = path.resolve(workDir, relativePath);
  const root = path.resolve(workDir);
  if (resolved !== root && !resolved.startsWith(root + path.sep)) {
    return null;
  }
  return resolved;
}

async function sendFileWithRange(
  req: IncomingMessage,
  res: ServerResponse,
  filePath: string
): Promise<void> {
  const info = await stat(filePath);
  if (!info.isFile()) {
    sendJson(res, 404, { error: 'NOT_FOUND', message: 'Media file not found' });
    return;
  }

  const total = info.size;
  const contentType = contentTypeFor(filePath);
  const range = req.headers.range;

  if (range) {
    const resolvedRange = resolveByteRange(range, total);
    if (!resolvedRange) {
      res.statusCode = 416;
      res.setHeader('Content-Range', `bytes */${total}`);
      res.end();
      return;
    }
    const { start, end } = resolvedRange;

    res.statusCode = 206;
    res.setHeader('Content-Type', contentType);
    res.setHeader('Accept-Ranges', 'bytes');
    res.setHeader('Content-Range', `bytes ${start}-${end}/${total}`);
    res.setHeader('Content-Length', end - start + 1);
    pipeMediaFile(filePath, res, { start, end });
    return;
  }

  res.statusCode = 200;
  res.setHeader('Content-Type', contentType);
  res.setHeader('Accept-Ranges', 'bytes');
  res.setHeader('Content-Length', total);
  pipeMediaFile(filePath, res);
}

export async function handleMedia(
  req: IncomingMessage,
  res: ServerResponse,
  config: ServiceConfig,
  store: JobStore
): Promise<boolean> {
  const url = parseUrl(req);
  const match = MEDIA_RE.exec(url.pathname);
  if (!match || (req.method !== 'GET' && req.method !== 'HEAD')) return false;

  if (config.requireMediaAuth) {
    if (!requireBearer(req, res, config.bearerToken)) return true;
  }

  const jobId = match[1]!;
  const relativePath = decodeURIComponent(match[2]!);
  const job = store.get(jobId);
  if (!job) {
    sendJson(res, 404, { error: 'JOB_NOT_FOUND', message: 'Unknown job' });
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

  const filePath = resolveSafeMediaPath(job.workDir, relativePath);
  if (!filePath) {
    sendJson(res, 400, {
      error: 'INVALID_PATH',
      message: 'Invalid media path'
    });
    return true;
  }

  try {
    // Ensure file exists before streaming.
    await open(filePath, 'r').then((handle) => handle.close());
  } catch {
    sendJson(res, 404, { error: 'NOT_FOUND', message: 'Media file not found' });
    return true;
  }

  if (req.method === 'HEAD') {
    const info = await stat(filePath);
    res.statusCode = 200;
    res.setHeader('Content-Type', contentTypeFor(filePath));
    res.setHeader('Accept-Ranges', 'bytes');
    res.setHeader('Content-Length', info.size);
    res.end();
    return true;
  }

  await sendFileWithRange(req, res, filePath);
  return true;
}

export { resolveSafeMediaPath };
