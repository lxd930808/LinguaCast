import { randomUUID } from 'node:crypto';
import type { IncomingMessage, ServerResponse } from 'node:http';

export interface RequestContext {
  traceId: string;
}

export function newTraceId(): string {
  return `tr_${randomUUID().replace(/-/g, '').slice(0, 20)}`;
}

export function parseUrl(req: IncomingMessage): URL {
  return new URL(req.url ?? '/', 'http://127.0.0.1');
}

export function sendJson(res: ServerResponse, status: number, body: unknown, headers?: Record<string, string>): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    ...headers
  });
  res.end(payload);
}

export interface ErrorBody {
  code: string;
  message: string;
  retryable: boolean;
  retryAfterSeconds?: number;
  traceId: string;
  params?: Record<string, unknown>;
}

export function sendError(
  res: ServerResponse,
  status: number,
  error: Omit<ErrorBody, 'traceId'>,
  traceId: string,
  headers?: Record<string, string>
): void {
  sendJson(res, status, { error: { ...error, traceId } }, headers);
}

export class BodyTooLargeError extends Error {}
export class InvalidContentTypeError extends Error {}

export async function readJsonBody(req: IncomingMessage, maxBytes: number): Promise<unknown> {
  const contentType = req.headers['content-type'] ?? '';
  if (!contentType.toLowerCase().startsWith('application/json')) {
    throw new InvalidContentTypeError('content-type must be application/json');
  }
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of req) {
    const buf = chunk as Buffer;
    total += buf.length;
    if (total > maxBytes) {
      throw new BodyTooLargeError(`request body exceeds ${maxBytes} bytes`);
    }
    chunks.push(buf);
  }
  const raw = Buffer.concat(chunks).toString('utf8');
  if (raw.trim() === '') return {};
  try {
    return JSON.parse(raw);
  } catch {
    throw new InvalidContentTypeError('request body is not valid JSON');
  }
}

export function attachRequestContext(req: IncomingMessage, res: ServerResponse): RequestContext {
  const incoming = req.headers['x-request-id'];
  const traceId =
    typeof incoming === 'string' && incoming.startsWith('tr_') ? incoming.slice(0, 40) : newTraceId();
  res.setHeader('x-trace-id', traceId);
  return { traceId };
}

export function idempotencyKey(req: IncomingMessage): string | undefined {
  const value = req.headers['idempotency-key'];
  if (typeof value !== 'string' || value.trim() === '') return undefined;
  return value.trim().slice(0, 128);
}
