import { createHash, createHmac } from 'node:crypto';

/**
 * Minimal AWS SigV4 signer for Cloudflare R2 (S3-compatible). Implemented
 * with node:crypto only — no SDK — to keep the 2 GB host image lean.
 */

export interface SigV4Credentials {
  accessKeyId: string;
  secretAccessKey: string;
}

const SERVICE = 's3';
const REGION = 'auto'; // R2 convention

function hmac(key: Buffer | string, data: string): Buffer {
  return createHmac('sha256', key).update(data, 'utf8').digest();
}

function sha256hex(data: string | Buffer): string {
  return createHash('sha256').update(data).digest('hex');
}

function amzDate(date: Date): { amz: string; day: string } {
  const iso = date.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
  return { amz: iso, day: iso.slice(0, 8) };
}

function signingKey(secret: string, day: string): Buffer {
  const kDate = hmac(`AWS4${secret}`, day);
  const kRegion = hmac(kDate, REGION);
  const kService = hmac(kRegion, SERVICE);
  return hmac(kService, 'aws4_request');
}

function canonicalQuery(params: Record<string, string>): string {
  return Object.keys(params)
    .sort()
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(params[k]!)}`)
    .join('&');
}

export type SignedRequestHeaders = Record<string, string>;

/** Sign a direct (header-auth) request. Payload hash of `payload` or UNSIGNED for streams. */
export function signRequest(options: {
  method: string;
  host: string;
  path: string;
  query?: Record<string, string>;
  headers?: Record<string, string>;
  payload: Buffer | 'UNSIGNED';
  credentials: SigV4Credentials;
  now?: Date;
}): SignedRequestHeaders {
  const { amz, day } = amzDate(options.now ?? new Date());
  const payloadHash =
    options.payload === 'UNSIGNED' ? 'UNSIGNED-PAYLOAD' : sha256hex(options.payload);
  const headers: Record<string, string> = {
    host: options.host,
    'x-amz-content-sha256': payloadHash,
    'x-amz-date': amz,
    ...options.headers
  };
  const signedHeaderNames = Object.keys(headers).sort();
  const canonicalHeaders = signedHeaderNames.map((name) => `${name}:${headers[name]}\n`).join('');
  const canonicalRequest = [
    options.method,
    options.path,
    canonicalQuery(options.query ?? {}),
    canonicalHeaders,
    signedHeaderNames.join(';'),
    payloadHash
  ].join('\n');
  const scope = `${day}/${REGION}/${SERVICE}/aws4_request`;
  const stringToSign = ['AWS4-HMAC-SHA256', amz, scope, sha256hex(canonicalRequest)].join('\n');
  const signature = createHmac('sha256', signingKey(options.credentials.secretAccessKey, day))
    .update(stringToSign, 'utf8')
    .digest('hex');
  return {
    ...headers,
    authorization:
      `AWS4-HMAC-SHA256 Credential=${options.credentials.accessKeyId}/${scope}, ` +
      `SignedHeaders=${signedHeaderNames.join(';')}, Signature=${signature}`
  };
}

/** Presign a GET (query-string auth) for client-direct downloads. */
export function presignGetUrl(options: {
  host: string;
  path: string;
  ttlSeconds: number;
  credentials: SigV4Credentials;
  now?: Date;
}): string {
  const { amz, day } = amzDate(options.now ?? new Date());
  const scope = `${day}/${REGION}/${SERVICE}/aws4_request`;
  const query: Record<string, string> = {
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': `${options.credentials.accessKeyId}/${scope}`,
    'X-Amz-Date': amz,
    'X-Amz-Expires': String(options.ttlSeconds),
    'X-Amz-SignedHeaders': 'host'
  };
  const canonicalRequest = [
    'GET',
    options.path,
    canonicalQuery(query),
    `host:${options.host}\n`,
    'host',
    'UNSIGNED-PAYLOAD'
  ].join('\n');
  const stringToSign = ['AWS4-HMAC-SHA256', amz, scope, sha256hex(canonicalRequest)].join('\n');
  const signature = createHmac('sha256', signingKey(options.credentials.secretAccessKey, day))
    .update(stringToSign, 'utf8')
    .digest('hex');
  return `https://${options.host}${options.path}?${canonicalQuery(query)}&X-Amz-Signature=${signature}`;
}
