import assert from 'node:assert/strict';
import { gzipSync } from 'node:zlib';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { assertV2ToolAllowed } from '../../src/agent/v2/guard.js';
import { workspaceCheck } from '../../src/api/health.js';
import { assertConfirmationToken, issueConfirmationToken } from '../../src/content/v2/confirmation.js';
import { DomainError, publicErrorFields, sanitizePublicText } from '../../src/domain/types.js';
import { RedactingLogger } from '../../src/observability/logger.js';
import { fetchAllowedPage, type PageFetch } from '../../src/web/fetch-client.js';
import { assertHttpUrl, assertPublicResolvedUrl, isBlockedAddress } from '../../src/web/policy.js';
import { buildGrepArgv } from '../../src/workspace/grep-adapter.js';
import { parseVirtualUri } from '../../src/workspace/virtual-path.js';

function isCode(code: string) {
  return (error: unknown) => error instanceof DomainError && error.code === code;
}

const REPO = join(dirname(fileURLToPath(import.meta.url)), '../../../..');

test('path matrix rejects NUL, extra dots, and skill-plant .versions', () => {
  assert.throws(() => parseVirtualUri('research://memory/note\0.md'), isCode('WORKSPACE_PATH_UNSAFE'));
  assert.throws(() => parseVirtualUri('research://memory/./note.md'), isCode('WORKSPACE_PATH_UNSAFE'));
  assert.throws(() => parseVirtualUri('research://.versions/x.md'), isCode('WORKSPACE_PATH_UNSAFE'));
  assert.throws(() => parseVirtualUri('shared://notes/../../etc/passwd'), isCode('WORKSPACE_PATH_UNSAFE'));
  assert.throws(() => parseVirtualUri('research://.tmp-artifact-x.md'), isCode('WORKSPACE_PATH_UNSAFE'));
  assert.throws(() => parseVirtualUri('research://memory/note.md/'), isCode('WORKSPACE_PATH_UNSAFE'));
  assert.throws(() => parseVirtualUri('research://sources\uFF0Fetc'), isCode('WORKSPACE_PATH_UNSAFE'));
  assert.throws(() => parseVirtualUri('research://memory/note\uFF0Emd'), isCode('WORKSPACE_PATH_UNSAFE'));
  assert.throws(() => parseVirtualUri('research://memory/%00note.md'), isCode('WORKSPACE_PATH_UNSAFE'));
  assert.throws(() => parseVirtualUri('research://memory/\u2024note.md'), isCode('WORKSPACE_PATH_UNSAFE'));
});

test('SSRF matrix blocks IPv6 ULA, link-local, and DNS rebinding to metadata', async () => {
  assert.equal(isBlockedAddress('fc00::1'), true);
  assert.equal(isBlockedAddress('fe80::1'), true);
  assert.equal(isBlockedAddress('::ffff:127.0.0.1'), true);
  assert.throws(() => assertHttpUrl('http://169.254.169.254/latest'), isCode('WEB_URL_BLOCKED'));
  assert.throws(() => assertHttpUrl('file:///etc/passwd'), isCode('WEB_URL_BLOCKED'));
  assert.throws(() => assertHttpUrl('javascript:alert(1)'), isCode('WEB_URL_BLOCKED'));
  assert.throws(() => assertHttpUrl('https://user:pass@example.com/page'), isCode('WEB_URL_BLOCKED'));
  await assert.rejects(
    () =>
      assertPublicResolvedUrl('https://example.com/page', async () => ['169.254.169.254']),
    isCode('WEB_URL_BLOCKED')
  );
});

test('redirect hop that rebinds to loopback is rejected', async () => {
  const lookup = async (hostname: string) => {
    if (hostname === 'example.com') return ['203.0.113.10'];
    return ['127.0.0.1'];
  };
  const fetchImpl: PageFetch = async (url) => {
    if (url.hostname === 'example.com') {
      return {
        status: 302,
        headers: { get: (name: string) => (name.toLowerCase() === 'location' ? 'https://rebind.internal/secret' : null) },
        arrayBuffer: async () => new ArrayBuffer(0)
      };
    }
    return {
      status: 200,
      headers: { get: () => 'text/html' },
      arrayBuffer: async () => new ArrayBuffer(0)
    };
  };
  await assert.rejects(
    () => fetchAllowedPage('https://example.com/go', { lookup, fetchImpl, maxBytes: 1024 }),
    isCode('WEB_URL_BLOCKED')
  );
});

