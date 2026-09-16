import type { DatabaseSync } from 'node:sqlite';
import { ulid } from 'ulid';

import { AccountError } from '../domain/errors.js';
import { QUOTA_TIMEZONE, nextResetAt, periodKey } from './period.js';

/**
 * Quota reservations and ledger (docs/contracts/account-v1-integration.md §3).
 * reserve/settle run in BEGIN IMMEDIATE transactions so concurrent callers
 * serialize and a period can never be oversold.
 */

export type QuotaKind = 'media' | 'assistant';
export type ReservationStatus = 'reserved' | 'consumed' | 'released';
export type SettleOutcome = 'consumed' | 'released';
export const QUOTA_KINDS: readonly QuotaKind[] = ['media', 'assistant'];
export const SETTLE_REASONS = [
  'succeeded',
  'failed',
  'cancelled',
  'reused_artifact',
  'rejected_before_start',
  'account_deleted'
] as const;
export type SettleReason = (typeof SETTLE_REASONS)[number];

export interface QuotaLimits {
  enforced: boolean;
  mediaSecondsPerDay: number;
  assistantTurnsPerDay: number;
  mediaConcurrency: number;
  assistantConcurrency: number;
}

export interface ReservationRow {
  reservationId: string;
  accountId: string;
  kind: QuotaKind;
  operationKey: string;
  amount: number;
  periodKey: string;
  status: ReservationStatus;
  reason: string | null;
  service: string;
  subjectRef: string | null;
  createdAt: number;
  settledAt: number | null;
}

export interface ReserveInput {
  accountId: string;
  kind: QuotaKind;
  operationKey: string;
  amount: number;
  service: string;
  subjectRef: string | null;
}

type Raw = Record<string, unknown>;

function toReservation(row: Raw): ReservationRow {
  return {
    reservationId: row.reservation_id as string,
    accountId: row.account_id as string,
    kind: row.kind as QuotaKind,
    operationKey: row.operation_key as string,
    amount: Number(row.amount),
    periodKey: row.period_key as string,
    status: row.status as ReservationStatus,
    reason: (row.reason as string | null) ?? null,
    service: row.service as string,
    subjectRef: (row.subject_ref as string | null) ?? null,
    createdAt: Number(row.created_at),
    settledAt: row.settled_at === null || row.settled_at === undefined ? null : Number(row.settled_at)
  };
}

const iso = (ms: number): string => new Date(ms).toISOString();

export function projectReservation(row: ReservationRow): Record<string, unknown> {
  return {
    reservationId: row.reservationId,
    accountId: row.accountId,
    kind: row.kind,
    operationKey: row.operationKey,
    amount: row.amount,
    periodKey: row.periodKey,
    status: row.status,
    reason: row.reason,
    service: row.service,
    createdAt: iso(row.createdAt),
    settledAt: row.settledAt === null ? null : iso(row.settledAt)
  };
}

export class QuotaStore {
  constructor(private readonly db: DatabaseSync) {}

