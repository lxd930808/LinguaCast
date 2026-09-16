import { createHash, randomBytes } from 'node:crypto';

import { DomainError } from '../../domain/types.js';

export const CONFIRMATION_TOKEN_PREFIX = 'ct_';

export function issueConfirmationToken(): { token: string; hash: string } {
  const token = `${CONFIRMATION_TOKEN_PREFIX}${randomBytes(24).toString('hex')}`;
  return { token, hash: hashConfirmationToken(token) };
}

export function hashConfirmationToken(token: string): string {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

export function assertConfirmationToken(token: string | undefined | null, expectedHash?: string | null): string {
  if (!token || !token.startsWith(CONFIRMATION_TOKEN_PREFIX) || token.length < 20) {
    throw new DomainError('TRANSCRIPT_CONFIRMATION_REQUIRED', 'missing or invalid user confirmation token', false, 400);
  }
  const hash = hashConfirmationToken(token);
  if (expectedHash && expectedHash !== hash) {
    throw new DomainError('TRANSCRIPT_CONFIRMATION_REQUIRED', 'missing or invalid user confirmation token', false, 400);
  }
  return hash;
}