test('still-compressed gzip or zlib bodies are rejected as unsupported', async () => {
  const compressed = gzipSync(Buffer.from('<html>' + 'x'.repeat(2048) + '</html>'));
  const fetchImpl: PageFetch = async () => ({
    status: 200,
    headers: {
      get: (name: string) => {
        const key = name.toLowerCase();
        if (key === 'content-type') return 'text/html';
        if (key === 'content-encoding') return 'gzip';
        if (key === 'content-length') return String(compressed.length);
        return null;
      }
    },
    arrayBuffer: async () =>
      compressed.buffer.slice(compressed.byteOffset, compressed.byteOffset + compressed.byteLength)
  });
  await assert.rejects(
    () =>
      fetchAllowedPage('https://example.com/gzip', {
        lookup: async () => ['203.0.113.10'],
        fetchImpl,
        maxBytes: 64 * 1024
      }),
    isCode('WEB_CONTENT_UNSUPPORTED')
  );
});

test('web page byte cap rejects bodies after the size check', async () => {
  const fetchImpl: PageFetch = async () => ({
    status: 200,
    headers: { get: (name: string) => (name.toLowerCase() === 'content-type' ? 'text/html' : null) },
    arrayBuffer: async () => {
      const bytes = Buffer.from('x'.repeat(2048));
      return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    }
  });
  await assert.rejects(
    () =>
      fetchAllowedPage('https://example.com/huge', {
        lookup: async () => ['203.0.113.10'],
        fetchImpl,
        maxBytes: 512
      }),
    isCode('WEB_CONTENT_TOO_LARGE')
  );
});

test('confirmation tokens cannot be forged and hashes must match', () => {
  const issued = issueConfirmationToken();
  assert.match(issued.token, /^ct_/);
  assert.throws(() => assertConfirmationToken('ct_forged'), isCode('TRANSCRIPT_CONFIRMATION_REQUIRED'));
  assert.throws(
    () => assertConfirmationToken(issued.token, '0'.repeat(64)),
    isCode('TRANSCRIPT_CONFIRMATION_REQUIRED')
  );
  assert.equal(assertConfirmationToken(issued.token, issued.hash), issued.hash);
});

test('grep still rejects PCRE2-shaped user glob and overlong patterns', () => {
  assert.throws(
    () => buildGrepArgv({ root: 'research://', pattern: 'a'.repeat(513), mode: 'regex' }, 200),
    isCode('GREP_ARGUMENT_REJECTED')
  );
  assert.throws(
    () => buildGrepArgv({ root: 'research://', pattern: 'a', mode: 'literal', glob: '--pcre2' }, 200),
    isCode('GREP_ARGUMENT_REJECTED')
  );
  assert.throws(
    () => buildGrepArgv({ root: 'research://', pattern: 'a', mode: 'literal', glob: '*.md; rm -rf' }, 200),
    isCode('GREP_ARGUMENT_REJECTED')
  );
  assert.throws(
    () => buildGrepArgv({ root: 'research://', pattern: '(?<=secret)\\w+', mode: 'regex' }, 200),
    isCode('GREP_PATTERN_REJECTED')
  );
  assert.throws(
    () => buildGrepArgv({ root: 'research://', pattern: '(?=admin)token', mode: 'regex' }, 200),
    isCode('GREP_PATTERN_REJECTED')
  );
});

test('default coding tools stay outside the V2 whitelist', () => {
  const base = {
    kind: 'research' as const,
    phase: 'gathering' as const,
    researchId: '01ARZ3NDEKTSV4RRFFQ69G5FAV',
    turnId: 'vt_01ARZ3NDEKTSV4RRFFQ69G5FAV',
    expectedResearchId: '01ARZ3NDEKTSV4RRFFQ69G5FAV',
    expectedTurnId: 'vt_01ARZ3NDEKTSV4RRFFQ69G5FAV'
  };
  for (const tool of ['bash', 'read', 'write', 'grep', 'find', 'ls', 'web']) {
    assert.throws(() => assertV2ToolAllowed({ ...base, tool }), isCode('TOOL_NOT_ALLOWED'));
  }
});

