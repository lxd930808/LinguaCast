import assert from 'node:assert/strict';
import { test } from 'node:test';

import { DomainError } from '../../src/domain/types.js';
import { YtDlpSearchProvider, type ProcessRunner } from '../../src/search/providers.js';
import { loadConfig } from '../../src/config/index.js';

test('yt-dlp is invoked with an argv array and the query stays one argument', async () => {
  const captured: Array<{ file: string; args: string[] }> = [];
  const runner: ProcessRunner = {
    async run(file, args) {
      captured.push({ file, args });
      return {
        code: 0,
        stdout: JSON.stringify({
          entries: [{ id: 'dQw4w9WgXcQ', title: 'Talk', extractor: 'Youtube', _type: 'video', duration: 12 }]
        }),
        stderr: ''
      };
    }
  };
  const config = loadConfig({
    ASSISTANT_IDENTITY_MODE: 'selfhost', ASSISTANT_SERVICE_TOKEN: 'test-assistant-token-0123456789',
    V10_SERVICE_TOKEN: 'test-v10-token-0123456789',
    V10_BASE_URL: 'https://content.example.test',
    NODE_ENV: 'test',
    YTDLP_PATH: '/usr/bin/yt-dlp-fake',
    ASSISTANT_TEMP_ROOT: '/tmp/assistant-ytdlp-test'
  });
  const provider = new YtDlpSearchProvider(config, runner);
  const query = 'foo"; rm -rf /; $(reboot)\nbar';
  const hits = await provider.search(query, 10);
  assert.equal(hits.length, 1);
  const seen = captured[0];
  assert.ok(seen);
  assert.equal(seen.args.includes('--skip-download'), true);
  assert.equal(seen.args.includes('--ignore-config'), true);
  assert.equal(seen.args.includes('--flat-playlist'), true);
  assert.equal(seen.args.filter((arg) => arg.startsWith('ytsearch')).length, 1);
  assert.equal(seen.args.at(-1), `ytsearch10:${query.normalize('NFC').trim()}`);
});

test('empty filtered yt-dlp output is an invalid-output class failure for the caller to fallback', async () => {
  const runner: ProcessRunner = {
    async run() {
      return { code: 0, stdout: JSON.stringify({ entries: [{ id: 'playlist', _type: 'playlist' }] }), stderr: '' };
    }
  };
  const config = loadConfig({
    ASSISTANT_IDENTITY_MODE: 'selfhost', ASSISTANT_SERVICE_TOKEN: 'test-assistant-token-0123456789',
    V10_SERVICE_TOKEN: 'test-v10-token-0123456789',
    V10_BASE_URL: 'https://content.example.test',
    NODE_ENV: 'test',
    ASSISTANT_TEMP_ROOT: '/tmp/assistant-ytdlp-test'
  });
  const hits = await new YtDlpSearchProvider(config, runner).search('accounting', 5);
  assert.equal(hits.length, 0);
});

test('timeout maps to YTDLP_TIMEOUT', async () => {
  const runner: ProcessRunner = {
    async run() {
      throw new DomainError('YTDLP_TIMEOUT', 'yt-dlp timed out or exceeded output limits', true, 503);
    }
  };
  const config = loadConfig({
    ASSISTANT_IDENTITY_MODE: 'selfhost', ASSISTANT_SERVICE_TOKEN: 'test-assistant-token-0123456789',
    V10_SERVICE_TOKEN: 'test-v10-token-0123456789',
    V10_BASE_URL: 'https://content.example.test',
    NODE_ENV: 'test',
    ASSISTANT_TEMP_ROOT: '/tmp/assistant-ytdlp-test'
  });
  await assert.rejects(
    () => new YtDlpSearchProvider(config, runner).search('q', 3),
    (error: unknown) => error instanceof DomainError && error.code === 'YTDLP_TIMEOUT'
  );
});
