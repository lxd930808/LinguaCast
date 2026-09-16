import type { AppleClient } from '../apple/apple-client.js';
import type { AuthMode, ServiceConfig } from '../config.js';
import {
  ACCESS_TOKEN_PREFIX,
  REFRESH_TOKEN_PREFIX,
  SecretBox,
  constantTimeEqual,
  newNonce,
  newOpaqueToken,
  sha256Hex
} from '../crypto/tokens.js';
import { AccountError, authModeUnsupported } from '../domain/errors.js';
import {
  SELFHOST_ACCOUNT_ID,
  newAccountId,
  newChallengeId,
  newDeletionId,
  newRefreshTokenId,
  newSessionId
} from '../domain/ids.js';
import type { AccountRow, AccountStore, DeletionStep } from '../store/account-store.js';

export type Platform = 'ios' | 'ipados' | 'tvos';
export const PLATFORMS: readonly Platform[] = ['ios', 'ipados', 'tvos'];

export interface RequestIdentity {
  accountId: string;
  authMode: AuthMode;
  sessionId: string | null;
}

export type InactiveReason = 'unknown' | 'expired' | 'revoked' | 'account_disabled' | 'account_deleting';

export type IntrospectResult =
  | { active: true; identity: RequestIdentity }
  | { active: false; inactiveReason: InactiveReason };

export interface AccountSummaryBody {
  accountId: string;
  authMode: AuthMode;
  status: 'active' | 'disabled' | 'deleting';
  createdAt: string;
}

export interface SessionTokensBody {
  accessToken: string;
  accessTokenExpiresAt: string;
  refreshToken: string;
  sessionExpiresAt: string;
  sessionId: string;
  account: AccountSummaryBody;
}

export interface ExchangeInput {
  challengeId: string;
  identityToken: string;
  authorizationCode: string;
  platform: Platform;
  deviceName: string | null;
}

export interface AuthServiceDeps {
  config: ServiceConfig;
  store: AccountStore;
  apple: AppleClient | null;
  secretBox: SecretBox | null;
  now: () => number;
}

const iso = (ms: number): string => new Date(ms).toISOString();

export function accountSummary(account: AccountRow): AccountSummaryBody {
  const status = account.status === 'deleted' ? 'deleting' : account.status;
  return { accountId: account.accountId, authMode: account.authMode, status, createdAt: iso(account.createdAt) };
}

function blockedAccountError(account: AccountRow): AccountError | null {
  if (account.status === 'disabled') return new AccountError(403, 'ACCOUNT_DISABLED', 'account is disabled');
  if (account.status === 'deleting' || account.status === 'deleted') {
    return new AccountError(403, 'ACCOUNT_DELETING', 'account deletion is in progress');
  }
  return null;
}

export function inactiveError(reason: InactiveReason): AccountError {
  switch (reason) {
    case 'expired':
      return new AccountError(401, 'ACCESS_TOKEN_EXPIRED', 'access token expired', true);
    case 'revoked':
      return new AccountError(401, 'SESSION_REVOKED', 'session was revoked');
    case 'account_disabled':
      return new AccountError(403, 'ACCOUNT_DISABLED', 'account is disabled');
    case 'account_deleting':
      return new AccountError(403, 'ACCOUNT_DELETING', 'account deletion is in progress');
    default:
      return new AccountError(401, 'AUTH_REQUIRED', 'missing or invalid credential');
  }
}

/** Identity, session and deletion rules from docs/contracts/account-v1-integration.md §1–§4. */
export class AuthService {
  constructor(private readonly deps: AuthServiceDeps) {}

  get authMode(): AuthMode {
    return this.deps.config.authMode;
  }

  createChallenge(platform: Platform): { challengeId: string; nonce: string; expiresAt: string } {
    this.requireApple();
    const now = this.deps.now();
    const nonce = newNonce();
    const challengeId = newChallengeId();
    const expiresAt = now + this.deps.config.challengeTtlSeconds * 1000;
    this.deps.store.insertChallenge({ challengeId, nonceHash: sha256Hex(nonce), platform, expiresAt }, now);
    return { challengeId, nonce, expiresAt: iso(expiresAt) };
  }