  private transaction<T>(fn: () => T): T {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const result = fn();
      this.db.exec('COMMIT');
      return result;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  limitFor(kind: QuotaKind, limits: QuotaLimits): number {
    return kind === 'media' ? limits.mediaSecondsPerDay : limits.assistantTurnsPerDay;
  }

  get(reservationId: string): ReservationRow | null {
    const row = this.db.prepare('SELECT * FROM quota_reservations WHERE reservation_id = ?').get(reservationId) as Raw | undefined;
    return row ? toReservation(row) : null;
  }

  /** Sums for one account, kind and period: consumed (used) and still reserved. */
  totals(accountId: string, kind: QuotaKind, period: string): { used: number; reserved: number } {
    const row = this.db
      .prepare(
        `SELECT COALESCE(SUM(CASE WHEN status = 'consumed' THEN amount END), 0) AS used,
                COALESCE(SUM(CASE WHEN status = 'reserved' THEN amount END), 0) AS reserved
           FROM quota_reservations WHERE account_id = ? AND kind = ? AND period_key = ?`
      )
      .get(accountId, kind, period) as { used: number; reserved: number };
    return { used: Number(row.used), reserved: Number(row.reserved) };
  }

  /** Ledger-derived sums, used to check the reservation table against the append-only ledger. */
  ledgerTotals(accountId: string, kind: QuotaKind, period: string): { used: number; reserved: number } {
    const row = this.db
      .prepare(
        `SELECT COALESCE(SUM(CASE WHEN action = 'reserve' THEN amount END), 0) AS reserve,
                COALESCE(SUM(CASE WHEN action = 'consume' THEN amount END), 0) AS consume,
                COALESCE(SUM(CASE WHEN action = 'release' THEN amount END), 0) AS release,
                COALESCE(SUM(CASE WHEN action = 'adjust' THEN amount END), 0) AS adjust
           FROM quota_ledger WHERE account_id = ? AND kind = ? AND period_key = ?`
      )
      .get(accountId, kind, period) as { reserve: number; consume: number; release: number; adjust: number };
    return {
      used: Number(row.consume) + Number(row.adjust),
      reserved: Number(row.reserve) - Number(row.consume) - Number(row.release)
    };
  }

  reserve(input: ReserveInput, limits: QuotaLimits, now: number): { created: boolean; reservation: ReservationRow } {
    return this.transaction(() => {
      const existingRow = this.db
        .prepare('SELECT * FROM quota_reservations WHERE account_id = ? AND kind = ? AND operation_key = ?')
        .get(input.accountId, input.kind, input.operationKey) as Raw | undefined;
      if (existingRow) {
        const existing = toReservation(existingRow);
        if (existing.amount !== input.amount) {
          throw new AccountError(409, 'IDEMPOTENCY_CONFLICT', 'operationKey was reserved with a different amount', false, {
            operationKey: input.operationKey
          });
        }
        return { created: false, reservation: existing };
      }

      const account = this.db.prepare('SELECT status FROM accounts WHERE account_id = ?').get(input.accountId) as
        | { status: string }
        | undefined;
      if (!account) throw new AccountError(404, 'NOT_FOUND', 'account is unknown');
      if (account.status === 'disabled') throw new AccountError(403, 'ACCOUNT_DISABLED', 'account is disabled');
      if (account.status !== 'active') throw new AccountError(403, 'ACCOUNT_DELETING', 'account deletion is in progress');

      const period = periodKey(now);
      const limit = this.limitFor(input.kind, limits);
      if (limits.enforced) {
        if (input.amount > limit) {
          throw new AccountError(422, 'QUOTA_REQUEST_TOO_LARGE', 'operation is larger than the daily limit', false, {
            kind: input.kind,
            limit,
            requested: input.amount
          });
        }
        const { used, reserved } = this.totals(input.accountId, input.kind, period);
        if (used + reserved + input.amount > limit) {
          const resetAt = nextResetAt(now);
          throw new AccountError(
            429,
            'QUOTA_EXCEEDED',
            'daily quota is exhausted',
            false,
            {
              kind: input.kind,
              limit,
              used,
              reserved,
              remaining: Math.max(0, limit - used - reserved),
              requested: input.amount,
              resetAt: iso(resetAt)
            },
            Math.max(1, Math.ceil((resetAt - now) / 1000))
          );
        }
      }

      const reservation: ReservationRow = {
        reservationId: `qr_${ulid()}`,
        accountId: input.accountId,
        kind: input.kind,
        operationKey: input.operationKey,
        amount: input.amount,
        periodKey: period,
        status: 'reserved',
        reason: null,
        service: input.service,
        subjectRef: input.subjectRef,
        createdAt: now,
        settledAt: null
      };
      this.db
        .prepare(
          `INSERT INTO quota_reservations (reservation_id, account_id, kind, operation_key, amount, period_key, status,
             reason, service, subject_ref, created_at, settled_at)
           VALUES (?, ?, ?, ?, ?, ?, 'reserved', NULL, ?, ?, ?, NULL)`
        )
        .run(
          reservation.reservationId,
          reservation.accountId,
          reservation.kind,
          reservation.operationKey,
          reservation.amount,
          reservation.periodKey,
          reservation.service,
          reservation.subjectRef,
          now
        );
      this.appendLedger(reservation, 'reserve', reservation.amount, null, now);
      return { created: true, reservation };
    });
  }

  settle(reservationId: string, outcome: SettleOutcome, reason: SettleReason, now: number): ReservationRow {
    return this.transaction(() => {
      const current = this.get(reservationId);
      if (!current) throw new AccountError(404, 'RESERVATION_NOT_FOUND', 'reservation is unknown');
      if (current.status === outcome) return current;
      if (current.status !== 'reserved') {
        throw new AccountError(409, 'RESERVATION_ALREADY_SETTLED', 'reservation was already settled differently', false, {
          status: current.status
        });
      }
      this.markSettled(current, outcome, reason, now);
      return this.get(reservationId)!;
    });
  }

  /** Releases every open reservation of an account. Caller provides the transaction. */
  releaseOutstandingInTransaction(accountId: string, now: number): number {
    const rows = (
      this.db.prepare("SELECT * FROM quota_reservations WHERE account_id = ? AND status = 'reserved'").all(accountId) as Raw[]
    ).map(toReservation);
    for (const row of rows) this.markSettled(row, 'released', 'account_deleted', now);
    return rows.length;
  }

  /** Replaces the account ID in quota history with a non-personal tombstone ID. Caller provides the transaction. */
  anonymizeInTransaction(accountId: string, replacement: string): void {
    this.db.prepare('UPDATE quota_reservations SET account_id = ?, subject_ref = NULL WHERE account_id = ?').run(replacement, accountId);
    this.db.prepare('UPDATE quota_ledger SET account_id = ? WHERE account_id = ?').run(replacement, accountId);
  }

  snapshot(accountId: string, limits: QuotaLimits, now: number): Record<string, unknown> {
    const period = periodKey(now);
    const buckets = QUOTA_KINDS.map((kind) => {
      const limit = this.limitFor(kind, limits);
      const { used, reserved } = this.totals(accountId, kind, period);
      return {
        kind,
        unit: kind === 'media' ? 'seconds' : 'turns',
        limit,
        used,
        reserved,
        remaining: Math.max(0, limit - used - reserved)
      };
    });
    const concurrency = QUOTA_KINDS.map((kind) => {
      const limit = kind === 'media' ? limits.mediaConcurrency : limits.assistantConcurrency;
      const open = (
        this.db
          .prepare("SELECT COUNT(*) AS n FROM quota_reservations WHERE account_id = ? AND kind = ? AND status = 'reserved'")
          .get(accountId, kind) as { n: number }
      ).n;
      const active = Number(open);
      return { kind, limit, running: Math.min(active, limit), queued: Math.max(0, active - limit) };
    });
    return {
      timezone: QUOTA_TIMEZONE,
      periodKey: period,
      resetAt: iso(nextResetAt(now)),
      enforced: limits.enforced,
      buckets,
      concurrency
    };
  }

  private markSettled(row: ReservationRow, outcome: SettleOutcome, reason: SettleReason, now: number): void {
    this.db
      .prepare("UPDATE quota_reservations SET status = ?, reason = ?, settled_at = ? WHERE reservation_id = ? AND status = 'reserved'")
      .run(outcome, reason, now, row.reservationId);
    this.appendLedger(row, outcome === 'consumed' ? 'consume' : 'release', row.amount, reason, now);
  }

  private appendLedger(
    row: ReservationRow,
    action: 'reserve' | 'consume' | 'release',
    amount: number,
    reason: string | null,
    now: number
  ): void {
    this.db
      .prepare(
        `INSERT INTO quota_ledger (reservation_id, account_id, kind, period_key, action, amount, reason, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(row.reservationId, row.accountId, row.kind, row.periodKey, action, amount, reason, now);
  }
}
