import type { R2Config } from '../config.js';

/**
 * Object key layout. Every key lives under
 *   {prefix}/{environment}/{category}/...
 * and the yt-media prefix of the existing media service is never touched.
 */

export type ObjectCategory =
  | 'podcast-audio'
  | 'video-audio'
  | 'video-media'
  | 'source-transcripts'
  | 'translations'
  | 'manifests'
  | 'backups'
  | 'canary';

export class KeyPolicyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'KeyPolicyError';
  }
}

export const SELFHOST_OWNER = 'selfhost';
const ACCOUNT_OWNER = /^acc_[0-9A-HJKMNP-TV-Z]{26}$/;

export class KeyLayout {
  readonly base: string;
  private readonly canaryBase: string;
  private readonly config: Pick<R2Config, 'prefix' | 'environment'>;

  constructor(config: Pick<R2Config, 'prefix' | 'environment'>, accountId: string | null = null) {
    this.config = config;
    const root = `${config.prefix}/${config.environment}`;
    this.base = accountId === null ? root : `${root}/accounts/${accountId}`;
    this.canaryBase = `${root}/canary`;
    if (config.prefix === 'yt-media' || config.prefix.startsWith('yt-media/')) {
      throw new KeyPolicyError('content pipeline must not use the yt-media prefix');
    }
  }

  /**
   * Layout for objects owned by one account. Signed-in accounts (acc_) write
   * under {prefix}/{environment}/accounts/{accountId}/ so objects, caches and
   * account purges never cross accounts. The selfhost owner and any pre-V18
   * owner scope keep the legacy root layout so existing objects stay valid.
   */
  forAccount(ownerScope: string): KeyLayout {
    return ACCOUNT_OWNER.test(ownerScope) ? new KeyLayout(this.config, ownerScope) : new KeyLayout(this.config);
  }

  static isAccountOwner(ownerScope: string): boolean {
    return ownerScope !== SELFHOST_OWNER && ACCOUNT_OWNER.test(ownerScope);
  }

  /** Prefix holding every object of one account (never the legacy root). */
  accountPrefix(accountId: string): string {
    if (!ACCOUNT_OWNER.test(accountId)) throw new KeyPolicyError('account prefix requires an acc_ owner');
    return `${this.config.prefix}/${this.config.environment}/accounts/${accountId}/`;
  }

  /** Key for a job-scoped published artifact file (segments.json, *.vtt, manifest.json). */
  jobArtifact(jobId: string, fileName: string): string {
    assertSafeSegment(fileName, 'fileName');
    return `${this.base}/manifests/${jobId}/${fileName}`;
  }

  jobTempArtifact(jobId: string, fileName: string): string {
    assertSafeSegment(fileName, 'fileName');
    return `${this.base}/manifests/${jobId}/.tmp-${fileName}`;
  }

  podcastAudio(audioFingerprint: string): string {
    return `${this.base}/podcast-audio/${audioFingerprint}.mp3`;
  }

  videoAudio(audioFingerprint: string): string {
    return `${this.base}/video-audio/${audioFingerprint}.mp3`;
  }

  videoMediaTemp(mediaId: string): string {
    assertSafeSegment(mediaId, 'mediaId');
    return `${this.base}/video-media/.tmp/${mediaId}.mp4`;
  }

  videoMedia(sha256: string): string {
    if (!/^[0-9a-f]{64}$/.test(sha256)) {
      throw new KeyPolicyError(`video media fingerprint must be a 64-char sha256: ${sha256}`);
    }
    return `${this.base}/video-media/${sha256}.mp4`;
  }

  sourceTranscript(fingerprint: string): string {
    return `${this.base}/source-transcripts/${fingerprint}.json`;
  }

  backup(fileName: string): string {
    assertSafeSegment(fileName, 'fileName');
    return `${this.base}/backups/${fileName}`;
  }

  canary(name: string): string {
    assertSafeSegment(name, 'name');
    return `${this.canaryBase}/${name}`;
  }

  /** All keys this service may ever write. */
  assertAllowed(key: string): void {
    if (!key.startsWith(`${this.base}/`)) {
      throw new KeyPolicyError(`object key outside content-pipeline prefix: ${key}`);
    }
  }

  /** Canary operations may ONLY touch the canary prefix. */
  assertCanary(key: string): void {
    if (!key.startsWith(`${this.canaryBase}/`)) {
      throw new KeyPolicyError(`canary operation outside canary prefix: ${key}`);
    }
  }
}

function assertSafeSegment(value: string, label: string): void {
  if (!/^[A-Za-z0-9._-]+$/.test(value)) {
    throw new KeyPolicyError(`${label} contains unsafe characters: ${value}`);
  }
}