  async exchange(input: ExchangeInput): Promise<SessionTokensBody> {
    const apple = this.requireApple();
    const { store } = this.deps;
    const challenge = store.consumeChallenge(input.challengeId, this.deps.now());
    if (!challenge) throw new AccountError(400, 'CHALLENGE_INVALID', 'unknown challenge');
    if (challenge.consumedAt !== null) throw new AccountError(400, 'CHALLENGE_CONSUMED', 'challenge was already used');
    if (challenge.expiresAt <= this.deps.now()) throw new AccountError(400, 'CHALLENGE_EXPIRED', 'challenge expired');
    if (challenge.platform !== input.platform) {
      throw new AccountError(400, 'CHALLENGE_INVALID', 'challenge was created for another platform');
    }

    const identity = await apple.verifyIdentityToken(input.identityToken, challenge.nonceHash);
    const appleRefreshToken = await apple.redeemAuthorizationCode(input.authorizationCode, identity);
    const sealed = appleRefreshToken && this.deps.secretBox ? this.deps.secretBox.seal(appleRefreshToken) : null;

    const now = this.deps.now();
    const result = store.transaction(() => {
      const existing = store.findAppleIdentity(identity.sub);
      let account: AccountRow;
      if (existing) {
        const found = store.getAccount(existing.accountId);
        if (!found) throw new Error('apple identity references a missing account');
        const blocked = blockedAccountError(found);
        if (blocked) return { error: blocked };
        account = found;
        store.updateAppleIdentity(identity.sub, identity.clientId, sealed ?? existing.refreshTokenEnc, now);
      } else {
        account = store.createAccount(newAccountId(), 'apple', now);
        store.insertAppleIdentity(
          { appleSub: identity.sub, accountId: account.accountId, clientId: identity.clientId, refreshTokenEnc: sealed },
          now
        );
      }
      const sessionId = newSessionId();
      const sessionExpiresAt = now + this.deps.config.sessionMaxAgeSeconds * 1000;
      store.insertSession(
        { sessionId, accountId: account.accountId, platform: input.platform, createdAt: now, expiresAt: sessionExpiresAt },
        input.deviceName
      );
      return { body: this.issue(sessionId, sessionExpiresAt, null, account, now) };
    });
    if ('error' in result) throw result.error;
    return result.body;
  }

  refresh(refreshToken: string): SessionTokensBody {
    this.requireApple();
    const { store, config } = this.deps;
    const now = this.deps.now();
    const result = store.transaction((): { body: SessionTokensBody } | { error: AccountError } => {
      const row = refreshToken.startsWith(REFRESH_TOKEN_PREFIX)
        ? store.getRefreshTokenByHash(sha256Hex(refreshToken))
        : null;
      const invalid = new AccountError(401, 'REFRESH_TOKEN_INVALID', 'refresh token is invalid or expired');
      if (!row) return { error: invalid };
      const session = store.getSession(row.sessionId);
      const account = session ? store.getAccount(session.accountId) : null;
      if (!session || !account) return { error: invalid };
      const blocked = blockedAccountError(account);
      if (blocked) return { error: blocked };
      if (session.revokedAt !== null) {
        return { error: new AccountError(401, 'SESSION_REVOKED', 'session was revoked') };
      }
      if (session.expiresAt <= now) return { error: invalid };

      if (row.status === 'active') {
        store.markRefreshRotated(row.tokenId, now);
      } else {
        const child = row.status === 'rotated' ? store.activeChildOf(row.tokenId) : null;
        const withinGrace =
          child !== null && row.rotatedAt !== null && now - row.rotatedAt <= config.refreshGraceSeconds * 1000;
        if (!withinGrace || !child) {
          store.revokeSession(session.sessionId, 'refresh_reuse', now);
          return { error: new AccountError(401, 'REFRESH_TOKEN_REUSED', 'refresh token was already used') };
        }
        store.markRefreshSuperseded(child.tokenId);
      }
      store.touchSessionRefresh(session.sessionId, now);
      return { body: this.issue(session.sessionId, session.expiresAt, row.tokenId, account, now) };
    });
    if ('error' in result) throw result.error;
    return result.body;
  }

  logout(identity: RequestIdentity): void {
    if (identity.sessionId === null) return;
    this.deps.store.revokeSession(identity.sessionId, 'logout', this.deps.now());
  }

