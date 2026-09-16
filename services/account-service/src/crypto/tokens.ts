import { createCipheriv, createDecipheriv, createHash, randomBytes, timingSafeEqual } from 'node:crypto';

export const ACCESS_TOKEN_PREFIX = 'lca_';
export const REFRESH_TOKEN_PREFIX = 'lcr_';

/** 256-bit opaque credential; only its SHA-256 digest is persisted. */
export function newOpaqueToken(prefix: string): string {
  return prefix + randomBytes(32).toString('base64url');
}

export function newNonce(): string {
  return randomBytes(32).toString('base64url');
}

export function sha256Hex(value: string): string {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

/** Constant-time comparison that does not leak length differences. */
export function constantTimeEqual(a: string, b: string): boolean {
  const da = createHash('sha256').update(a, 'utf8').digest();
  const db = createHash('sha256').update(b, 'utf8').digest();
  return timingSafeEqual(da, db);
}

/** AES-256-GCM sealing for third-party secrets stored at rest (Apple refresh tokens). */
export class SecretBox {
  constructor(private readonly key: Buffer) {
    if (key.length !== 32) throw new Error('SecretBox key must be 32 bytes');
  }

  seal(plaintext: string): string {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, iv);
    const ciphertext = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
    const tag = cipher.getAuthTag();
    return ['v1', iv.toString('base64url'), tag.toString('base64url'), ciphertext.toString('base64url')].join('.');
  }

  open(sealed: string): string {
    const [version, iv, tag, ciphertext] = sealed.split('.');
    if (version !== 'v1' || !iv || !tag || ciphertext === undefined) throw new Error('unsupported sealed value');
    const decipher = createDecipheriv('aes-256-gcm', this.key, Buffer.from(iv, 'base64url'));
    decipher.setAuthTag(Buffer.from(tag, 'base64url'));
    return Buffer.concat([decipher.update(Buffer.from(ciphertext, 'base64url')), decipher.final()]).toString('utf8');
  }
}
