import type { DatabaseSync } from 'node:sqlite';

import type { AuthMode } from '../config.js';

export type AccountStatus = 'active' | 'disabled' | 'deleting' | 'deleted';
export type RefreshTokenStatus = 'active' | 'rotated' | 'superseded' | 'revoked';
export type DeletionStatus = 'pending' | 'in_progress' | 'completed';

export interface AccountRow {
  accountId: string;
  authMode: AuthMode;
  status: AccountStatus;
  createdAt: number;
  updatedAt: number;
}

export interface AppleIdentityRow {
  appleSub: string;
  accountId: string;
  clientId: string;
  refreshTokenEnc: string | null;
}

export interface ChallengeRow {
  challengeId: string;
  nonceHash: string;
  platform: string;
  expiresAt: number;
  consumedAt: number | null;
}

export interface SessionRow {
  sessionId: string;
  accountId: string;
  platform: string;
  createdAt: number;
  expiresAt: number;
  revokedAt: number | null;
}

export interface RefreshTokenRow {
  tokenId: string;
  sessionId: string;
  parentTokenId: string | null;
  status: RefreshTokenStatus;
  rotatedAt: number | null;
}

export interface AccessTokenLookup {
  sessionId: string;
  expiresAt: number;
  sessionExpiresAt: number;
  sessionRevokedAt: number | null;
  accountId: string;
  accountStatus: AccountStatus;
  authMode: AuthMode;
}

export interface DeletionStep {
  name: string;
  status: 'pending' | 'done';
  attempts: number;
  lastErrorCode?: string;
}

export interface DeletionRow {
  deletionId: string;
  accountId: string;
  status: DeletionStatus;
  steps: DeletionStep[];
  appleClientId: string | null;
  appleRefreshTokenEnc: string | null;
  attempts: number;
  nextAttemptAt: number;
  lastErrorCode: string | null;
  requestedAt: number;
  completedAt: number | null;
}

type Raw = Record<string, unknown>;

function toAccount(row: Raw): AccountRow {
  return {
    accountId: row.account_id as string,
    authMode: row.auth_mode as AuthMode,
    status: row.status as AccountStatus,
    createdAt: row.created_at as number,
    updatedAt: row.updated_at as number
  };
}

function toDeletion(row: Raw): DeletionRow {
  return {
    deletionId: row.deletion_id as string,
    accountId: row.account_id as string,
    status: row.status as DeletionStatus,
    steps: JSON.parse(row.steps_json as string) as DeletionStep[],
    appleClientId: (row.apple_client_id as string | null) ?? null,
    appleRefreshTokenEnc: (row.apple_refresh_token_enc as string | null) ?? null,
    attempts: row.attempts as number,
    nextAttemptAt: row.next_attempt_at as number,
    lastErrorCode: (row.last_error_code as string | null) ?? null,
    requestedAt: row.requested_at as number,
    completedAt: (row.completed_at as number | null) ?? null
  };
}

/**
 * Synchronous SQLite access. Multi-statement invariants (challenge consumption,
 * session creation, refresh rotation, deletion) are wrapped by callers in
 * `transaction`, which uses BEGIN IMMEDIATE so concurrent writers serialize.
 */
export class AccountStore {
  constructor(private readonly db: DatabaseSync) {}

