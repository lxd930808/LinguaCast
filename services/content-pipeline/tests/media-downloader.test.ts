import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createServer, type Server } from 'node:http';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import type { AddressInfo } from 'node:net';

import { downloadToFile } from '../src/media/downloader.js';
import { PipelineJobError } from '../src/jobs/worker.js';

// Downloader tests (WP4): a loopback fixture server exercises redirects,
// framing lies, truncation, MIME gating and size caps. The SSRF allowAddress
// seam admits only loopback so production rules stay in force.

const PAYLOAD = Buffer.from('x'.repeat(64 * 1024)); // 64 KiB

interface Fixture {
  server: Server;
  baseUrl: string;
  cleanup: () => Promise<void>;
  hits: Map<string, number>;
}

async function startServer(): Promise<Fixture> {
  const hits = new Map<string, number>();
  const server = createServer((req, res) => {
    const url = req.url ?? '/';
    hits.set(url, (hits.get(url) ?? 0) + 1);
    switch (url) {
      case '/ok.mp3':
        res.writeHead(200, {
          'content-type': 'audio/mpeg',
          'content-length': PAYLOAD.length
        });
        res.end(PAYLOAD);
        return;
      case '/no-length.mp3':
        res.writeHead(200, { 'content-type': 'audio/mpeg' });
        res.end(PAYLOAD); // chunked, no content-length
        return;
      case '/lies-long.mp3':
        res.writeHead(200, {
          'content-type': 'audio/mpeg',
          'content-length': PAYLOAD.length * 2 // claims more than it sends
        });
        res.end(PAYLOAD);
        return;
      case '/lies-short.mp3':
        res.writeHead(200, {
          'content-type': 'audio/mpeg',
          'content-length': 10
        });
        res.end(PAYLOAD);
        return;
      case '/wrong-mime':
        res.writeHead(200, { 'content-type': 'text/html', 'content-length': PAYLOAD.length });
        res.end(PAYLOAD);
        return;
      case '/s3-octet.mp3':
        // S3/CloudFront legacy spelling used by Substack-hosted feeds.
        res.writeHead(200, {
          'content-type': 'binary/octet-stream',
          'content-length': PAYLOAD.length
        });
        res.end(PAYLOAD);
        return;
      case '/missing':
        res.writeHead(404).end();
        return;
      case '/forbidden':
        res.writeHead(403).end();
        return;
      case '/throttled':
        res.writeHead(429, { 'retry-after': '17' }).end();
        return;
      case '/redirect-1':
        res.writeHead(302, { location: '/redirect-2' }).end();
        return;
      case '/redirect-2':
        res.writeHead(302, { location: '/ok.mp3' }).end();
        return;
      case '/redirect-private':
        res.writeHead(302, { location: 'http://10.0.0.9/internal.mp3' }).end();
        return;
      case '/redirect-localhost':
        res.writeHead(302, { location: 'http://localhost:1/x.mp3' }).end();
        return;
      case '/redirect-loop':
        res.writeHead(302, { location: '/redirect-loop' }).end();
        return;
      case '/stall.mp3':
        res.writeHead(200, { 'content-type': 'audio/mpeg', 'content-length': PAYLOAD.length });
        res.write(PAYLOAD.subarray(0, 100));
        // Never send the rest; the idle timeout must fire.
        return;
      default:
        res.writeHead(500).end();
    }
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as AddressInfo).port;
  return {
    server,
    baseUrl: `http://127.0.0.1:${port}`,
    hits,
    cleanup: async () => {
      await new Promise((resolve) => server.close(resolve));
    }
  };
}

async function tempTarget(): Promise<{ dir: string; file: string }> {
  const dir = await mkdtemp(join(tmpdir(), 'download-test-'));
  return { dir, file: join(dir, 'out.bin') };
}

const LOOPBACK_ONLY = { allowAddress: (ip: string) => ip === '127.0.0.1' || ip === '::1' };

async function expectJobError(
  promise: Promise<unknown>,
  code: string
): Promise<PipelineJobError> {
  try {
    await promise;
  } catch (error) {
    assert.ok(error instanceof PipelineJobError, `expected PipelineJobError, got ${error}`);
    assert.equal(error.jobError.code, code);
    return error;
  }
  assert.fail(`expected ${code}, but the call succeeded`);
}

test('happy path streams bytes and computes sha256', async () => {
  const fx = await startServer();
  const { dir, file } = await tempTarget();
  try {
    const result = await downloadToFile(`${fx.baseUrl}/ok.mp3`, file, {
      maxBytes: 1024 * 1024,
      ssrf: LOOPBACK_ONLY
    });
    assert.equal(result.bytes, PAYLOAD.length);
    assert.equal(result.sha256, createHash('sha256').update(PAYLOAD).digest('hex'));
    assert.equal(result.contentType, 'audio/mpeg');
    assert.deepEqual(await readFile(file), PAYLOAD);
  } finally {
    await fx.cleanup();
    await rm(dir, { recursive: true, force: true });
  }
});

test('missing content-length still downloads within the byte cap', async () => {
  const fx = await startServer();
  const { dir, file } = await tempTarget();
  try {
    const result = await downloadToFile(`${fx.baseUrl}/no-length.mp3`, file, {
      maxBytes: 1024 * 1024,
      ssrf: LOOPBACK_ONLY
    });
    assert.equal(result.bytes, PAYLOAD.length);
  } finally {
    await fx.cleanup();
    await rm(dir, { recursive: true, force: true });
  }
});

test('a lying content-length (truncated body) fails retryably', async () => {
  const fx = await startServer();
  const { dir, file } = await tempTarget();
  try {
    const error = await expectJobError(
      downloadToFile(`${fx.baseUrl}/lies-long.mp3`, file, {
        maxBytes: 1024 * 1024,
        ssrf: LOOPBACK_ONLY
      }),
      'AUDIO_DOWNLOAD_FAILED'
    );
    assert.equal(error.jobError.retryable, true);
  } finally {
    await fx.cleanup();
    await rm(dir, { recursive: true, force: true });
  }
});

test('declared length above the cap aborts before streaming', async () => {
  const fx = await startServer();
  const { dir, file } = await tempTarget();
  try {
    const error = await expectJobError(
      downloadToFile(`${fx.baseUrl}/ok.mp3`, file, {
        maxBytes: 1024,
        ssrf: LOOPBACK_ONLY
      }),
      'MEDIA_TOO_LARGE'
    );
    assert.equal(error.jobError.retryable, false);
  } finally {
    await fx.cleanup();
    await rm(dir, { recursive: true, force: true });
  }
});

test('an unannounced oversize stream is cut at the cap', async () => {
  const fx = await startServer();
  const { dir, file } = await tempTarget();
  try {
    await expectJobError(
      downloadToFile(`${fx.baseUrl}/no-length.mp3`, file, {
        maxBytes: 1024,
        ssrf: LOOPBACK_ONLY
      }),
      'MEDIA_TOO_LARGE'
    );
  } finally {
    await fx.cleanup();
    await rm(dir, { recursive: true, force: true });
  }
});

test('wrong MIME is rejected as unsupported', async () => {
  const fx = await startServer();
  const { dir, file } = await tempTarget();
  try {
    await expectJobError(
      downloadToFile(`${fx.baseUrl}/wrong-mime`, file, {
        maxBytes: 1024 * 1024,
        ssrf: LOOPBACK_ONLY
      }),
      'UNSUPPORTED_AUDIO'
    );
  } finally {
    await fx.cleanup();
    await rm(dir, { recursive: true, force: true });
  }
});

test('binary/octet-stream from S3 is accepted', async () => {
  const fx = await startServer();
  const { dir, file } = await tempTarget();
  try {
    const result = await downloadToFile(`${fx.baseUrl}/s3-octet.mp3`, file, {
      maxBytes: 1024 * 1024,
      ssrf: LOOPBACK_ONLY
    });
    assert.equal(result.bytes, PAYLOAD.length);
    assert.equal(result.contentType, 'binary/octet-stream');
  } finally {
    await fx.cleanup();
    await rm(dir, { recursive: true, force: true });
  }
});

test('HTTP status mapping: 404, 403, 429', async () => {
  const fx = await startServer();
  const { dir, file } = await tempTarget();
  try {
    await expectJobError(
      downloadToFile(`${fx.baseUrl}/missing`, file, { maxBytes: 1 << 20, ssrf: LOOPBACK_ONLY }),
      'SOURCE_UNAVAILABLE'
    );
    await expectJobError(
      downloadToFile(`${fx.baseUrl}/forbidden`, file, { maxBytes: 1 << 20, ssrf: LOOPBACK_ONLY }),
      'SOURCE_RESTRICTED'
    );
    const throttled = await expectJobError(
      downloadToFile(`${fx.baseUrl}/throttled`, file, { maxBytes: 1 << 20, ssrf: LOOPBACK_ONLY }),
      'SOURCE_RATE_LIMITED'
    );
    assert.equal(throttled.jobError.retryAfterSeconds, 17);
  } finally {
    await fx.cleanup();
    await rm(dir, { recursive: true, force: true });
  }
});

test('redirect chains are followed and re-validated', async () => {
  const fx = await startServer();
  const { dir, file } = await tempTarget();
  try {
    const result = await downloadToFile(`${fx.baseUrl}/redirect-1`, file, {
      maxBytes: 1024 * 1024,
      ssrf: LOOPBACK_ONLY
    });
    assert.equal(result.bytes, PAYLOAD.length);
    assert.equal(result.redirects, 2);
    assert.equal(result.finalUrl, `${fx.baseUrl}/ok.mp3`);
  } finally {
    await fx.cleanup();
    await rm(dir, { recursive: true, force: true });
  }
});

test('redirects to private IPs or localhost are blocked before connecting', async () => {
  const fx = await startServer();
  const { dir, file } = await tempTarget();
  try {
    await expectJobError(
      downloadToFile(`${fx.baseUrl}/redirect-private`, file, {
        maxBytes: 1 << 20,
        ssrf: LOOPBACK_ONLY
      }),
      'SOURCE_RESTRICTED'
    );
    await expectJobError(
      downloadToFile(`${fx.baseUrl}/redirect-localhost`, file, {
        maxBytes: 1 << 20,
        ssrf: LOOPBACK_ONLY
      }),
      'SOURCE_RESTRICTED'
    );
    assert.equal(fx.hits.get('/redirect-private'), 1); // never followed
  } finally {
    await fx.cleanup();
    await rm(dir, { recursive: true, force: true });
  }
});

test('redirect loops stop at the redirect cap', async () => {
  const fx = await startServer();
  const { dir, file } = await tempTarget();
  try {
    await expectJobError(
      downloadToFile(`${fx.baseUrl}/redirect-loop`, file, {
        maxBytes: 1 << 20,
        maxRedirects: 3,
        ssrf: LOOPBACK_ONLY
      }),
      'AUDIO_DOWNLOAD_FAILED'
    );
    assert.equal(fx.hits.get('/redirect-loop'), 4); // initial + 3 follows
  } finally {
    await fx.cleanup();
    await rm(dir, { recursive: true, force: true });
  }
});

test('a stalled body fails on the idle timeout', async () => {
  const fx = await startServer();
  const { dir, file } = await tempTarget();
  try {
    const error = await expectJobError(
      downloadToFile(`${fx.baseUrl}/stall.mp3`, file, {
        maxBytes: 1 << 20,
        idleTimeoutMs: 250,
        ssrf: LOOPBACK_ONLY
      }),
      'AUDIO_DOWNLOAD_FAILED'
    );
    assert.match(error.jobError.message, /stall/);
  } finally {
    await fx.cleanup();
    await rm(dir, { recursive: true, force: true });
  }
});
