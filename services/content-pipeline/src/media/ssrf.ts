import { lookup as dnsLookup } from 'node:dns/promises';
import { isIP } from 'node:net';

// SSRF guard for outbound media downloads (WP4). Every hop of a redirect
// chain is validated: http(s) scheme only, hostname resolves exclusively to
// public unicast addresses. DNS results are re-checked on every redirect so a
// rebinding between hops is caught.

export class SsrfBlockedError extends Error {
  constructor(
    readonly reason: string,
    readonly host: string
  ) {
    super(`blocked request to ${host}: ${reason}`);
    this.name = 'SsrfBlockedError';
  }
}

export type LookupFn = (hostname: string) => Promise<string[]>;

const defaultLookup: LookupFn = async (hostname) => {
  const results = await dnsLookup(hostname, { all: true, verbatim: true });
  return results.map((r) => r.address);
};

/** Returns a reason string when the address is not public unicast, else null. */
export function blockedAddressReason(address: string): string | null {
  const family = isIP(address);
  if (family === 4) return blockedIpv4Reason(address);
  if (family === 6) return blockedIpv6Reason(address);
  return `not an IP address: ${address}`;
}

export function isPublicAddress(address: string): boolean {
  return blockedAddressReason(address) === null;
}

function parseIpv4(address: string): number[] | null {
  const parts = address.split('.');
  if (parts.length !== 4) return null;
  const octets = parts.map((p) => {
    if (!/^\d{1,3}$/.test(p)) return NaN;
    return Number(p);
  });
  if (octets.some((o) => Number.isNaN(o) || o > 255)) return null;
  return octets;
}

function blockedIpv4Reason(address: string): string | null {
  const octets = parseIpv4(address);
  if (!octets) return 'malformed IPv4 address';
  const [a, b] = octets;
  if (a === 0) return 'unspecified/this-host range 0.0.0.0/8';
  if (a === 10) return 'private range 10.0.0.0/8';
  if (a === 127) return 'loopback 127.0.0.0/8';
  if (a === 169 && b === 254) return 'link-local 169.254.0.0/16';
  if (a === 172 && b >= 16 && b <= 31) return 'private range 172.16.0.0/12';
  if (a === 192 && b === 168) return 'private range 192.168.0.0/16';
  if (a === 100 && b >= 64 && b <= 127) return 'carrier-grade NAT 100.64.0.0/10';
  if (a === 192 && b === 0) return 'reserved 192.0.0.0/24 (protocol assignments, TEST-NET-1/2)';
  if (a === 198 && (b === 18 || b === 19)) return 'benchmarking 198.18.0.0/15';
  if (a === 198 && b === 51) return 'TEST-NET-2 198.51.100.0/24';
  if (a === 203 && b === 0) return 'TEST-NET-3 203.0.113.0/24';
  if (a >= 224 && a <= 239) return 'multicast 224.0.0.0/4';
  if (a >= 240) return 'reserved 240.0.0.0/4';
  return null;
}

/**
 * Parses an IPv6 address (compressed forms allowed, embedded IPv4 allowed)
 * into eight 16-bit hextets, or null when malformed.
 */
export function parseIpv6(address: string): number[] | null {
  let input = address;
  // Zone identifiers (fe80::1%eth0) are link-local; keep parsing the address.
  const zoneIndex = input.indexOf('%');
  if (zoneIndex >= 0) input = input.slice(0, zoneIndex);

  let embeddedV4: number[] | null = null;
  const lastColon = input.lastIndexOf(':');
  if (lastColon >= 0 && input.includes('.')) {
    const tail = input.slice(lastColon + 1);
    embeddedV4 = parseIpv4(tail);
    if (!embeddedV4) return null;
    // Replace the IPv4 tail with two placeholder hextets; overwritten below.
    input = `${input.slice(0, lastColon)}:0:0`;
  }

  const halves = input.split('::');
  if (halves.length > 2) return null;

  const parseGroup = (group: string): number[] | null => {
    if (group === '') return [];
    const parts = group.split(':');
    const values: number[] = [];
    for (const part of parts) {
      if (!/^[0-9a-fA-F]{1,4}$/.test(part)) return null;
      values.push(parseInt(part, 16));
    }
    return values;
  };

  const head = parseGroup(halves[0]);
  const tail = halves.length === 2 ? parseGroup(halves[1]) : [];
  if (!head || !tail) return null;

  let hextets: number[];
  if (halves.length === 2) {
    const missing = 8 - head.length - tail.length;
    if (missing < 0) return null;
    hextets = [...head, ...new Array<number>(missing).fill(0), ...tail];
  } else {
    hextets = head;
    if (hextets.length !== 8) return null;
  }
  if (embeddedV4) {
    const [a, b, c, d] = embeddedV4;
    hextets[6] = (a << 8) | b;
    hextets[7] = (c << 8) | d;
  }
  if (hextets.length !== 8) return null;
  return hextets;
}

