import type { R2Config } from '../config.js';
import {
  ObjectStoreError,
  type ObjectMeta,
  type ObjectStore
} from './object-store.js';
import { presignGetUrl, signRequest } from './sigv4.js';

/**
 * Cloudflare R2 object store over HTTPS with SigV4 auth. Only object-level
 * operations on the configured bucket; never touches other prefixes beyond
 * what callers pass in (callers enforce the content-pipeline prefix).
 */
export class R2ObjectStore implements ObjectStore {
  private readonly host: string;

  constructor(private readonly config: R2Config) {
    this.host = `${config.accountId}.r2.cloudflarestorage.com`;
  }

  private pathFor(key: string): string {
    return `/${this.config.bucket}/${key.split('/').map(encodeURIComponent).join('/')}`;
  }

  private async request(
    method: string,
    key: string,
    options: { body?: Buffer; headers?: Record<string, string>; query?: Record<string, string> } = {}
  ): Promise<Response> {
    const headers = signRequest({
      method,
      host: this.host,
      path: this.pathFor(key),
      query: options.query,
      // identity is mandatory: the Cloudflare edge otherwise negotiates gzip
      // on compressible types, which strips content-length from HEAD (weak
      // etag) and breaks byte verification and range reads.
      headers: { 'accept-encoding': 'identity', ...options.headers },
      payload: options.body ?? Buffer.alloc(0),
      credentials: {
        accessKeyId: this.config.accessKeyId,
        secretAccessKey: this.config.secretAccessKey
      }
    });
    const query = options.query
      ? '?' +
        Object.entries(options.query)
          .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
          .join('&')
      : '';
    const res = await fetch(`https://${this.host}${this.pathFor(key)}${query}`, {
      method,
      headers,
      body: options.body
    });
    return res;
  }

  async put(key: string, data: Buffer, contentType: string): Promise<ObjectMeta> {
    const res = await this.request('PUT', key, {
      body: data,
      headers: { 'content-type': contentType }
    });
    if (!res.ok) throw new ObjectStoreError('REMOTE', `R2 PUT failed: HTTP ${res.status}`);
    return { key, bytes: data.length, etag: res.headers.get('etag') ?? '', contentType };
  }

  async putStream(
    key: string,
    stream: NodeJS.ReadableStream,
    bytes: number,
    contentType: string
  ): Promise<ObjectMeta> {
    // Unsigned payload keeps memory flat for large media over TLS.
    const headers = signRequest({
      method: 'PUT',
      host: this.host,
      path: this.pathFor(key),
      payload: 'UNSIGNED',
      headers: {
        // See request(): identity keeps HEAD/range semantics accurate.
        'accept-encoding': 'identity',
        'content-type': contentType,
        'content-length': String(bytes)
      },
      credentials: {
        accessKeyId: this.config.accessKeyId,
        secretAccessKey: this.config.secretAccessKey
      }
    });
    const res = await fetch(`https://${this.host}${this.pathFor(key)}`, {
      method: 'PUT',
      headers,
      // Node fetch accepts a Node Readable; duplex is required for streams.
      body: stream,
      duplex: 'half'
    } as unknown as RequestInit);
    if (!res.ok) throw new ObjectStoreError('REMOTE', `R2 streaming PUT failed: HTTP ${res.status}`);
    return { key, bytes, etag: res.headers.get('etag') ?? '', contentType };
  }

  async head(key: string): Promise<ObjectMeta | null> {
    const res = await this.request('HEAD', key);
    if (res.status === 404) return null;
    if (!res.ok) throw new ObjectStoreError('REMOTE', `R2 HEAD failed: HTTP ${res.status}`);
    return {
      key,
      bytes: Number(res.headers.get('content-length') ?? 0),
      etag: res.headers.get('etag') ?? '',
      contentType: res.headers.get('content-type') ?? undefined
    };
  }

  async getRange(key: string, start?: number, end?: number): Promise<Buffer> {
    const headers: Record<string, string> = {};
    if (start !== undefined) {
      headers['range'] = `bytes=${start}-${end ?? ''}`;
    }
    const res = await this.request('GET', key, { headers });
    if (res.status === 404) throw new ObjectStoreError('NOT_FOUND', `object not found: ${key}`);
    if (start !== undefined && res.status === 416) {
      throw new ObjectStoreError('INVALID_RANGE', `invalid range ${start}-${end ?? ''}`);
    }
    if (!res.ok && res.status !== 206) {
      throw new ObjectStoreError('REMOTE', `R2 GET failed: HTTP ${res.status}`);
    }
    return Buffer.from(await res.arrayBuffer());
  }

  async delete(key: string): Promise<void> {
    const res = await this.request('DELETE', key);
    if (!res.ok && res.status !== 404) {
      throw new ObjectStoreError('REMOTE', `R2 DELETE failed: HTTP ${res.status}`);
    }
  }

  async copy(sourceKey: string, targetKey: string): Promise<ObjectMeta> {
    const res = await this.request('PUT', targetKey, {
      headers: {
        'x-amz-copy-source': `/${this.config.bucket}/${sourceKey}`
      }
    });
    if (!res.ok) throw new ObjectStoreError('REMOTE', `R2 COPY failed: HTTP ${res.status}`);
    const head = await this.head(targetKey);
    if (!head) throw new ObjectStoreError('REMOTE', 'R2 COPY succeeded but target missing');
    return head;
  }

  async presignGet(key: string, ttlSeconds: number): Promise<string> {
    return presignGetUrl({
      host: this.host,
      path: this.pathFor(key),
      ttlSeconds,
      credentials: {
        accessKeyId: this.config.accessKeyId,
        secretAccessKey: this.config.secretAccessKey
      }
    });
  }

  async listKeys(prefix: string): Promise<string[]> {
    const keys: string[] = [];
    let continuationToken: string | undefined;
    do {
      const query: Record<string, string> = {
        'list-type': '2',
        prefix,
        'max-keys': '1000'
      };
      if (continuationToken) query['continuation-token'] = continuationToken;
      // List operates on the bucket path, not an object key.
      const headers = signRequest({
        method: 'GET',
        host: this.host,
        path: `/${this.config.bucket}`,
        query,
        payload: Buffer.alloc(0),
        credentials: {
          accessKeyId: this.config.accessKeyId,
          secretAccessKey: this.config.secretAccessKey
        }
      });
      const queryString = Object.entries(query)
        .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
        .join('&');
      const res = await fetch(`https://${this.host}/${this.config.bucket}?${queryString}`, { headers });
      if (!res.ok) throw new ObjectStoreError('REMOTE', `R2 LIST failed: HTTP ${res.status}`);
      const xml = await res.text();
      for (const match of xml.matchAll(/<Key>([^<]+)<\/Key>/g)) {
        keys.push(match[1]!);
      }
      const truncated = /<IsTruncated>true<\/IsTruncated>/.test(xml);
      continuationToken = truncated
        ? /<NextContinuationToken>([^<]+)<\/NextContinuationToken>/.exec(xml)?.[1]
        : undefined;
    } while (continuationToken);
    return keys;
  }
}
