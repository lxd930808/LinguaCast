import assert from 'node:assert/strict';
import { test } from 'node:test';

import { DomainError } from '../../src/domain/types.js';
import { assertPublicHttpsUrl, fetchRssEpisodes, type HttpGet } from '../../src/search/providers.js';

const FEED = `<?xml version="1.0"?>
<rss><channel>
<item><title>Episode One</title><guid>ep-1</guid><link>https://feeds.example.com/ep1</link><enclosure url="https://cdn.example.com/ep1.mp3" type="audio/mpeg"/><pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate><description>Hello</description></item>
</channel></rss>`;

const FEED_NO_ENCLOSURE = `<?xml version="1.0"?>
<rss><channel>
<item><title>Episode Two</title><guid>ep-2</guid><link>https://feeds.example.com/ep2</link></item>
</channel></rss>`;

test('RSS episodes are parsed from XML text rather than JSON', async () => {
  const httpGet: HttpGet = async () => ({ status: 200, json: null, text: FEED });
  const hits = await fetchRssEpisodes('https://feeds.example.com/show.xml', 5, httpGet);
  assert.equal(hits.length, 1);
  assert.equal(hits[0]?.sourceId, 'ep-1');
  assert.equal(hits[0]?.sourceType, 'podcast_episode');
  assert.equal(hits[0]?.deepResearchAvailability, 'available');
});

test('private RSS hosts are blocked before fetch', () => {
  assert.throws(() => assertPublicHttpsUrl('http://127.0.0.1/feed.xml'), (error: unknown) => {
    return error instanceof DomainError && error.code === 'SOURCE_URL_BLOCKED';
  });
  assert.throws(() => assertPublicHttpsUrl('http://192.168.1.9/feed.xml'), (error: unknown) => {
    return error instanceof DomainError && error.code === 'SOURCE_URL_BLOCKED';
  });
  assert.throws(() => assertPublicHttpsUrl('http://169.254.169.254/latest/meta-data'), (error: unknown) => {
    return error instanceof DomainError && error.code === 'SOURCE_URL_BLOCKED';
  });
});

test('RSS episodes without enclosure are not researchable', async () => {
  const httpGet: HttpGet = async () => ({ status: 200, json: null, text: FEED_NO_ENCLOSURE });
  const hits = await fetchRssEpisodes('https://feeds.example.com/show.xml', 5, httpGet);
  assert.equal(hits[0]?.deepResearchAvailability, 'unavailable');
  assert.ok(hits[0]?.warnings.includes('missing_enclosure'));
});

test('RSS document with external entities is rejected', async () => {
  const httpGet: HttpGet = async () => ({
    status: 200,
    json: null,
    text: `<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><rss><channel><item><title>&xxe;</title></item></channel></rss>`
  });
  await assert.rejects(
    () => fetchRssEpisodes('https://feeds.example.com/show.xml', 3, httpGet),
    (error: unknown) => error instanceof DomainError && error.code === 'SOURCE_URL_BLOCKED'
  );
});

test('RSS redirects are not followed automatically', async () => {
  const httpGet: HttpGet = async () => ({ status: 302, json: null, text: '' });
  await assert.rejects(
    () => fetchRssEpisodes('https://feeds.example.com/show.xml', 3, httpGet),
    (error: unknown) => error instanceof DomainError && error.code === 'SOURCE_URL_BLOCKED'
  );
});
