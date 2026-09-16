import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { openDatabase } from '../../src/db/migrations.js';
import { V2Store } from '../../src/db/v2/store.js';
import { DomainError } from '../../src/domain/types.js';
import { FileTools } from '../../src/workspace/file-tools.js';
import { buildGrepArgv, GrepAdapter, type GrepRunner } from '../../src/workspace/grep-adapter.js';
import { WorkspaceManager } from '../../src/workspace/manager.js';

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), '../../migrations');

function toolsHarness() {
  const dir = mkdtempSync(join(tmpdir(), 'grep-tools-'));
  const db = openDatabase(join(dir, 'a.db'), MIGRATIONS);
  const store = new V2Store(db);
  const workspaceRoot = join(dir, 'workspaces');
  mkdirSync(workspaceRoot);
  const manager = new WorkspaceManager({
    root: workspaceRoot,
    store,
    diskFreeBytes: () => 8 * 1024 * 1024 * 1024
  });
  const research = manager.create({
    ownerScope: 'selfhost',
    title: 'grep',
    outputLanguage: 'zh-Hans',
    storefront: 'US',
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality'
  });
  const tools = new FileTools({
    store,
    researchId: research.researchId,
    workspaceDir: manager.internalPath(research.researchId),
    adminGrants: [],
    sharedWriteEnabled: false,
    sharedVersionRoot: join(dir, 'versions')
  });
  tools.writeFile(
    'research://sources/web/pages/note.md',
    'Firms are piloting document review tools.\nBinary?\n'
  );
  return { tools, close: () => store.close() };
}

test('grep argv is frozen and never includes PCRE2 or extra flags', () => {
  const argv = buildGrepArgv(
    { root: 'research://sources', pattern: 'accounting"; rm -rf /', mode: 'literal', glob: '*.md' },
    200
  );
  assert.equal(argv.includes('--json'), true);
  assert.equal(argv.includes('--no-config'), true);
  assert.equal(argv.includes('--no-follow'), true);
  assert.equal(argv.includes('--engine=default'), true);
  assert.equal(argv.includes('-F'), true);
  assert.equal(argv.includes('--regexp'), true);
  assert.equal(argv.at(-3), 'accounting"; rm -rf /');
  assert.equal(argv.includes('-P'), false);
  assert.equal(argv.includes('--pcre2'), false);
  assert.equal(argv.includes('--ignore-file'), false);
  assert.throws(
    () => buildGrepArgv({ root: 'research://', pattern: 'a', mode: 'literal', glob: '../x' }, 200),
    (error: unknown) => error instanceof DomainError && error.code === 'GREP_ARGUMENT_REJECTED'
  );
});

test('grep maps rg JSON back to virtual URIs and skips binary', async () => {
  const { tools, close } = toolsHarness();
  const runner: GrepRunner = {
    async run(file, args) {
      assert.equal(file, '/usr/bin/rg');
      assert.equal(args.includes('--engine=default'), true);
      assert.equal(args.some((arg) => arg.startsWith('/')), false);
      return {
        code: 0,
        timedOut: false,
        stdout: [
          JSON.stringify({
            type: 'match',
            data: {
              path: { text: 'sources/web/pages/note.md' },
              lines: { text: 'Firms are piloting document review tools.\n' },
              line_number: 12,
              submatches: [{ start: 3, end: 11 }]
            }
          }),
          JSON.stringify({ type: 'binary', data: { path: { text: '/tmp/secret.bin' } } })
        ].join('\n')
      };
    }
  };
  const adapter = new GrepAdapter('/usr/bin/rg', 200, 5000, runner);
  const result = await adapter.grep(tools, {
    root: 'research://',
    pattern: 'accounting',
    mode: 'literal',
    glob: '*.md',
    caseSensitive: false
  });
  assert.equal(result.matchCount, 1);
  assert.equal(result.matches[0]?.uri, 'research://sources/web/pages/note.md');
  assert.equal(result.matches[0]?.line, 12);
  assert.equal(result.matches[0]?.column, 4);
  assert.equal(result.matches[0]?.text.includes('Firms'), true);
  assert.equal(JSON.stringify(result).includes('/tmp/'), false);
  assert.equal(JSON.stringify(result).includes('/usr/bin/rg'), false);
  close();
});

