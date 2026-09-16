/**
 * Fixed-window, in-memory request limiter for unauthenticated auth endpoints.
 * It protects the Apple verification path from abuse; it is not the daily
 * product quota (see QUOTA_* codes).
 */
export class FixedWindowRateLimiter {
  private readonly windows = new Map<string, { startedAt: number; count: number }>();

  constructor(
    private readonly limitPerWindow: number,
    private readonly now: () => number,
    private readonly windowMs = 60_000,
    private readonly maxKeys = 10_000
  ) {}

  /** Returns 0 when allowed, otherwise the seconds until the window resets. */
  hit(key: string): number {
    const now = this.now();
    const current = this.windows.get(key);
    if (!current || now - current.startedAt >= this.windowMs) {
      if (this.windows.size >= this.maxKeys) this.evictExpired(now);
      this.windows.set(key, { startedAt: now, count: 1 });
      return 0;
    }
    current.count += 1;
    if (current.count <= this.limitPerWindow) return 0;
    return Math.max(1, Math.ceil((current.startedAt + this.windowMs - now) / 1000));
  }

  private evictExpired(now: number): void {
    for (const [key, window] of this.windows) {
      if (now - window.startedAt >= this.windowMs) this.windows.delete(key);
    }
    if (this.windows.size >= this.maxKeys) this.windows.clear();
  }
}
