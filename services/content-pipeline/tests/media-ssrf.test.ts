import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  assertPublicUrl,
  blockedAddressReason,
  parseIpv6,
  SsrfBlockedError
} from '../src/media/ssrf.js';

// SSRF guard unit tests (WP4). No network: DNS is always injected.

test('IPv4 private, loopback, link-local and reserved ranges are blocked', () => {
  const blocked = [
    '0.0.0.0',
    '10.0.0.1',
    '10.255.255.255',
    '127.0.0.1',
    '127.1.2.3',
    '169.254.0.1',
    '172.16.0.1',
    '172.31.255.255',
    '192.168.1.1',
    '100.64.0.1',
    '100.127.255.255',
    '192.0.2.1',
    '198.18.0.1',
    '198.51.100.1',
    '203.0.113.1',
    '224.0.0.1',
    '240.0.0.1',
    '255.255.255.255'
  ];
  for (const ip of blocked) {
    assert.ok(blockedAddressReason(ip) !== null, `${ip} should be blocked`);
  }
});

test('IPv4 public addresses pass, range edges are exact', () => {
  const allowed = ['8.8.8.8', '1.1.1.1', '172.15.255.255', '172.32.0.0', '100.63.255.255', '100.128.0.0', '11.0.0.0'];
  for (const ip of allowed) {
    assert.equal(blockedAddressReason(ip), null, `${ip} should be allowed`);
  }
});

test('IPv6 parser handles compressed and embedded forms', () => {
  assert.deepEqual(parseIpv6('::1'), [0, 0, 0, 0, 0, 0, 0, 1]);
  assert.deepEqual(parseIpv6('::ffff:127.0.0.1'), [0, 0, 0, 0, 0, 0xffff, 0x7f00, 1]);
  assert.deepEqual(parseIpv6('2001:db8::1'), [0x2001, 0x0db8, 0, 0, 0, 0, 0, 1]);
  assert.equal(parseIpv6(':::'), null);
  assert.equal(parseIpv6('12345::'), null);
});

test('IPv6 loopback, ULA, link-local, multicast, mapped and NAT64 are blocked', () => {
  const blocked = [
    '::',
    '::1',
    'fe80::1',
    'fc00::1',
    'fd00::abcd',
    'ff02::1',
    '::ffff:127.0.0.1',
    '::ffff:10.1.2.3',
    '64:ff9b::127.0.0.1',
    '2001:db8::1'
  ];
  for (const ip of blocked) {
    assert.ok(blockedAddressReason(ip) !== null, `${ip} should be blocked`);
  }
  assert.equal(blockedAddressReason('2606:4700:4700::1111'), null);
  assert.equal(blockedAddressReason('::ffff:8.8.8.8'), null);
  assert.equal(blockedAddressReason('64:ff9b::8.8.8.8'), null);
});

test('non-http(s) schemes are rejected', async () => {
  for (const url of ['file:///etc/passwd', 'ftp://example.com/x', 'gopher://x/']) {
    await assert.rejects(
      assertPublicUrl(new URL(url)),
      (error: unknown) => error instanceof SsrfBlockedError
    );
  }
});

test('literal private IPs are blocked without DNS', async () => {
  await assert.rejects(assertPublicUrl(new URL('http://127.0.0.1:8080/x')), SsrfBlockedError);
  await assert.rejects(assertPublicUrl(new URL('http://[::1]/x')), SsrfBlockedError);
  await assert.rejects(assertPublicUrl(new URL('http://[fe80::1]/x')), SsrfBlockedError);
  await assert.rejects(assertPublicUrl(new URL('http://192.168.0.1/x')), SsrfBlockedError);
});

test('localhost names are always blocked', async () => {
  await assert.rejects(assertPublicUrl(new URL('http://localhost/x')), SsrfBlockedError);
  await assert.rejects(assertPublicUrl(new URL('http://evil.localhost/x')), SsrfBlockedError);
});

test('DNS rebinding: a hostname resolving to a private address is blocked', async () => {
  const lookup = async () => ['127.0.0.1'];
  await assert.rejects(
    assertPublicUrl(new URL('https://rebinding.example.com/podcast.mp3'), { lookup }),
    (error: unknown) => error instanceof SsrfBlockedError && /127\.0\.0\.0\/8|loopback/.test(error.message)
  );
});

test('a hostname resolving to any private address among public ones is blocked', async () => {
  const lookup = async () => ['8.8.8.8', '192.168.1.1'];
  await assert.rejects(
    assertPublicUrl(new URL('https://mixed.example.com/'), { lookup }),
    SsrfBlockedError
  );
});

test('public resolution passes and allowAddress test seam works', async () => {
  const lookup = async () => ['93.184.216.34'];
  await assertPublicUrl(new URL('https://example.com/feed.mp3'), { lookup });

  // Test seam used by the downloader suite to reach the loopback fixture server.
  await assertPublicUrl(new URL('http://127.0.0.1:9999/x'), {
    allowAddress: (ip) => ip === '127.0.0.1'
  });
});

test('DNS failure is a blocked error, not a silent pass', async () => {
  const lookup = async () => {
    throw new Error('ENOTFOUND');
  };
  await assert.rejects(
    assertPublicUrl(new URL('https://missing.example.com/'), { lookup }),
    SsrfBlockedError
  );
});
