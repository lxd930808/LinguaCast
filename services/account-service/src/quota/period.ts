/**
 * Daily quota periods follow the Asia/Shanghai calendar day (UTC+8, no DST).
 * A reservation keeps the period in which it was created even when it is
 * settled after midnight.
 */

export const QUOTA_TIMEZONE = 'Asia/Shanghai';
const OFFSET_MS = 8 * 3600 * 1000;
const DAY_MS = 24 * 3600 * 1000;

export function periodKey(nowMs: number): string {
  return new Date(nowMs + OFFSET_MS).toISOString().slice(0, 10);
}

/** Epoch milliseconds of the next 00:00 Asia/Shanghai. */
export function nextResetAt(nowMs: number): number {
  const local = nowMs + OFFSET_MS;
  return Math.floor(local / DAY_MS) * DAY_MS + DAY_MS - OFFSET_MS;
}
