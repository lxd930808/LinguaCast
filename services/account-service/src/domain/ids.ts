import { ulid } from 'ulid';

export const SELFHOST_ACCOUNT_ID = 'selfhost';

const ULID = '[0-9A-HJKMNP-TV-Z]{26}';
export const ACCOUNT_ID_PATTERN = new RegExp(`^(acc_${ULID}|${SELFHOST_ACCOUNT_ID})$`);
export const CHALLENGE_ID_PATTERN = new RegExp(`^ach_${ULID}$`);

export const newAccountId = (): string => `acc_${ulid()}`;
export const newSessionId = (): string => `ses_${ulid()}`;
export const newChallengeId = (): string => `ach_${ulid()}`;
export const newRefreshTokenId = (): string => `rtk_${ulid()}`;
export const newDeletionId = (): string => `del_${ulid()}`;
