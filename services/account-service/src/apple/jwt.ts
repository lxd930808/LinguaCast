import { sign, verify, type KeyObject } from 'node:crypto';

export interface DecodedJwt {
  header: Record<string, unknown>;
  payload: Record<string, unknown>;
  signingInput: string;
  signature: Buffer;
}

const SEGMENT = /^[A-Za-z0-9_-]+$/;

function decodeSegment(segment: string): Record<string, unknown> | null {
  try {
    const value = JSON.parse(Buffer.from(segment, 'base64url').toString('utf8')) as unknown;
    return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/** Structural decode only; callers must verify the signature before trusting claims. */
export function decodeJwt(token: string): DecodedJwt | null {
  const segments = token.split('.');
  if (segments.length !== 3) return null;
  const [headerSegment, payloadSegment, signatureSegment] = segments as [string, string, string];
  if (!SEGMENT.test(headerSegment) || !SEGMENT.test(payloadSegment) || !SEGMENT.test(signatureSegment)) {
    return null;
  }
  const header = decodeSegment(headerSegment);
  const payload = decodeSegment(payloadSegment);
  if (!header || !payload) return null;
  return {
    header,
    payload,
    signingInput: `${headerSegment}.${payloadSegment}`,
    signature: Buffer.from(signatureSegment, 'base64url')
  };
}

export function verifyRs256(jwt: DecodedJwt, key: KeyObject): boolean {
  try {
    return verify('RSA-SHA256', Buffer.from(jwt.signingInput), key, jwt.signature);
  } catch {
    return false;
  }
}

function encodeSegment(value: Record<string, unknown>): string {
  return Buffer.from(JSON.stringify(value), 'utf8').toString('base64url');
}

/** ES256 JWT with a raw (IEEE P1363) signature, as Apple requires for client secrets. */
export function signEs256Jwt(header: Record<string, unknown>, payload: Record<string, unknown>, key: KeyObject): string {
  const signingInput = `${encodeSegment(header)}.${encodeSegment(payload)}`;
  const signature = sign('sha256', Buffer.from(signingInput), { key, dsaEncoding: 'ieee-p1363' });
  return `${signingInput}.${signature.toString('base64url')}`;
}
