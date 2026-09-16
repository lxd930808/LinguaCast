import { DomainError } from '../domain/types.js';

export type DnsLookup = (hostname: string) => Promise<string[]>;

const BLOCKED_HOSTS = new Set([
  'localhost',
  'metadata.google.internal',
  'metadata.internal',
  'instance-data'
]);

const ALLOWED_SCHEMES = new Set(['http:', 'https:']);
const MAX_REDIRECTS = 3;

export function canonicalUrl(raw: string): string {
  const url = new URL(raw);
  url.hash = '';
  url.hostname = url.hostname.toLowerCase();
  const params = [...url.searchParams.entries()].filter(([key]) => !key.toLowerCase().startsWith('utm_'));
  url.search = '';
  for (const [key, value] of params.sort((left, right) => left[0].localeCompare(right[0]))) {
    url.searchParams.append(key, value);
  }
  return url.toString().replace(/\/$/, url.pathname === '/' ? '/' : '');
}

export function isPrivateIPv4(address: string): boolean {
  const parts = address.split('.').map((part) => Number(part));
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return false;
  }
  const [a, b] = parts as [number, number, number, number];
  if (a === 10 || a === 127 || a === 0) return true;
  if (a === 169 && b === 254) return true;
  if (a === 192 && b === 168) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 100 && b >= 64 && b <= 127) return true;
  return false;
}

export function isBlockedAddress(address: string): boolean {
  const lower = address.toLowerCase();
  if (lower === '::1' || lower.startsWith('fe80:') || lower.startsWith('fc') || lower.startsWith('fd')) return true;
  if (lower.startsWith('::ffff:')) {
    return isPrivateIPv4(lower.slice('::ffff:'.length));
  }
  return isPrivateIPv4(lower);
}

export function assertHttpUrl(raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new DomainError('WEB_URL_BLOCKED', 'URL is not valid', false, 400);
  }
  if (!ALLOWED_SCHEMES.has(url.protocol)) {
    throw new DomainError('WEB_URL_BLOCKED', 'URL scheme is not allowed', false, 400);
  }
  if (url.username || url.password) {
    throw new DomainError('WEB_URL_BLOCKED', 'URL credentials are not allowed', false, 400);
  }
  const host = url.hostname.toLowerCase();
  if (
    BLOCKED_HOSTS.has(host) ||
    host.endsWith('.local') ||
    host.endsWith('.localhost') ||
    host.endsWith('.internal') ||
    isPrivateIPv4(host)
  ) {
    throw new DomainError('WEB_URL_BLOCKED', 'URL host is not allowed', false, 400);
  }
  return url;
}

export async function assertPublicResolvedUrl(raw: string, lookup: DnsLookup): Promise<URL> {
  const url = assertHttpUrl(raw);
  let addresses: string[];
  try {
    addresses = await lookup(url.hostname);
  } catch {
    throw new DomainError('WEB_URL_BLOCKED', 'URL host could not be resolved', false, 400);
  }
  if (addresses.length === 0 || addresses.some((address) => isBlockedAddress(address))) {
    throw new DomainError('WEB_URL_BLOCKED', 'URL resolved to a private or metadata address', false, 400);
  }
  return url;
}

export function resolveRedirect(current: URL, location: string | null): URL {
  if (!location) {
    throw new DomainError('WEB_URL_BLOCKED', 'redirect location is missing', false, 400);
  }
  return new URL(location, current);
}

export { MAX_REDIRECTS };
