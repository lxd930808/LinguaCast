import type { AppleClient, FetchLike } from '../apple/apple-client.js';
import type { PurgeTarget } from '../config.js';
import type { SecretBox } from '../crypto/tokens.js';
import { AccountError } from '../domain/errors.js';
import type { Logger } from '../observability/logger.js';
import type { AccountStore, DeletionRow, DeletionStep } from '../store/account-store.js';
import type { QuotaStore } from '../quota/quota-store.js';

/**
 * Retrying cross-service deletion workflow (account-v1-integration §4). Each
 * step is idempotent on the callee side; a step is marked done only after an
 * explicit completion response. Tombstone rows are kept after completion.
 */

export interface DeletionWorkerOptions {
  store: AccountStore;
  /** When present, open reservations are released and quota history is anonymized on completion. */
  quota?: QuotaStore;
  apple: AppleClient | null;
  secretBox: SecretBox | null;
  purgeTargets: readonly PurgeTarget[];
  purgeToken: string | null;
  fetchImpl: FetchLike;
  logger: Logger;
  now: () => number;
  intervalMs: number;
  batchSize?: number;
}

const BASE_BACKOFF_MS = 30_000;
const MAX_BACKOFF_MS = 60 * 60 * 1000;
const IN_PROGRESS_RECHECK_MS = 15_000;
const MAINTENANCE_RETENTION_MS = 24 * 60 * 60 * 1000;

type StepOutcome = 'done' | 'in_progress' | { errorCode: string };

export class DeletionWorker {
  private timer: NodeJS.Timeout | null = null;
  private running = false;

  constructor(private readonly options: DeletionWorkerOptions) {}

  start(): void {
    if (this.timer) return;
    const tick = () => {
      void this.runOnce()
        .catch((error) => this.options.logger.error('deletion tick failed', { err: String(error) }))
        .finally(() => {
          if (this.timer) {
            this.timer = setTimeout(tick, this.options.intervalMs);
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

  /** Processes due deletions once; returns the number of deletions completed. */
  async runOnce(): Promise<number> {
    if (this.running) return 0;
    this.running = true;
    try {
      const { store, now } = this.options;
      store.pruneAccessTokens(now());
      store.pruneChallenges(now() - MAINTENANCE_RETENTION_MS);
      let completed = 0;
      for (const deletion of store.dueDeletions(now(), this.options.batchSize ?? 10)) {
        if (await this.process(deletion)) completed += 1;
      }
      return completed;
    } finally {
      this.running = false;
    }
  }

  private async process(deletion: DeletionRow): Promise<boolean> {
    const { store, now, logger } = this.options;
    const steps: DeletionStep[] = deletion.steps.map((step) => ({ ...step }));
    let failureCode: string | null = null;
    let waiting = false;

    for (const step of steps) {
      if (step.status === 'done') continue;
      const outcome = await this.runStep(step.name, deletion);
      step.attempts += 1;
      if (outcome === 'done') {
        step.status = 'done';
        delete step.lastErrorCode;
      } else if (outcome === 'in_progress') {
        waiting = true;
      } else {
        step.lastErrorCode = outcome.errorCode;
        failureCode = outcome.errorCode;
      }
    }

    const allDone = steps.every((step) => step.status === 'done');
    const at = now();
    const attempts = failureCode ? deletion.attempts + 1 : deletion.attempts;
    const next: DeletionRow = {
      ...deletion,
      steps,
      attempts,
      status: allDone ? 'completed' : 'in_progress',
      lastErrorCode: failureCode,
      nextAttemptAt: allDone
        ? at
        : failureCode
          ? at + Math.min(MAX_BACKOFF_MS, BASE_BACKOFF_MS * 2 ** Math.max(0, attempts - 1))
          : at + (waiting ? IN_PROGRESS_RECHECK_MS : 0),
      appleRefreshTokenEnc: allDone ? null : deletion.appleRefreshTokenEnc,
      completedAt: allDone ? at : null
    };
    store.transaction(() => {
      store.saveDeletionProgress(next);
      if (allDone) {
        store.setAccountStatus(deletion.accountId, 'deleted', at);
        this.options.quota?.releaseOutstandingInTransaction(deletion.accountId, at);
        this.options.quota?.anonymizeInTransaction(deletion.accountId, `deleted:${deletion.deletionId}`);
      }
    });
    if (allDone) {
      logger.info('account deletion completed', { deletionId: deletion.deletionId });
    } else if (failureCode) {
      logger.warn('account deletion step failed', { deletionId: deletion.deletionId, code: failureCode });
    }
    return allDone;
  }

  private async runStep(name: string, deletion: DeletionRow): Promise<StepOutcome> {
    if (name === 'apple-revoke') return this.revokeApple(deletion);
    if (name.startsWith('purge:')) {
      const target = this.options.purgeTargets.find((entry) => `purge:${entry.name}` === name);
      if (!target) return { errorCode: 'PURGE_TARGET_NOT_CONFIGURED' };
      return this.purge(target, deletion.accountId);
    }
    return { errorCode: 'UNKNOWN_STEP' };
  }

  private async purge(target: PurgeTarget, accountId: string): Promise<StepOutcome> {
    if (!this.options.purgeToken) return { errorCode: 'PURGE_TOKEN_NOT_CONFIGURED' };
    try {
      const response = await this.options.fetchImpl(
        `${target.baseUrl}/internal/v1/accounts/${encodeURIComponent(accountId)}/purge`,
        {
          method: 'POST',
          headers: { authorization: `Bearer ${this.options.purgeToken}`, 'content-type': 'application/json' },
          body: '{}'
        }
      );
      if (response.status === 202) return 'in_progress';
      if (response.status !== 200) return { errorCode: `PURGE_HTTP_${response.status}` };
      const body = (await response.json().catch(() => null)) as { status?: unknown } | null;
      return body?.status === 'done' ? 'done' : 'in_progress';
    } catch {
      return { errorCode: 'PURGE_UNREACHABLE' };
    }
  }

  private async revokeApple(deletion: DeletionRow): Promise<StepOutcome> {
    if (!deletion.appleRefreshTokenEnc || !deletion.appleClientId) return 'done';
    if (!this.options.apple || !this.options.secretBox) return { errorCode: 'APPLE_NOT_CONFIGURED' };
    let token: string;
    try {
      token = this.options.secretBox.open(deletion.appleRefreshTokenEnc);
    } catch {
      return { errorCode: 'APPLE_TOKEN_UNREADABLE' };
    }
    try {
      await this.options.apple.revokeRefreshToken(token, deletion.appleClientId);
      return 'done';
    } catch (error) {
      return { errorCode: error instanceof AccountError ? error.code : 'APPLE_REVOKE_FAILED' };
    }
  }
}
