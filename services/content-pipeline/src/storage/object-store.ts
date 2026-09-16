/**
 * Object storage abstraction. Production uses R2 via SigV4; tests use the
 * in-memory implementation so CI never touches billed services.
 */

export interface ObjectMeta {
  key: string;
  bytes: number;
  etag: string;
  contentType?: string;
}

export interface ObjectStore {
  put(key: string, data: Buffer, contentType: string): Promise<ObjectMeta>;
  /**
   * Streaming variant for large media: avoids buffering the whole object in
   * memory. Implementations sign with UNSIGNED-PAYLOAD over TLS.
   */
  putStream?(
    key: string,
    stream: NodeJS.ReadableStream,
    bytes: number,
    contentType: string
  ): Promise<ObjectMeta>;
  head(key: string): Promise<ObjectMeta | null>;
  getRange(key: string, start?: number, end?: number): Promise<Buffer>;
  delete(key: string): Promise<void>;
  /** Server-side copy within the same bucket (temp → final publish). */
  copy(sourceKey: string, targetKey: string): Promise<ObjectMeta>;
  presignGet(key: string, ttlSeconds: number): Promise<string>;
  listKeys(prefix: string): Promise<string[]>;
}

export class ObjectStoreError extends Error {
  constructor(
    readonly code: 'NOT_FOUND' | 'INVALID_RANGE' | 'REMOTE',
    message: string
  ) {
    super(message);
    this.name = 'ObjectStoreError';
  }
}

export class InMemoryObjectStore implements ObjectStore {
  private readonly objects = new Map<string, { data: Buffer; contentType: string }>();

  async put(key: string, data: Buffer, contentType: string): Promise<ObjectMeta> {
    this.objects.set(key, { data: Buffer.from(data), contentType });
    return this.meta(key);
  }

  async putStream(
    key: string,
    stream: NodeJS.ReadableStream,
    _bytes: number,
    contentType: string
  ): Promise<ObjectMeta> {
    const chunks: Buffer[] = [];
    for await (const chunk of stream) {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    }
    this.objects.set(key, { data: Buffer.concat(chunks), contentType });
    return this.meta(key);
  }

  async head(key: string): Promise<ObjectMeta | null> {
    const obj = this.objects.get(key);
    if (!obj) return null;
    return this.meta(key);
  }

  async getRange(key: string, start?: number, end?: number): Promise<Buffer> {
    const obj = this.objects.get(key);
    if (!obj) throw new ObjectStoreError('NOT_FOUND', `object not found: ${key}`);
    const size = obj.data.length;
    if (start === undefined) return Buffer.from(obj.data);
    const effectiveEnd = end === undefined ? size - 1 : end;
    if (start < 0 || start > effectiveEnd || start >= size) {
      throw new ObjectStoreError('INVALID_RANGE', `invalid range ${start}-${end ?? ''} for ${size} bytes`);
    }
    return Buffer.from(obj.data.subarray(start, Math.min(effectiveEnd, size - 1) + 1));
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
    return `memory://presigned/${encodeURIComponent(key)}?ttl=${ttlSeconds}`;
  }

  async listKeys(prefix: string): Promise<string[]> {
    return [...this.objects.keys()].filter((key) => key.startsWith(prefix)).sort();
  }

  private meta(key: string): ObjectMeta {
    const obj = this.objects.get(key)!;
    return {
      key,
      bytes: obj.data.length,
      etag: `"mem-${obj.data.length.toString(16)}"`,
      contentType: obj.contentType
    };
  }
}
