/**
 * WP15 Step 1 fake object storage: an in-memory ObjectStore whose presigned
 * URLs point at a local HTTP server. The server enforces the embedded expiry
 * (with an injectable clock skew for the signed-URL-expiry scenario) and
 * honours Range requests, so the suite exercises the same semantics as R2
 * presigned GETs without SigV4 (that path is covered separately by
 * scripts/r2-canary.ts against real R2).
 */

import { createServer, type Server } from 'node:http';

import {
  ObjectStoreError,
  type ObjectMeta,
  type ObjectStore
} from '../../src/storage/object-store.js';

export class FakeS3ObjectStore implements ObjectStore {
  /** Next N put/putStream calls fail with a REMOTE error. */
  failNextPuts = 0;
  /** Added to the server's clock when validating the expiry param. */
  clockSkewMs = 0;
  putCount = 0;

  private readonly objects = new Map<string, { data: Buffer; contentType: string }>();

  private constructor(
    public readonly baseUrl: string,
    private readonly server: Server
  ) {}

  static async start(): Promise<FakeS3ObjectStore> {
    let self: FakeS3ObjectStore;
    const server = createServer((req, res) => {
      const url = new URL(req.url ?? '/', 'http://fake');
      if (req.method !== 'GET' || url.pathname !== '/object') {
        res.writeHead(404, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'no fake route' }));
        return;
      }
      const key = url.searchParams.get('key') ?? '';
      const expires = Number(url.searchParams.get('expires') ?? 0);
      if (!Number.isFinite(expires) || Date.now() + self.clockSkewMs > expires) {
        res.writeHead(403, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'AccessDenied', message: 'signature expired' }));
        return;
      }
      const obj = self.objects.get(key);
      if (!obj) {
        res.writeHead(404, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'NoSuchKey' }));
        return;
      }
      const range = req.headers.range;
      const rangeMatch = typeof range === 'string' ? /^bytes=(\d+)-(\d*)$/.exec(range) : null;
      if (rangeMatch) {
        const start = Number(rangeMatch[1]);
        const end = rangeMatch[2] === '' ? obj.data.length - 1 : Number(rangeMatch[2]);
        if (start < 0 || start >= obj.data.length || end < start) {
          res.writeHead(416, { 'content-range': `bytes */${obj.data.length}` });
          res.end();
          return;
        }
        const slice = obj.data.subarray(start, Math.min(end, obj.data.length - 1) + 1);
        res.writeHead(206, {
          'content-type': obj.contentType,
          'content-length': slice.length,
          'content-range': `bytes ${start}-${start + slice.length - 1}/${obj.data.length}`,
          'accept-ranges': 'bytes'
        });
        res.end(slice);
        return;
      }
      res.writeHead(200, {
        'content-type': obj.contentType,
        'content-length': obj.data.length,
        'accept-ranges': 'bytes'
      });
      res.end(obj.data);
    });
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const address = server.address();
    if (address === null || typeof address === 'string') throw new Error('fake S3 has no address');
    self = new FakeS3ObjectStore(`http://127.0.0.1:${address.port}`, server);
    return self;
  }

  async close(): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      this.server.close((error) => (error ? reject(error) : resolve()));
    });
  }

  private guardPut(): void {
    if (this.failNextPuts > 0) {
      this.failNextPuts -= 1;
      throw new ObjectStoreError('REMOTE', 'injected S3 publish failure');
    }
  }

  async put(key: string, data: Buffer, contentType: string): Promise<ObjectMeta> {
    this.guardPut();
    this.putCount += 1;
    this.objects.set(key, { data: Buffer.from(data), contentType });
    return this.meta(key);
  }

  async putStream(
    key: string,
    stream: NodeJS.ReadableStream,
    _bytes: number,
    contentType: string
  ): Promise<ObjectMeta> {
    this.guardPut();
    this.putCount += 1;
    const chunks: Buffer[] = [];
    for await (const chunk of stream) {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    }
    this.objects.set(key, { data: Buffer.concat(chunks), contentType });
    return this.meta(key);
  }

  async head(key: string): Promise<ObjectMeta | null> {
    return this.objects.has(key) ? this.meta(key) : null;
  }

  async getRange(key: string, start?: number, end?: number): Promise<Buffer> {
    const obj = this.objects.get(key);
    if (!obj) throw new ObjectStoreError('NOT_FOUND', `object not found: ${key}`);
    if (start === undefined) return Buffer.from(obj.data);
    const effectiveEnd = end === undefined ? obj.data.length - 1 : end;
    if (start < 0 || start > effectiveEnd || start >= obj.data.length) {
      throw new ObjectStoreError('INVALID_RANGE', `invalid range for ${obj.data.length} bytes`);
    }
    return Buffer.from(obj.data.subarray(start, Math.min(effectiveEnd, obj.data.length - 1) + 1));
  }

  async delete(key: string): Promise<void> {
    this.objects.delete(key);
  }

  async copy(sourceKey: string, targetKey: string): Promise<ObjectMeta> {
    const obj = this.objects.get(sourceKey);
    if (!obj) throw new ObjectStoreError('NOT_FOUND', `object not found: ${sourceKey}`);
    this.objects.set(targetKey, { data: Buffer.from(obj.data), contentType: obj.contentType });
    return this.meta(targetKey);
  }

  async presignGet(key: string, ttlSeconds: number): Promise<string> {
    if (!this.objects.has(key)) throw new ObjectStoreError('NOT_FOUND', `object not found: ${key}`);
    const expires = Date.now() + ttlSeconds * 1000;
    return `${this.baseUrl}/object?key=${encodeURIComponent(key)}&expires=${expires}`;
  }

  async listKeys(prefix: string): Promise<string[]> {
    return [...this.objects.keys()].filter((key) => key.startsWith(prefix)).sort();
  }

  private meta(key: string): ObjectMeta {
    const obj = this.objects.get(key)!;
    return {
      key,
      bytes: obj.data.length,
      etag: `"fake-${obj.data.length.toString(16)}"`,
      contentType: obj.contentType
    };
  }
}
