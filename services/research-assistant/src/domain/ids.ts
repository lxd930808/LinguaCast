import { ulid } from 'ulid';

export type IdPrefix = 'as' | 'at' | 'am' | 'sr' | 'cb' | 'ct' | 'srun';

export function newId(prefix: IdPrefix): string {
  return `${prefix}_${ulid()}`;
}

export function isId(prefix: IdPrefix, value: string): boolean {
  return new RegExp(`^${prefix}_[0-9A-HJKMNP-TV-Z]{26}$`).test(value);
}

export function nowIso(date = new Date()): string {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}
