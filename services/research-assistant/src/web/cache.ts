export class WebCache {
  private readonly data = new Map<string, { expiresAt: number; value: unknown }>();

  get<T>(key: string): T | null {
    const hit = this.data.get(key);
    if (!hit || hit.expiresAt <= Date.now()) {
      this.data.delete(key);
      return null;
    }
    return hit.value as T;
  }

  set(key: string, value: unknown, ttlMs: number): void {
    this.data.set(key, { value, expiresAt: Date.now() + ttlMs });
  }
}

export function webCacheKey(parts: { kind: string; provider: string; urlOrQuery: string; extractor?: string }): string {
  return [parts.kind, parts.provider, parts.urlOrQuery, parts.extractor ?? ''].join('|');
}