function blockedIpv6Reason(address: string): string | null {
  const h = parseIpv6(address);
  if (!h) return 'malformed IPv6 address';
  const [h0, h1, , , , , h6, h7] = h;
  const allZero = h.every((x) => x === 0);
  if (allZero) return 'unspecified address ::/128';
  if (h.every((x, i) => x === (i === 7 ? 1 : 0))) return 'loopback ::1/128';
  // IPv4-mapped ::ffff:a.b.c.d
  if (h0 === 0 && h1 === 0 && h[2] === 0 && h[3] === 0 && h[4] === 0 && h[5] === 0xffff) {
    const v4 = `${(h6 >> 8) & 0xff}.${h6 & 0xff}.${(h7 >> 8) & 0xff}.${h7 & 0xff}`;
    const reason = blockedIpv4Reason(v4);
    return reason ? `IPv4-mapped ${v4}: ${reason}` : null;
  }
  // NAT64 64:ff9b::/96 embeds an IPv4 address.
  if (h0 === 0x64 && h1 === 0xff9b && h[2] === 0 && h[3] === 0 && h[4] === 0) {
    const v4 = `${(h6 >> 8) & 0xff}.${h6 & 0xff}.${(h7 >> 8) & 0xff}.${h7 & 0xff}`;
    const reason = blockedIpv4Reason(v4);
    return reason ? `NAT64 ${v4}: ${reason}` : null;
  }
  if ((h0 & 0xffc0) === 0xfe80) return 'link-local fe80::/10';
  if ((h0 & 0xfe00) === 0xfc00) return 'unique local fc00::/7';
  if ((h0 & 0xff00) === 0xff00) return 'multicast ff00::/8';
  if (h0 === 0x2001 && h1 === 0x0db8) return 'documentation 2001:db8::/32';
  return null;
}

export interface SsrfCheckOptions {
  lookup?: LookupFn;
  /** Extra predicate for tests (e.g. allow the loopback fixture server). */
  allowAddress?: (address: string) => boolean;
}

/** Validates a URL's scheme and resolves its host, rejecting non-public IPs. */
export async function assertPublicUrl(url: URL, options: SsrfCheckOptions = {}): Promise<void> {
  if (url.protocol !== 'https:' && url.protocol !== 'http:') {
    throw new SsrfBlockedError(`scheme ${url.protocol} is not allowed`, url.hostname);
  }
  const host = url.hostname;
  if (host === '') throw new SsrfBlockedError('empty hostname', host);

  // Literal IPs skip DNS.
  const bare = host.startsWith('[') && host.endsWith(']') ? host.slice(1, -1) : host;
  if (isIP(bare) !== 0) {
    if (options.allowAddress?.(bare)) return;
    const reason = blockedAddressReason(bare);
    if (reason) throw new SsrfBlockedError(reason, bare);
    return;
  }

  if (host.toLowerCase() === 'localhost' || host.toLowerCase().endsWith('.localhost')) {
    throw new SsrfBlockedError('localhost names are not allowed', host);
  }

  const lookup = options.lookup ?? defaultLookup;
  let addresses: string[];
  try {
    addresses = await lookup(host);
  } catch (error) {
    throw new SsrfBlockedError(
      `DNS resolution failed: ${error instanceof Error ? error.message : String(error)}`,
      host
    );
  }
  if (addresses.length === 0) throw new SsrfBlockedError('DNS returned no addresses', host);
  for (const address of addresses) {
    if (options.allowAddress?.(address)) continue;
    const reason = blockedAddressReason(address);
    if (reason) throw new SsrfBlockedError(reason, host);
  }
}