test('grep timeout kills the process group', async () => {
  const { tools, close } = toolsHarness();
  const dir = mkdtempSync(join(tmpdir(), 'rg-stub-'));
  const stub = join(dir, 'sleepy-rg');
  writeFileSync(
    stub,
    `#!/usr/bin/env node
setInterval(() => {}, 1000);
`
  );
  chmodSync(stub, 0o755);
  const adapter = new GrepAdapter(stub, 200, 150);
  await assert.rejects(
    () => adapter.grep(tools, { root: 'research://memory', pattern: 'x', mode: 'literal' }),
    (error: unknown) => error instanceof DomainError && error.code === 'GREP_TIMEOUT'
  );
  close();
});

test('match budget sets truncated without leaking real paths', async () => {
  const { tools, close } = toolsHarness();
  const runner: GrepRunner = {
    async run() {
      const lines = [];
      for (let i = 1; i <= 3; i += 1) {
        lines.push(
          JSON.stringify({
            type: 'match',
            data: {
              path: { text: 'memory/research.md' },
              lines: { text: 'hit\n' },
              line_number: i,
              submatches: [{ start: 0, end: 3 }]
            }
          })
        );
      }
      return { code: 0, timedOut: false, stdout: lines.join('\n') };
    }
  };
  const adapter = new GrepAdapter('rg', 2, 5000, runner);
  const result = await adapter.grep(tools, { root: 'research://', pattern: 'hit', mode: 'literal' });
  assert.equal(result.truncated, true);
  assert.equal(result.matchCount, 2);
  close();
});

test('grep cancel kills the process group', async () => {
  const { tools, close } = toolsHarness();
  const dir = mkdtempSync(join(tmpdir(), 'rg-cancel-'));
  const stub = join(dir, 'sleepy-rg');
  writeFileSync(
    stub,
    `#!/usr/bin/env node
setInterval(() => {}, 1000);
`
  );
  chmodSync(stub, 0o755);
  const adapter = new GrepAdapter(stub, 200, 5000);
  const controller = new AbortController();
  const pending = adapter.grep(tools, { root: 'research://memory', pattern: 'x', mode: 'literal' }, controller.signal);
  setTimeout(() => controller.abort(), 30);
  await assert.rejects(
    pending,
    (error: unknown) => error instanceof DomainError && error.code === 'GREP_TIMEOUT'
  );
  close();
});

test('grep drops stderr-shaped absolute paths and non-JSON noise', async () => {
  const { tools, close } = toolsHarness();
  const runner: GrepRunner = {
    async run() {
      return {
        code: 0,
        timedOut: false,
        stdout: [
          `/tmp/secret/research.md:1:leaked`,
          JSON.stringify({
            type: 'match',
            data: {
              path: { text: '/etc/passwd' },
              lines: { text: 'root:x:0:0\n' },
              line_number: 1,
              submatches: [{ start: 0, end: 4 }]
            }
          }),
          JSON.stringify({
            type: 'match',
            data: {
              path: { text: 'memory/research.md' },
              lines: { text: 'safe hit\n' },
              line_number: 3,
              submatches: [{ start: 0, end: 4 }]
            }
          })
        ].join('\n')
      };
    }
  };
  const adapter = new GrepAdapter('rg', 20, 5000, runner);
  const result = await adapter.grep(tools, { root: 'research://', pattern: 'hit', mode: 'literal' });
  assert.equal(result.matchCount, 1);
  assert.equal(result.matches[0]?.uri, 'research://memory/research.md');
  assert.equal(JSON.stringify(result).includes('/etc/passwd'), false);
  assert.equal(JSON.stringify(result).includes('/tmp/'), false);
  close();
});

test('ripgrep regex parse errors become GREP_PATTERN_REJECTED', async () => {
  const { tools, close } = toolsHarness();
  const runner: GrepRunner = {
    async run() {
      return { code: 2, timedOut: false, stdout: 'regex parse error: lookaround is not supported' };
    }
  };
  const adapter = new GrepAdapter('rg', 20, 5000, runner);
  await assert.rejects(
    () => adapter.grep(tools, { root: 'research://', pattern: '(?<=a)b', mode: 'regex' }),
    (error: unknown) => error instanceof DomainError && error.code === 'GREP_PATTERN_REJECTED'
  );
  close();
});
