import type { IncomingMessage, ServerResponse } from 'node:http';

export function unauthorized(res: ServerResponse, message = 'Unauthorized'): void {
  res.statusCode = 401;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.end(JSON.stringify({ error: 'UNAUTHORIZED', message }));
}

export function requireBearer(
  req: IncomingMessage,
  res: ServerResponse,
  token: string
): boolean {
  const header = req.headers.authorization;
  if (header?.startsWith('Bearer ')) {
    const provided = header.slice('Bearer '.length).trim();
    if (provided && provided === token) return true;
  }

  try {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const queryToken = url.searchParams.get('access_token');
    if (queryToken && queryToken === token) return true;
  } catch {
    // ignore
  }

  unauthorized(res, 'Missing or invalid Bearer token');
  return false;
}
