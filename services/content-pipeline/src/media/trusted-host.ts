import { lookup as dnsLookup } from 'node:dns/promises';

/**
 * Allow the configured media-api host (often loopback / host-gateway) so
 * promotion and audio copy can fetch playback.url / audioUrl without opening
 * a general SSRF hole. Other hosts keep the default public-only policy.
 */
export async function trustedMediaHostPolicy(
  mediaBaseUrl: string,
  mediaUrl: string
): Promise<{ allowAddress: (address: string) => boolean } | undefined> {
  const baseHost = new URL(mediaBaseUrl).hostname;
  let mediaHost: string;
  try {
    mediaHost = new URL(mediaUrl).hostname;
  } catch {
    throw new Error('media service returned an invalid URL');
  }
  if (mediaHost !== baseHost) return undefined;

  const trusted = new Set<string>();
  try {
    for (const entry of await dnsLookup(baseHost, { all: true, verbatim: true })) {
      trusted.add(entry.address);
    }
  } catch {
    // Downloader will re-resolve; an empty set means "allow whatever DNS returned".
  }
  return {
    allowAddress: (address) => trusted.size === 0 || trusted.has(address)
  };
}
