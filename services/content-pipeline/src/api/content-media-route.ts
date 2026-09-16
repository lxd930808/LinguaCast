import type { IncomingMessage, ServerResponse } from 'node:http';

import type { VideoMediaTaskStore } from '../domain/video-media-task-store.js';
import type { ServiceConfig } from '../config.js';
import { ContentMediaStore } from '../domain/content-media-store.js';
import type { JobStore } from '../jobs/job-store.js';
import type { KeyLayout } from '../storage/keys.js';
import type { ObjectStore } from '../storage/object-store.js';
import { authenticate } from './auth.js';
import type { IdentityResolver } from '../auth/identity.js';
import {
  attachRequestContext,
  parseUrl,
  readJsonBody,
  sendError,
  sendJson
} from './http-utils.js';

const PLAYBACK_PATH = '/v1/content-media/video-playback-url';
const VIDEO_KEY_RE = /^video:youtube:[A-Za-z0-9_-]+$/;

export interface ContentMediaRouteDeps {
  config: ServiceConfig;
  store: JobStore;
  mediaStore: ContentMediaStore;
  objects: ObjectStore;
  keys: KeyLayout;
  mediaTasks?: VideoMediaTaskStore;
  identity?: IdentityResolver;
}

export async function handleContentMediaRoutes(
  req: IncomingMessage,
  res: ServerResponse,
  deps: ContentMediaRouteDeps
): Promise<boolean> {
  const url = parseUrl(req);
  if (!url.pathname.startsWith('/v1/content-media')) return false;

  const { traceId } = attachRequestContext(res);
  const caller = await authenticate(req, res, deps, traceId);
  if (!caller) return true;
  const owner = caller.identity.accountId;

  if (req.method === 'POST' && ['/v1/content-media/video-status','/v1/content-media/video-retry'].includes(url.pathname)) {
    await videoStatus(req,res,deps,owner,traceId,url.pathname.endsWith('/video-retry'));
    return true;
  }
  if (url.pathname === PLAYBACK_PATH && req.method === 'POST') {
    await issueVideoPlaybackUrl(req, res, deps, owner, traceId);
    return true;
  }
  sendError(
    res,
    404,
    { code: 'MEDIA_NOT_FOUND', message: `No route for ${req.method} ${url.pathname}`, retryable: false },
    traceId
  );
  return true;
}

