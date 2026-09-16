/**
 * FIFO dispatcher for queued V2 turns (V18 WP04). A turn stays `queued` until a
 * slot is free: at most `perOwner` running turns per account and `global`
 * running turns in this process. Waiting is a status, not an error.
 */

export interface QueuedTurn {
  turnId: string;
  ownerScope: string;
}

export interface TurnSchedulerOptions {
  store: { listQueuedTurns(limit: number): QueuedTurn[] };
  run: (turnId: string) => Promise<unknown>;
  limits: { perOwner: number; global: number };
  onError?: (turnId: string, error: unknown) => void;
}

export class TurnScheduler {
  private readonly running = new Map<string, string>();
  private pumping = false;

  constructor(private readonly options: TurnSchedulerOptions) {}

  get runningTurnIds(): string[] {
    return [...this.running.keys()];
  }

  /** Starts as many queued turns as the limits allow. Safe to call repeatedly. */
  enqueue(): void {
    if (this.pumping) return;
    this.pumping = true;
    try {
      const { perOwner, global } = this.options.limits;
      for (const candidate of this.options.store.listQueuedTurns(200)) {
        if (this.running.size >= global) break;
        if (this.running.has(candidate.turnId)) continue;
        let ownerRunning = 0;
        for (const owner of this.running.values()) if (owner === candidate.ownerScope) ownerRunning += 1;
        if (ownerRunning >= perOwner) continue;
        this.running.set(candidate.turnId, candidate.ownerScope);
        void this.options
          .run(candidate.turnId)
          .catch((error) => this.options.onError?.(candidate.turnId, error))
          .finally(() => {
            this.running.delete(candidate.turnId);
            this.enqueue();
          });
      }
    } finally {
      this.pumping = false;
    }
  }
}
