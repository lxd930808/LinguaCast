import type { IncomingMessage, ServerResponse } from 'node:http';

import { DomainError, publicErrorFields } from '../../domain/types.js';
import { idempotencyKey, parseUrl, readJsonBody, sendError, sendJson } from '../http-utils.js';
import type { ServiceConfig } from '../../config/index.js';
import type { V2AssistantApplication } from './application.js';
import { writeV2Sse } from './sse.js';

export async function handleV2Api(
  req: IncomingMessage,
  res: ServerResponse,
  app: V2AssistantApplication,
  config: ServiceConfig,
  traceId: string,
  owner: string
): Promise<boolean> {
  const url = parseUrl(req);
  const path = url.pathname;
  if (!path.startsWith('/v2/assistant/')) return false;

  try {
    if (req.method === 'POST' && path === '/v2/assistant/researches') {
      const body = (await readJsonBody(req, config.maxBodyBytes)) as Record<string, unknown>;
      sendJson(res, 201, app.createResearch(owner, body, idempotencyKey(req)));
      return true;
    }
    if (req.method === 'GET' && path === '/v2/assistant/researches') {
      sendJson(res, 200, app.listResearches(owner, url.searchParams.get('limit'), url.searchParams.get('cursor')));
      return true;
    }

    const researchMatch = path.match(/^\/v2\/assistant\/researches\/([^/]+)$/);
    if (researchMatch && req.method === 'GET') {
      sendJson(res, 200, app.getSnapshot(owner, researchMatch[1]));
      return true;
    }
    if (researchMatch && req.method === 'DELETE') {
      const result = app.deleteResearch(owner, researchMatch[1], idempotencyKey(req));
      if (result.status === 204) {
        res.writeHead(204);
        res.end();
      } else {
        sendJson(res, 202, result.body);
      }
      return true;
    }

    const turnsMatch = path.match(/^\/v2\/assistant\/researches\/([^/]+)\/turns$/);
    if (turnsMatch && req.method === 'POST') {
      const body = (await readJsonBody(req, config.maxBodyBytes)) as Record<string, unknown>;
      sendJson(res, 202, await app.createTurn(owner, turnsMatch[1], body, idempotencyKey(req)));
      return true;
    }

    const eventsMatch = path.match(/^\/v2\/assistant\/turns\/([^/]+)\/events$/);
    if (eventsMatch && req.method === 'GET') {
      await writeV2Sse(req, res, app, owner, eventsMatch[1], traceId);
      return true;
    }

    const cancelMatch = path.match(/^\/v2\/assistant\/turns\/([^/]+)\/cancel$/);
    if (cancelMatch && req.method === 'POST') {
      sendJson(res, 200, app.cancelTurn(owner, cancelMatch[1], idempotencyKey(req)));
      return true;
    }

    const artifactsMatch = path.match(/^\/v2\/assistant\/researches\/([^/]+)\/artifacts$/);
    if (artifactsMatch && req.method === 'GET') {
      sendJson(res, 200, app.listArtifacts(owner, artifactsMatch[1], url.searchParams));
      return true;
    }

    const artifactMatch = path.match(/^\/v2\/assistant\/researches\/([^/]+)\/artifacts\/([^/]+)$/);
    if (artifactMatch && req.method === 'GET') {
      sendJson(res, 200, app.getArtifactBody(owner, artifactMatch[1], artifactMatch[2], url.searchParams));
      return true;
    }

    const transcriptionMatch = path.match(
      /^\/v2\/assistant\/researches\/([^/]+)\/sources\/([^/]+)\/transcription$/
    );
    if (transcriptionMatch && req.method === 'POST') {
      const body = (await readJsonBody(req, config.maxBodyBytes)) as Record<string, unknown>;
      sendJson(
        res,
        202,
        await app.createTranscription(owner, transcriptionMatch[1], transcriptionMatch[2], body, idempotencyKey(req))
      );
      return true;
    }

    const transcriptListMatch = path.match(/^\/v2\/assistant\/researches\/([^/]+)\/transcriptions$/);
    if (transcriptListMatch && req.method === 'GET') {
      sendJson(res, 200, app.listTranscriptions(owner, transcriptListMatch[1]));
      return true;
    }

    const transcriptJobMatch = path.match(/^\/v2\/assistant\/researches\/([^/]+)\/transcriptions\/([^/]+)$/);
    if (transcriptJobMatch && req.method === 'GET') {
      sendJson(res, 200, app.getTranscription(owner, transcriptJobMatch[1], transcriptJobMatch[2]));
      return true;
    }

    const memoryMatch = path.match(/^\/v2\/assistant\/researches\/([^/]+)\/memory$/);
    if (memoryMatch && req.method === 'GET') {
      sendJson(res, 200, app.getMemory(owner, memoryMatch[1]));
      return true;
    }

    const confirmMatch = path.match(/^\/v2\/assistant\/memory-proposals\/([^/]+)\/confirm$/);
    if (confirmMatch && req.method === 'POST') {
      sendJson(res, 200, app.confirmMemoryProposal(owner, confirmMatch[1], idempotencyKey(req)));
      return true;
    }

    const rejectMatch = path.match(/^\/v2\/assistant\/memory-proposals\/([^/]+)\/reject$/);
    if (rejectMatch && req.method === 'POST') {
      sendJson(res, 200, app.rejectMemoryProposal(owner, rejectMatch[1], idempotencyKey(req)));
      return true;
    }

    sendError(
      res,
      404,
      { code: 'RESEARCH_NOT_FOUND', message: `No route for ${req.method} ${path}`, retryable: false },
      traceId
    );
    return true;
  } catch (error) {
    if (error instanceof DomainError) {
      sendError(res, error.httpStatus, publicErrorFields(error), traceId);
      return true;
    }
    throw error;
  }
}