async function issueVideoPlaybackUrl(
  req: IncomingMessage,
  res: ServerResponse,
  deps: ContentMediaRouteDeps,
  owner: string,
  traceId: string
): Promise<void> {
  const body = (await readJsonBody(req, deps.config.maxBodyBytes)) as Record<string, unknown>;
  const contentType = body.contentType;
  const contentKey = body.contentKey;
  const preferredHeight = body.preferredHeight;

  if (contentType !== 'video') {
    sendError(
      res,
      400,
      {
        code: 'INVALID_REQUEST',
        message: 'contentType must be video',
        retryable: false,
        params: { field: 'contentType' }
      },
      traceId
    );
    return;
  }
  if (typeof contentKey !== 'string' || !VIDEO_KEY_RE.test(contentKey)) {
    sendError(
      res,
      400,
      {
        code: 'INVALID_REQUEST',
        message: 'contentKey must be a video:youtube:<id> key',
        retryable: false,
        params: { field: 'contentKey' }
      },
      traceId
    );
    return;
  }
  if (preferredHeight !== undefined) {
    if (
      typeof preferredHeight !== 'number' ||
      !Number.isInteger(preferredHeight) ||
      preferredHeight < 144 ||
      preferredHeight > 4320
    ) {
      sendError(
        res,
        400,
        {
          code: 'INVALID_REQUEST',
          message: 'preferredHeight must be an integer between 144 and 4320',
          retryable: false,
          params: { field: 'preferredHeight' }
        },
        traceId
      );
      return;
    }
  }

  const asset = deps.mediaStore.currentReadyForContent(owner, 'video', contentKey);
  if (!asset || !asset.objectKey) {
    const promoting = deps.mediaStore.promotingForContent(owner, 'video', contentKey);
    const active = deps.mediaStore.hasActiveJobForContent(owner, 'video', contentKey);
    const contentId=deps.mediaStore.contentIdForOwner(owner,'video',contentKey);
    if (promoting || active || (contentId !== null && deps.mediaTasks?.active(contentId))) {
      sendError(
        res,
        409,
        {
          code: 'MEDIA_NOT_READY',
          message: 'video media is still being promoted',
          retryable: true,
          retryAfterSeconds: 8
        },
        traceId
      );
      return;
    }
    sendError(
      res,
      404,
      { code: 'MEDIA_NOT_FOUND', message: 'no ready video media for contentKey', retryable: false },
      traceId
    );
    return;
  }

  deps.keys.assertAllowed(asset.objectKey);
  const head = await deps.objects.head(asset.objectKey);
  if (!head || (asset.bytes !== null && head.bytes !== asset.bytes)) {
    deps.mediaStore.markInvalid(asset.mediaId, 'MEDIA_INTEGRITY_FAILED');
    sendError(
      res,
      409,
      {
        code: 'MEDIA_INTEGRITY_FAILED',
        message: 'registered video object failed HEAD verification',
        retryable: false
      },
      traceId
    );
    return;
  }

  const url = await deps.objects.presignGet(asset.objectKey, deps.config.r2.signedUrlTtlSeconds);
  const now = Date.now();
  const retainUntil = now + deps.config.videoMediaRetentionDays * 86_400_000;
  deps.mediaStore.touchAccess(asset.mediaId, retainUntil, now);
  const expiresAt = new Date(now + deps.config.r2.signedUrlTtlSeconds * 1000).toISOString();
  sendJson(res, 200, {
    schemaVersion: 1,
    mediaId: asset.mediaId,
    contentType: 'video',
    contentKey,
    url,
    expiresAt,
    mimeType: asset.mimeType ?? 'video/mp4',
    bytes: asset.bytes ?? head.bytes,
    sha256: asset.sha256,
    durationSeconds: asset.durationSeconds,
    height: asset.height,
    videoCodec: asset.videoCodec,
    audioCodec: asset.audioCodec,
    acceptRanges: 'bytes',
    mediaVersion: asset.renditionKey,
    createdAt: new Date(asset.createdAt).toISOString()
  });
  void preferredHeight;
}


async function videoStatus(req: IncomingMessage,res: ServerResponse,deps: ContentMediaRouteDeps,owner: string,traceId: string,retry: boolean): Promise<void> {
  const body=await readJsonBody(req,deps.config.maxBodyBytes) as Record<string,unknown>;
  if(body.contentType!=='video'||typeof body.contentKey!=='string'||!VIDEO_KEY_RE.test(body.contentKey)) {
    sendError(res,400,{code:'INVALID_REQUEST',message:'Expected video contentType and YouTube contentKey',retryable:false},traceId);return;
  }
  const contentKey=body.contentKey;
  const id=deps.mediaStore.contentIdForOwner(owner,'video',contentKey);
  let asset=deps.mediaStore.currentReadyForContent(owner,'video',contentKey);
  if(asset?.objectKey) {
    const head=await deps.objects.head(asset.objectKey);
    if(!head||head.bytes!==asset.bytes) {deps.mediaStore.markInvalid(asset.mediaId,'MEDIA_INTEGRITY_FAILED');asset=null;}
  }
  if(retry && !asset) {
    if(!deps.config.videoMediaPromotionEnabled || !deps.mediaTasks) {
      sendError(res,409,{code:'MEDIA_DISABLED',message:'Video saving is disabled',retryable:false},traceId);return;
    }
    const jobId=id===null?null:deps.mediaTasks.latestJobId(id);
    if(id===null||!jobId) {
      sendError(res,404,{code:'MEDIA_NOT_FOUND',message:'Generate subtitles before saving this video',retryable:false},traceId);return;
    }
    deps.mediaTasks.enqueue(id,jobId);
  }
  const task=id===null?null:deps.mediaTasks?.get(id);
  const state=asset?'ready':task?.state==='ready'?'not_saved':task?.state ?? 'not_saved';
  sendJson(res,retry&&!asset?202:200,{schemaVersion:1,contentKey,state,mediaId:asset?.mediaId ?? null,
    failureCode:task?.failure_code ?? null,attempts:task?.attempts ?? 0,
    retryAfterSeconds:state==='queued'||state==='running'?8:null});
}
