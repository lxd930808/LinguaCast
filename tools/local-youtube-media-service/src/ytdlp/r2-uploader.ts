import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { createHmac, createHash } from 'node:crypto';
import path from 'node:path';

export interface R2Config {
  accountId: string;
  accessKeyId: string;
  secretAccessKey: string;
  bucket: string;
  publicBaseUrl?: string | null;
  keyPrefix: string;
  signedUrlTtlSeconds: number;
}

export interface R2UploadResult {
  key: string;
  url: string;
  bytes: number;
}

function encodeRfc3986(value: string): string {
  return encodeURIComponent(value).replace(/[!'()*]/g, (char) =>
    `%${char.charCodeAt(0).toString(16).toUpperCase()}`
  );
}

function hmac(key: Buffer | string, data: string): Buffer {
  return createHmac('sha256', key).update(data, 'utf8').digest();
}

function sha256Hex(data: Buffer | string): string {
  return createHash('sha256').update(data).digest('hex');
}

function amzDate(date: Date): { amzDate: string; dateStamp: string } {
  const iso = date.toISOString().replace(/[:-]|\.\d{3}/g, '');
  return {
    amzDate: iso,
    dateStamp: iso.slice(0, 8)
  };
}

function endpointFor(accountId: string): string {
  return `https://${accountId}.r2.cloudflarestorage.com`;
}

async function signedRequest(options: {
  config: R2Config;
  method: string;
  key: string;
  headers?: Record<string, string>;
  body?: Buffer | NodeJS.ReadableStream | null;
  query?: Record<string, string>;
  unsignedPayload?: boolean;
}): Promise<Response> {
  const { config, method, key, headers = {}, body = null, query = {}, unsignedPayload } =
    options;
  const host = `${config.accountId}.r2.cloudflarestorage.com`;
  const now = new Date();
  const { amzDate: amz, dateStamp } = amzDate(now);
  const region = 'auto';
  const service = 's3';
  const canonicalUri = `/${config.bucket}/${key.split('/').map(encodeRfc3986).join('/')}`;
  const queryEntries = Object.entries(query)
    .map(([k, v]) => [encodeRfc3986(k), encodeRfc3986(v)] as const)
    .sort(([a], [b]) => a.localeCompare(b));
  const canonicalQuery = queryEntries.map(([k, v]) => `${k}=${v}`).join('&');

  const payloadHash = unsignedPayload
    ? 'UNSIGNED-PAYLOAD'
    : body && Buffer.isBuffer(body)
      ? sha256Hex(body)
      : sha256Hex('');

  const baseHeaders: Record<string, string> = {
    host,
    'x-amz-content-sha256': payloadHash,
    'x-amz-date': amz,
    ...headers
  };
  const signedHeaderNames = Object.keys(baseHeaders)
    .map((name) => name.toLowerCase())
    .sort();
  const canonicalHeaders = signedHeaderNames
    .map((name) => `${name}:${baseHeaders[name]!.trim()}\n`)
    .join('');
  const signedHeaders = signedHeaderNames.join(';');
  const canonicalRequest = [
    method,
    canonicalUri,
    canonicalQuery,
    canonicalHeaders,
    signedHeaders,
    payloadHash
  ].join('\n');

  const credentialScope = `${dateStamp}/${region}/${service}/aws4_request`;
  const stringToSign = [
    'AWS4-HMAC-SHA256',
    amz,
    credentialScope,
    sha256Hex(canonicalRequest)
  ].join('\n');

  const kDate = hmac(`AWS4${config.secretAccessKey}`, dateStamp);
  const kRegion = hmac(kDate, region);
  const kService = hmac(kRegion, service);
  const kSigning = hmac(kService, 'aws4_request');
  const signature = createHmac('sha256', kSigning)
    .update(stringToSign, 'utf8')
    .digest('hex');

  const authorization = `AWS4-HMAC-SHA256 Credential=${config.accessKeyId}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;

  const url = `${endpointFor(config.accountId)}${canonicalUri}${
    canonicalQuery ? `?${canonicalQuery}` : ''
  }`;

  return fetch(url, {
    method,
    headers: {
      ...baseHeaders,
      Authorization: authorization
    },
    body: body as BodyInit | null,
    // @ts-expect-error Node fetch duplex for streaming body
    duplex: body && !Buffer.isBuffer(body) ? 'half' : undefined
  });
}

export async function uploadFileToR2(options: {
  config: R2Config;
  localPath: string;
  key: string;
  contentType: string;
}): Promise<R2UploadResult> {
  const { config, localPath, key, contentType } = options;
  const info = await stat(localPath);
  const stream = createReadStream(localPath);
  const response = await signedRequest({
    config,
    method: 'PUT',
    key,
    headers: {
      'content-type': contentType,
      'content-length': String(info.size)
    },
    body: stream,
    unsignedPayload: true
  });
  if (!response.ok) {
    const text = await response.text().catch(() => '');
    throw new Error(`R2 upload failed HTTP ${response.status}: ${text.slice(0, 500)}`);
  }
  const url = await presignGetUrl({
    config,
    key,
    expiresInSeconds: config.signedUrlTtlSeconds
  });
  return { key, url, bytes: info.size };
}

export async function deleteR2Object(config: R2Config, key: string): Promise<void> {
  const response = await signedRequest({
    config,
    method: 'DELETE',
    key
  });
  if (!response.ok && response.status !== 404) {
    const text = await response.text().catch(() => '');
    throw new Error(`R2 delete failed HTTP ${response.status}: ${text.slice(0, 500)}`);
  }
}

export async function presignGetUrl(options: {
  config: R2Config;
  key: string;
  expiresInSeconds: number;
}): Promise<string> {
  const { config, key, expiresInSeconds } = options;
  if (config.publicBaseUrl) {
    const base = config.publicBaseUrl.replace(/\/$/, '');
    return `${base}/${key.split('/').map(encodeURIComponent).join('/')}`;
  }

  const host = `${config.accountId}.r2.cloudflarestorage.com`;
  const now = new Date();
  const { amzDate: amz, dateStamp } = amzDate(now);
  const region = 'auto';
  const service = 's3';
  const credentialScope = `${dateStamp}/${region}/${service}/aws4_request`;
  const credential = `${config.accessKeyId}/${credentialScope}`;
  const canonicalUri = `/${config.bucket}/${key.split('/').map(encodeRfc3986).join('/')}`;
  const query: Record<string, string> = {
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': credential,
    'X-Amz-Date': amz,
    'X-Amz-Expires': String(expiresInSeconds),
    'X-Amz-SignedHeaders': 'host'
  };
  const canonicalQuery = Object.entries(query)
    .map(([k, v]) => `${encodeRfc3986(k)}=${encodeRfc3986(v)}`)
    .sort()
    .join('&');
  const canonicalRequest = [
    'GET',
    canonicalUri,
    canonicalQuery,
    `host:${host}\n`,
    'host',
    'UNSIGNED-PAYLOAD'
  ].join('\n');
  const stringToSign = [
    'AWS4-HMAC-SHA256',
    amz,
    credentialScope,
    sha256Hex(canonicalRequest)
  ].join('\n');
  const kDate = hmac(`AWS4${config.secretAccessKey}`, dateStamp);
  const kRegion = hmac(kDate, region);
  const kService = hmac(kRegion, service);
  const kSigning = hmac(kService, 'aws4_request');
  const signature = createHmac('sha256', kSigning)
    .update(stringToSign, 'utf8')
    .digest('hex');
  return `https://${host}${canonicalUri}?${canonicalQuery}&X-Amz-Signature=${signature}`;
}

export function mediaObjectKey(
  prefix: string,
  jobId: string,
  fileName: string
): string {
  const cleanPrefix = prefix.replace(/^\/+|\/+$/g, '');
  return `${cleanPrefix}/${jobId}/${path.basename(fileName)}`;
}
