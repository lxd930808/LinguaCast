import type { IncomingMessage, ServerResponse } from 'node:http';

import { DomainError, publicErrorFields } from '../../domain/types.js';
import { sendError } from '../http-utils.js';
import type { V2AssistantApplication } from './application.js';

const TERMINAL = new Set(['turn.completed', 'turn.failed', 'turn.cancelled']);

export async function writeV2Sse(
  req: IncomingMessage,
  res: ServerResponse,
  app: V2AssistantApplication,
  owner: string,
  turnId: string,
  traceId: string
): Promise<void> {
  const last = typeof req.headers['last-event-id'] === 'string' ? req.headers['last-event-id'] : undefined;
  let replay;
  try {
    replay = app.eventsSince(owner, turnId, last);
  } catch (error) {
    if (error instanceof DomainError) {
      sendError(res, error.httpStatus, publicErrorFields(error), traceId);
      return;
    }
    throw error;
  }
  if (replay.expired) {
    sendError(
      res,
      409,
      { code: 'EVENT_CURSOR_EXPIRED', message: 'Last-Event-ID is older than the retained event window', retryable: false },
      traceId
    );
    return;
  }
  res.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-cache, no-transform',
    connection: 'keep-alive',
    'x-accel-buffering': 'no'
  });
  for (const event of replay.events) {
    writeFrame(res, event);
  }
  let lastId = replay.events.at(-1)?.eventId ?? (last ? Number(last) : 0);
  if (replay.events.some((event) => TERMINAL.has(event.type))) {
    res.end();
    return;
  }

  await new Promise<void>((resolve) => {
    const heartbeat = setInterval(() => {
      res.write(`event: heartbeat\ndata: ${JSON.stringify({ t: new Date().toISOString() })}\n\n`);
    }, 15_000);
    const poll = setInterval(() => {
      try {
        const more = app.eventsSince(owner, turnId, String(lastId));
        if (more.expired) {
          cleanup();
          resolve();
          return;
        }
        for (const event of more.events) {
          writeFrame(res, event);
          lastId = event.eventId;
          if (TERMINAL.has(event.type)) {
            cleanup();
            res.end();
            resolve();
            return;
          }
        }
      } catch {
        cleanup();
        resolve();
      }
    }, 200);
    const cleanup = () => {
      clearInterval(heartbeat);
      clearInterval(poll);
      req.off('close', onClose);
    };
    const onClose = () => {
      cleanup();
      resolve();
    };
    req.on('close', onClose);
  });
}

function writeFrame(
  res: ServerResponse,
  event: {
    eventId: number;
    sequence: number;
    researchId: string;
    turnId: string;
    type: string;
    occurredAt: string;
    payload: unknown;
  }
): void {
  res.write(`id: ${event.eventId}\n`);
  res.write(`event: ${event.type}\n`);
  res.write(
    `data: ${JSON.stringify({
      schemaVersion: 2,
      eventId: event.eventId,
      sequence: event.sequence,
      researchId: event.researchId,
      turnId: event.turnId,
      type: event.type,
      occurredAt: event.occurredAt,
      payload: event.payload
    })}\n\n`
  );
}