  introspect(token: string): IntrospectResult {
    const { config, store } = this.deps;
    if (config.authMode === 'selfhost') {
      const expected = config.selfhostAccessToken;
      return expected !== null && constantTimeEqual(token, expected)
        ? { active: true, identity: { accountId: SELFHOST_ACCOUNT_ID, authMode: 'selfhost', sessionId: null } }
        : { active: false, inactiveReason: 'unknown' };
    }
    if (!token.startsWith(ACCESS_TOKEN_PREFIX)) return { active: false, inactiveReason: 'unknown' };
    const row = store.lookupAccessToken(sha256Hex(token));
    if (!row) return { active: false, inactiveReason: 'unknown' };
    if (row.accountStatus === 'disabled') return { active: false, inactiveReason: 'account_disabled' };
    if (row.accountStatus === 'deleting' || row.accountStatus === 'deleted') {
      return { active: false, inactiveReason: 'account_deleting' };
    }
    if (row.sessionRevokedAt !== null) return { active: false, inactiveReason: 'revoked' };
    const now = this.deps.now();
    if (row.expiresAt <= now || row.sessionExpiresAt <= now) return { active: false, inactiveReason: 'expired' };
    return { active: true, identity: { accountId: row.accountId, authMode: row.authMode, sessionId: row.sessionId } };
  }

  authenticate(token: string | null): RequestIdentity {
    if (token === null) throw inactiveError('unknown');
    const result = this.introspect(token);
    if (!result.active) throw inactiveError(result.inactiveReason);
    return result.identity;
  }

  account(identity: RequestIdentity): AccountRow {
    const account = this.deps.store.getAccount(identity.accountId);
    if (!account) throw inactiveError('unknown');
    return account;
  }

  requestDeletion(identity: RequestIdentity): { deletionId: string; status: 'pending'; requestedAt: string } {
    if (this.authMode !== 'apple' || identity.authMode !== 'apple') throw authModeUnsupported();
    const { store, config } = this.deps;
    const now = this.deps.now();
    return store.transaction(() => {
      const existing = store.getDeletionForAccount(identity.accountId);
      if (existing) {
        return { deletionId: existing.deletionId, status: 'pending' as const, requestedAt: iso(existing.requestedAt) };
      }
      const appleIdentity = store.findAppleIdentityByAccount(identity.accountId);
      const steps: DeletionStep[] = config.purgeTargets.map((target) => ({
        name: `purge:${target.name}`,
        status: 'pending',
        attempts: 0
      }));
      if (appleIdentity?.refreshTokenEnc) steps.push({ name: 'apple-revoke', status: 'pending', attempts: 0 });
      const deletionId = newDeletionId();
      store.insertDeletion({
        deletionId,
        accountId: identity.accountId,
        status: 'pending',
        steps,
        appleClientId: appleIdentity?.clientId ?? null,
        appleRefreshTokenEnc: appleIdentity?.refreshTokenEnc ?? null,
        attempts: 0,
        nextAttemptAt: now,
        lastErrorCode: null,
        requestedAt: now,
        completedAt: null
      });
      store.setAccountStatus(identity.accountId, 'deleting', now);
      store.revokeAccountSessions(identity.accountId, 'account_deleted', now);
      store.deleteAppleIdentityForAccount(identity.accountId);
      return { deletionId, status: 'pending' as const, requestedAt: iso(now) };
    });
  }

  /** Must run inside a store transaction. */
  private issue(
    sessionId: string,
    sessionExpiresAt: number,
    parentTokenId: string | null,
    account: AccountRow,
    now: number
  ): SessionTokensBody {
    const { store, config } = this.deps;
    const accessToken = newOpaqueToken(ACCESS_TOKEN_PREFIX);
    const accessExpiresAt = Math.min(now + config.accessTokenTtlSeconds * 1000, sessionExpiresAt);
    store.insertAccessToken(sha256Hex(accessToken), sessionId, now, accessExpiresAt);
    const refreshToken = newOpaqueToken(REFRESH_TOKEN_PREFIX);
    store.insertRefreshToken(newRefreshTokenId(), sha256Hex(refreshToken), sessionId, parentTokenId, now);
    return {
      accessToken,
      accessTokenExpiresAt: iso(accessExpiresAt),
      refreshToken,
      sessionExpiresAt: iso(sessionExpiresAt),
      sessionId,
      account: accountSummary(account)
    };
  }

  private requireApple(): AppleClient {
    if (this.deps.config.authMode !== 'apple' || !this.deps.apple) throw authModeUnsupported();
    return this.deps.apple;
  }
}