test('V2 error envelopes and readiness omit real paths and secrets', async () => {
  const leaked = new DomainError(
    'WORKSPACE_PATH_UNSAFE',
    'ENOENT open /Users/xudongliu/secret/workspaces/01ARZ3NDEKTSV4RRFFQ69G5FAV Bearer test-assistant-token-0123456789',
    false,
    400,
    { path: '/var/lib/linguacast-assistant/workspaces', uri: 'research://memory/note.md', cookie: 'sid=abc' }
  );
  const fields = publicErrorFields(leaked);
  const text = JSON.stringify(fields);
  assert.equal(text.includes('/Users/'), false);
  assert.equal(text.includes('/var/lib/'), false);
  assert.equal(text.includes('test-assistant-token-0123456789'), false);
  assert.equal(text.includes('sid=abc'), false);
  assert.equal(fields.params.uri, 'research://memory/note.md');
  assert.equal('path' in fields.params, false);
  assert.match(sanitizePublicText('see /tmp/assistant.db and Cookie: secret'), /\[redacted-path\]/);

  const ready = await workspaceCheck('/var/lib/linguacast-assistant/workspaces', false)();
  assert.equal(ready.ok, true);
  assert.equal(JSON.stringify(ready).includes('/var/lib/'), false);
});

test('deploy env examples keep optional V15 flags off and carry no V1/V2 switches', () => {
  const files = [
    'services/research-assistant/.env.example',
    'deploy/research-assistant/.env.example',
    'deploy/dmit/research-assistant/.env.example'
  ];
  for (const relative of files) {
    const text = readFileSync(join(REPO, relative), 'utf8');
    for (const removed of ['ASSISTANT_V2_ENABLED', 'ASSISTANT_V2_DEFAULT', 'ASSISTANT_V1_MUTATIONS_ENABLED']) {
      assert.equal(text.includes(removed), false, `${relative} must not mention removed ${removed}`);
    }
    for (const flag of ['ASSISTANT_WEB_ENABLED', 'ASSISTANT_SHARED_WRITE_ENABLED', 'ASSISTANT_QMD_ENABLED']) {
      assert.match(text, new RegExp(`${flag}=0`), `${relative} must set ${flag}=0`);
      assert.equal(text.includes(`${flag}=1`), false, `${relative} must not set ${flag}=1`);
    }
  }
  for (const composePath of [
    'deploy/research-assistant/docker-compose.yml',
    'deploy/dmit/research-assistant/docker-compose.yml'
  ]) {
    const compose = readFileSync(join(REPO, composePath), 'utf8');
    for (const flag of ['ASSISTANT_WEB_ENABLED', 'ASSISTANT_SHARED_WRITE_ENABLED', 'ASSISTANT_QMD_ENABLED']) {
      assert.equal(compose.includes(`${flag}: "1"`), false, `${composePath} must not set ${flag}=1`);
      assert.equal(compose.includes(`${flag}=1`), false, `${composePath} must not set ${flag}=1`);
    }
  }
});

test('logger redacts filesystem paths, cookies, and signed URLs', () => {
  const lines: string[] = [];
  const logger = new RedactingLogger((line) => lines.push(line));
  logger.registerSecret('live-secret-token-abcdef');
  logger.error('open /var/lib/linguacast-assistant/workspaces/01ARZ3NDEKTSV4RRFFQ69G5FAV Cookie: sid=abc', {
    url: 'https://example.com/file?X-Amz-Signature=deadbeef&X-Amz-Credential=AKIA'
  });
  const joined = lines.join('\n');
  assert.equal(joined.includes('/var/lib/'), false);
  assert.equal(joined.includes('live-secret-token-abcdef'), false);
  assert.equal(joined.includes('sid=abc'), false);
  assert.equal(joined.includes('deadbeef'), false);
  assert.match(joined, /\[redacted-path\]/);
});
