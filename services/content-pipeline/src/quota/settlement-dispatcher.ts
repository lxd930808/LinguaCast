import type { JobStore } from '../jobs/job-store.js';
import type { Logger } from '../observability/logger.js';
import { QuotaError, type QuotaClient } from './quota-client.js';

/**
 * Delivers durable settlement rows to the account service and repairs the
 * reserve→insert crash window (account-v1-integration §3.3–§3.5). Running jobs
 * are never released by elapsed time; only stored terminal states settle.
 */

export interface SettlementDispatcherOptions {
  store: JobStore;
  client: QuotaClient;
  logger: Logger;
  intervalMs?: number;
  /** Intents younger than this may still belong to an in-flight request. */
  intentGraceMs?: number;
  now?: () => number;
}

export class QuotaSettlementDispatcher {
  private timer: NodeJS.Timeout | null = null;
  private running = false;

  constructor(private readonly options: SettlementDispatcherOptions) {}

  start(): void {
    if (this.timer) return;
    const tick = () => {
      void this.runOnce()
        .catch((error) => this.options.logger.warn('quota settlement tick failed', { err: String(error) }))
        .finally(() => {
          if (this.timer) {
            this.timer = setTimeout(tick, this.options.intervalMs ?? 5000);
            this.timer.unref?.();
          }
        });
    };
    this.timer = setTimeout(tick, 0);
    this.timer.unref?.();
  }

  stop(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  async runOnce(): Promise<{ delivered: number; failed: number; intents: number }> {
    if (this.running) return { delivered: 0, failed: 0, intents: 0 };
    this.running = true;
    try {
      const intents = await this.reconcileIntents();
      let delivered = 0;
      let failed = 0;
      const now = this.options.now ?? Date.now;
      for (const row of this.options.store.pendingSettlements(50)) {
        try {
          const result = await this.options.client.settle(row.reservationId, row.outcome, row.reason);
          this.options.store.markSettlementDelivered(row.reservationId, now(), result === 'conflict' ? 'conflict' : null);
          if (result === 'conflict') {
            this.options.logger.warn('quota settlement conflict', { reservationId: row.reservationId, outcome: row.outcome });
          }
          delivered += 1;
        } catch (error) {
          this.options.store.markSettlementAttempt(row.reservationId, error instanceof QuotaError ? error.code : 'SETTLE_FAILED');
          failed += 1;
        }
      }
      return { delivered, failed, intents };
    } finally {
      this.running = false;
    }
  }

  /** Reservations whose job row never got inserted are released (rejected_before_start). */
  async reconcileIntents(): Promise<number> {
    const now = (this.options.now ?? Date.now)();
    let repaired = 0;
    for (const intent of this.options.store.listIntents(now - (this.options.intentGraceMs ?? 60_000))) {
      const job = this.options.store.getJob(intent.jobId);
      if (job?.reservationId) {
        this.options.store.deleteIntent(intent.operationKey);
        continue;
      }
      try {
        const reservation = await this.options.client.reserve({
          accountId: intent.ownerScope,
          operationKey: intent.operationKey,
          amount: intent.amount,
          subjectRef: intent.jobId
        });
        if (reservation.status === 'reserved') {
          this.options.store.enqueueSettlement(reservation.reservationId, 'released', 'rejected_before_start', null);
        }
        this.options.store.deleteIntent(intent.operationKey);
        repaired += 1;
      } catch (error) {
        if (error instanceof QuotaError && error.status !== 503) {
          // Nothing is reserved for this operation (quota refused / conflict): drop the intent.
          this.options.store.deleteIntent(intent.operationKey);
          repaired += 1;
        }
      }
    }
    return repaired;
  }
}
