import { randomUUID } from 'node:crypto';
import type { IncomingMessage, ServerResponse } from 'node:http';

import { AccountError } from '../domain/errors.js';

export const ACCOUNT_CONTEXT_HEADER = 'x-linguacast-account-context';

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
    'cache-control': 'no-store',
    ...headers
  });
  res.end(payload);
}

export function sendNoContent(res: ServerResponse): void {
  res.writeHead(204, { 'cache-control': 'no-store' });
  res.end();
}

export interface ErrorBody {
  code: string;
  message: string;
  retryable: boolean;
  retryAfterSeconds?: number;
  params?: Record<string, unknown>;
}

export function sendError(res: ServerResponse, status: number, error: ErrorBody, traceId: string): void {
  const headers: Record<string, string> = {};
  if (error.retryAfterSeconds !== undefined) headers['retry-after'] = String(error.retryAfterSeconds);
  sendJson(res, status, { error: { ...error, traceId } }, headers);
}

export function sendAccountError(res: ServerResponse, error: AccountError, traceId: string): void {
  sendError(
    res,
    error.status,
    {
      code: error.code,
      message: error.message,
      retryable: error.retryable,
      ...(error.retryAfterSeconds !== undefined ? { retryAfterSeconds: error.retryAfterSeconds } : {}),
      ...(error.params ? { params: error.params } : {})
    },
    traceId
  );
}

export class BodyTooLargeError extends Error {}
export class InvalidContentTypeError extends Error {}

export async function readJsonObject(req: IncomingMessage, maxBytes: number): Promise<Record<string, unknown>> {
  const contentType = req.headers['content-type'] ?? '';
  if (!contentType.toLowerCase().startsWith('application/json')) {
    throw new InvalidContentTypeError('content-type must be application/json');
  }
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of req) {
    const buf = chunk as Buffer;
    total += buf.length;
    if (total > maxBytes) throw new BodyTooLargeError(`request body exceeds ${maxBytes} bytes`);
    chunks.push(buf);
  }
  const raw = Buffer.concat(chunks).toString('utf8');
  if (raw.trim() === '') return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new InvalidContentTypeError('request body is not valid JSON');
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new AccountError(400, 'INVALID_REQUEST', 'request body must be a JSON object');
  }
  return parsed as Record<string, unknown>;
}

export function bearerToken(req: IncomingMessage): string | null {
  const header = req.headers.authorization;
  if (typeof header !== 'string' || !header.startsWith('Bearer ')) return null;
  const token = header.slice('Bearer '.length).trim();
  return token === '' ? null : token;
}

export function clientAddress(req: IncomingMessage, trustProxy: boolean): string {
  if (trustProxy) {
    const forwarded = req.headers['x-forwarded-for'];
    const first = (Array.isArray(forwarded) ? forwarded[0] : forwarded)?.split(',')[0]?.trim();
    if (first) return first;
  }
  return req.socket.remoteAddress ?? 'unknown';
}
