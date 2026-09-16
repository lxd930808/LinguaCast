/**
 * Typed error carrying a stable code from docs/contracts/account-v1-errors.md.
 * `message` is an English diagnostic and must never include credentials,
 * Apple claims or request bodies.
 */
export class AccountError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly retryable = false,
    readonly params?: Record<string, unknown>,
    readonly retryAfterSeconds?: number
  ) {
    super(message);
    this.name = 'AccountError';
  }
}

export function invalidRequest(field: string, reason: string): AccountError {
  return new AccountError(400, 'INVALID_REQUEST', `${field} ${reason}`, false, { field });
}

export function authModeUnsupported(): AccountError {
  return new AccountError(404, 'AUTH_MODE_UNSUPPORTED', 'operation is not available in this authentication mode');
}