  transaction<T>(fn: () => T): T {
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

  ping(): void {
    this.db.prepare('SELECT 1').get();
  }

  close(): void {
    this.db.close();
  }

  // Accounts -----------------------------------------------------------------

  getAccount(accountId: string): AccountRow | null {
    const row = this.db.prepare('SELECT * FROM accounts WHERE account_id = ?').get(accountId) as Raw | undefined;
    return row ? toAccount(row) : null;
  }

  createAccount(accountId: string, authMode: AuthMode, now: number): AccountRow {
    this.db
      .prepare('INSERT INTO accounts (account_id, auth_mode, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)')
      .run(accountId, authMode, 'active', now, now);
    return { accountId, authMode, status: 'active', createdAt: now, updatedAt: now };
  }

  ensureAccount(accountId: string, authMode: AuthMode, now: number): AccountRow {
    return this.getAccount(accountId) ?? this.createAccount(accountId, authMode, now);
  }

  setAccountStatus(accountId: string, status: AccountStatus, now: number): void {
    this.db.prepare('UPDATE accounts SET status = ?, updated_at = ? WHERE account_id = ?').run(status, now, accountId);
  }

  // Apple identities ---------------------------------------------------------

  findAppleIdentity(appleSub: string): AppleIdentityRow | null {
    const row = this.db.prepare('SELECT * FROM apple_identities WHERE apple_sub = ?').get(appleSub) as Raw | undefined;
    return row ? this.toIdentity(row) : null;
  }

  findAppleIdentityByAccount(accountId: string): AppleIdentityRow | null {
    const row = this.db.prepare('SELECT * FROM apple_identities WHERE account_id = ?').get(accountId) as Raw | undefined;
    return row ? this.toIdentity(row) : null;
  }

  insertAppleIdentity(identity: AppleIdentityRow, now: number): void {
    this.db
      .prepare(
        `INSERT INTO apple_identities (apple_sub, account_id, client_id, refresh_token_enc, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)`
      )
      .run(identity.appleSub, identity.accountId, identity.clientId, identity.refreshTokenEnc, now, now);
  }

  updateAppleIdentity(appleSub: string, clientId: string, refreshTokenEnc: string | null, now: number): void {
    this.db
      .prepare('UPDATE apple_identities SET client_id = ?, refresh_token_enc = ?, updated_at = ? WHERE apple_sub = ?')
      .run(clientId, refreshTokenEnc, now, appleSub);
  }

  deleteAppleIdentityForAccount(accountId: string): void {
    this.db.prepare('DELETE FROM apple_identities WHERE account_id = ?').run(accountId);
  }

  private toIdentity(row: Raw): AppleIdentityRow {
    return {
      appleSub: row.apple_sub as string,
      accountId: row.account_id as string,
      clientId: row.client_id as string,
      refreshTokenEnc: (row.refresh_token_enc as string | null) ?? null
    };
  }

  // Challenges ---------------------------------------------------------------

  insertChallenge(challenge: Omit<ChallengeRow, 'consumedAt'>, now: number): void {
    this.db
      .prepare(
        'INSERT INTO auth_challenges (challenge_id, nonce_hash, platform, created_at, expires_at) VALUES (?, ?, ?, ?, ?)'
      )
      .run(challenge.challengeId, challenge.nonceHash, challenge.platform, now, challenge.expiresAt);
  }

  /**
   * Marks the challenge consumed and returns its prior state. The mark commits
   * even when the caller later rejects the exchange (single use per attempt).
   */
  consumeChallenge(challengeId: string, now: number): ChallengeRow | null {
    return this.transaction(() => {
      const row = this.db.prepare('SELECT * FROM auth_challenges WHERE challenge_id = ?').get(challengeId) as
        | Raw
        | undefined;
      if (!row) return null;
      const consumedAt = (row.consumed_at as number | null) ?? null;
      if (consumedAt === null) {
        this.db.prepare('UPDATE auth_challenges SET consumed_at = ? WHERE challenge_id = ?').run(now, challengeId);
      }
      return {
        challengeId,
        nonceHash: row.nonce_hash as string,
        platform: row.platform as string,
        expiresAt: row.expires_at as number,
        consumedAt
      };
    });
  }

  pruneChallenges(olderThan: number): number {
    return Number(this.db.prepare('DELETE FROM auth_challenges WHERE expires_at < ?').run(olderThan).changes);
  }

  // Sessions and credentials -------------------------------------------------

  insertSession(session: Omit<SessionRow, 'revokedAt'>, deviceName: string | null): void {
    this.db
      .prepare(
        `INSERT INTO sessions (session_id, account_id, platform, device_name, created_at, expires_at)
         VALUES (?, ?, ?, ?, ?, ?)`
      )
      .run(session.sessionId, session.accountId, session.platform, deviceName, session.createdAt, session.expiresAt);
  }

  getSession(sessionId: string): SessionRow | null {
    const row = this.db.prepare('SELECT * FROM sessions WHERE session_id = ?').get(sessionId) as Raw | undefined;
    if (!row) return null;
    return {
      sessionId: row.session_id as string,
      accountId: row.account_id as string,
      platform: row.platform as string,
      createdAt: row.created_at as number,
      expiresAt: row.expires_at as number,
      revokedAt: (row.revoked_at as number | null) ?? null
    };
  }

  touchSessionRefresh(sessionId: string, now: number): void {
    this.db.prepare('UPDATE sessions SET last_refreshed_at = ? WHERE session_id = ?').run(now, sessionId);
  }

  revokeSession(sessionId: string, reason: string, now: number): void {
    this.db
      .prepare('UPDATE sessions SET revoked_at = ?, revoke_reason = ? WHERE session_id = ? AND revoked_at IS NULL')
      .run(now, reason, sessionId);
    this.db
      .prepare("UPDATE refresh_tokens SET status = 'revoked' WHERE session_id = ? AND status = 'active'")
      .run(sessionId);
    // Access token rows are kept until expiry so introspection can report
    // `revoked` / `account_deleting` instead of an anonymous unknown token.
  }

  revokeAccountSessions(accountId: string, reason: string, now: number): number {
    const rows = this.db
      .prepare('SELECT session_id FROM sessions WHERE account_id = ? AND revoked_at IS NULL')
      .all(accountId) as Array<{ session_id: string }>;
    for (const row of rows) this.revokeSession(row.session_id, reason, now);
    return rows.length;
  }

  insertAccessToken(tokenHash: string, sessionId: string, now: number, expiresAt: number): void {
    this.db
      .prepare('INSERT INTO access_tokens (token_hash, session_id, created_at, expires_at) VALUES (?, ?, ?, ?)')
      .run(tokenHash, sessionId, now, expiresAt);
  }

  lookupAccessToken(tokenHash: string): AccessTokenLookup | null {
    const row = this.db
      .prepare(
        `SELECT t.session_id, t.expires_at, s.expires_at AS session_expires_at, s.revoked_at,
                a.account_id, a.status, a.auth_mode
           FROM access_tokens t
           JOIN sessions s ON s.session_id = t.session_id
           JOIN accounts a ON a.account_id = s.account_id
          WHERE t.token_hash = ?`
      )
      .get(tokenHash) as Raw | undefined;
    if (!row) return null;
    return {
      sessionId: row.session_id as string,
      expiresAt: row.expires_at as number,
      sessionExpiresAt: row.session_expires_at as number,
      sessionRevokedAt: (row.revoked_at as number | null) ?? null,
      accountId: row.account_id as string,
      accountStatus: row.status as AccountStatus,
      authMode: row.auth_mode as AuthMode
    };
  }

  pruneAccessTokens(now: number): number {
    return Number(this.db.prepare('DELETE FROM access_tokens WHERE expires_at < ?').run(now).changes);
  }

  insertRefreshToken(tokenId: string, tokenHash: string, sessionId: string, parentTokenId: string | null, now: number): void {
    this.db
      .prepare(
        `INSERT INTO refresh_tokens (token_id, token_hash, session_id, parent_token_id, status, created_at)
         VALUES (?, ?, ?, ?, 'active', ?)`
      )
      .run(tokenId, tokenHash, sessionId, parentTokenId, now);
  }

  getRefreshTokenByHash(tokenHash: string): RefreshTokenRow | null {
    const row = this.db.prepare('SELECT * FROM refresh_tokens WHERE token_hash = ?').get(tokenHash) as Raw | undefined;
    return row ? this.toRefresh(row) : null;
  }

  activeChildOf(tokenId: string): RefreshTokenRow | null {
    const row = this.db
      .prepare("SELECT * FROM refresh_tokens WHERE parent_token_id = ? AND status = 'active' LIMIT 1")
      .get(tokenId) as Raw | undefined;
    return row ? this.toRefresh(row) : null;
  }

  markRefreshRotated(tokenId: string, now: number): void {
    this.db.prepare("UPDATE refresh_tokens SET status = 'rotated', rotated_at = ? WHERE token_id = ?").run(now, tokenId);
  }

  markRefreshSuperseded(tokenId: string): void {
    this.db.prepare("UPDATE refresh_tokens SET status = 'superseded' WHERE token_id = ?").run(tokenId);
  }

  countActiveRefreshTokens(sessionId: string): number {
    const row = this.db
      .prepare("SELECT COUNT(*) AS n FROM refresh_tokens WHERE session_id = ? AND status = 'active'")
      .get(sessionId) as { n: number };
    return row.n;
  }

  private toRefresh(row: Raw): RefreshTokenRow {
    return {
      tokenId: row.token_id as string,
      sessionId: row.session_id as string,
      parentTokenId: (row.parent_token_id as string | null) ?? null,
      status: row.status as RefreshTokenStatus,
      rotatedAt: (row.rotated_at as number | null) ?? null
    };
  }

  // Deletions ----------------------------------------------------------------

  insertDeletion(row: DeletionRow): void {
    this.db
      .prepare(
        `INSERT INTO account_deletions (deletion_id, account_id, status, steps_json, apple_client_id,
           apple_refresh_token_enc, attempts, next_attempt_at, last_error_code, requested_at, completed_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        row.deletionId,
        row.accountId,
        row.status,
        JSON.stringify(row.steps),
        row.appleClientId,
        row.appleRefreshTokenEnc,
        row.attempts,
        row.nextAttemptAt,
        row.lastErrorCode,
        row.requestedAt,
        row.completedAt
      );
  }

  getDeletionForAccount(accountId: string): DeletionRow | null {
    const row = this.db.prepare('SELECT * FROM account_deletions WHERE account_id = ?').get(accountId) as Raw | undefined;
    return row ? toDeletion(row) : null;
  }

  dueDeletions(now: number, limit: number): DeletionRow[] {
    const rows = this.db
      .prepare(
        `SELECT * FROM account_deletions
          WHERE status != 'completed' AND next_attempt_at <= ?
          ORDER BY next_attempt_at ASC LIMIT ?`
      )
      .all(now, limit) as Raw[];
    return rows.map(toDeletion);
  }

  saveDeletionProgress(row: DeletionRow): void {
    this.db
      .prepare(
        `UPDATE account_deletions
            SET status = ?, steps_json = ?, attempts = ?, next_attempt_at = ?, last_error_code = ?,
                apple_refresh_token_enc = ?, completed_at = ?
          WHERE deletion_id = ?`
      )
      .run(
        row.status,
        JSON.stringify(row.steps),
        row.attempts,
        row.nextAttemptAt,
        row.lastErrorCode,
        row.appleRefreshTokenEnc,
        row.completedAt,
        row.deletionId
      );
  }

  listTombstones(): Array<{ accountId: string; completedAt: number | null }> {
    const rows = this.db.prepare('SELECT account_id, completed_at FROM account_deletions ORDER BY requested_at').all() as Raw[];
    return rows.map((row) => ({ accountId: row.account_id as string, completedAt: (row.completed_at as number | null) ?? null }));
  }
}
