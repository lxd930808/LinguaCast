import { createHash } from 'node:crypto';

/**
 * Reference implementation of docs/contracts/content-keys-v1.md.
 * Golden vectors live in fixtures/contract/content-key-vectors.json and are
 * mirrored into the iOS test fixtures; Swift must produce identical output.
 */

function sha256hex(input: string): string {
  return createHash('sha256').update(input, 'utf8').digest('hex');
}

export function normalizeFeedUrl(raw: string): string {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error(`INVALID_FEED_URL`);
  }
  const scheme = url.protocol.replace(':', '').toLowerCase();
  if (scheme !== 'http' && scheme !== 'https') {
    throw new Error(`INVALID_FEED_SCHEME`);
  }
  const host = url.hostname.toLowerCase();
  let port = url.port;
  if ((scheme === 'http' && port === '80') || (scheme === 'https' && port === '443')) {
    port = '';
  }
  let path = url.pathname.normalize('NFC');
  if (path.length > 1 && path.endsWith('/')) {
    path = path.slice(0, -1);
  }
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

export interface DedupeKeyInput {
  ownerScope: string;
  contentType: 'podcast_episode' | 'video';
  contentKey: string;
  sourceLanguage: string;
  targetLanguage: string;
  translationQuality: 'fast' | 'quality';
  pipelineVersion: string;
}

export function dedupeKey(input: DedupeKeyInput): string {
  return sha256hex(
    [
      input.ownerScope,
      input.contentType,
      input.contentKey,
      input.sourceLanguage.normalize('NFC'),
      input.targetLanguage.normalize('NFC'),
      input.translationQuality,
      input.pipelineVersion
    ].join('\n')
  );
}
