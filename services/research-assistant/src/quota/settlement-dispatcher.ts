import type { V2Store } from '../db/v2/store.js';
import type { Logger } from '../observability/logger.js';
import { QuotaError, type QuotaClient } from './quota-client.js';

/**
 * Delivers durable turn settlements to the account service, re-creates
 * settlements lost between a status update and its outbox insert, and releases
 * reservations whose turn was never inserted (account-v1-integration §3.3–§3.5).
 */

export interface TurnSettlementDispatcherOptions {
  store: V2Store;
  client: QuotaClient;
  logger: Logger;
  intervalMs?: number;
  intentGraceMs?: number;
  now?: () => number;
}

export class TurnSettlementDispatcher {
  private timer: NodeJS.Timeout | null = null;
  private running = false;

  constructor(private readonly options: TurnSettlementDispatcherOptions) {}

  start(): void {
    if (this.timer) return;
    const tick = () => {
      void this.runOnce()
        .catch((error) => this.options.logger.warn('turn settlement tick failed', { err: String(error) }))
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

  async runOnce(): Promise<{ repaired: number; intents: number; delivered: number; failed: number }> {
    if (this.running) return { repaired: 0, intents: 0, delivered: 0, failed: 0 };
    this.running = true;
    try {
      const { store, client } = this.options;
      const now = this.options.now ?? Date.now;
      const repaired = store.repairMissingSettlements();
      const intents = await this.reconcileIntents(now());
      let delivered = 0;
      let failed = 0;
      for (const row of store.pendingSettlements(50)) {
        try {
          const result = await client.settle(row.reservationId, row.outcome, row.reason);
          store.markSettlementDelivered(row.reservationId, now(), result === 'conflict' ? 'conflict' : null);
          delivered += 1;
        } catch (error) {
          store.markSettlementAttempt(row.reservationId, error instanceof QuotaError ? error.code : 'SETTLE_FAILED');
          failed += 1;
        }
      }
      return { repaired, intents, delivered, failed };
    } finally {
      this.running = false;
    }
  }

  private async reconcileIntents(now: number): Promise<number> {
    const { store, client } = this.options;
    let handled = 0;
    for (const intent of store.listQuotaIntents(now - (this.options.intentGraceMs ?? 60_000))) {
      if (store.getTurn(intent.turnId)?.reservationId) {
        store.deleteQuotaIntent(intent.operationKey);
        continue;
      }
      try {
        const reservation = await client.reserve({
          accountId: intent.ownerScope,
          operationKey: intent.operationKey,
          amount: intent.amount,
          subjectRef: intent.turnId
        });
        if (reservation.status === 'reserved') {
          store.enqueueSettlement(reservation.reservationId, 'released', 'rejected_before_start', null);
        }
        store.deleteQuotaIntent(intent.operationKey);
        handled += 1;
      } catch (error) {
        if (error instanceof QuotaError && error.status !== 503) {
          store.deleteQuotaIntent(intent.operationKey);
          handled += 1;
        }
      }
    }
    return handled;
  }
}
