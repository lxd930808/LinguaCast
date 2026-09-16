import { createHash } from 'node:crypto';

function sha256hex(input: string): string {
  return createHash('sha256').update(input, 'utf8').digest('hex');
}

export function normalizeFeedUrl(raw: string): string {
  const url = new URL(raw);
  const scheme = url.protocol.replace(':', '').toLowerCase();
  if (scheme !== 'http' && scheme !== 'https') throw new Error('INVALID_FEED_SCHEME');
  const host = url.hostname.toLowerCase();
  let port = url.port;
  if ((scheme === 'http' && port === '80') || (scheme === 'https' && port === '443')) port = '';
  let path = url.pathname.normalize('NFC');
  if (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1);
  const query = url.search.normalize('NFC');
  return `${scheme}://${host}${port ? `:${port}` : ''}${path}${query}`;
}

export function podcastContentKey(feedUrl: string, episodeGuid: string): string {
  const feed = normalizeFeedUrl(feedUrl);
  const guid = episodeGuid.normalize('NFC').trim();
  return `podcast:${sha256hex(feed).slice(0, 16)}:${sha256hex(guid).slice(0, 16)}`;
}

export function videoContentKey(platform: string, videoId: string): string {
  return `video:${platform.toLowerCase()}:${videoId.normalize('NFC').trim()}`;
}

export function playerDeepLink(contentKey: string, startMs: number): string {
  return `linguacast://play?content_key=${encodeURIComponent(contentKey)}&start_ms=${Math.max(0, Math.floor(startMs))}`;
}
