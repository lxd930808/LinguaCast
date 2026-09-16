import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, symlinkSync, writeFileSync, linkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { openDatabase } from '../../src/db/migrations.js';
import { V2Store } from '../../src/db/v2/store.js';
import { DomainError } from '../../src/domain/types.js';
import { FileTools } from '../../src/workspace/file-tools.js';
import { parseAdminGrants } from '../../src/workspace/grants.js';
import { spawnSync } from 'node:child_process';
import { WorkspaceManager } from '../../src/workspace/manager.js';

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), '../../migrations');

function harness() {
  const dir = mkdtempSync(join(tmpdir(), 'file-tools-'));
  const db = openDatabase(join(dir, 'a.db'), MIGRATIONS);
  const store = new V2Store(db);
  const workspaceRoot = join(dir, 'workspaces');
  const shared = join(dir, 'shared');
  const versions = join(dir, 'shared-versions');
  mkdirSync(workspaceRoot);
  mkdirSync(shared);
  mkdirSync(versions);
  mkdirSync(join(shared, 'notes'));
  writeFileSync(join(shared, 'notes', 'inbox.md'), 'old notes\n');
  const adminGrants = parseAdminGrants({
    grants: [
      {
        alias: 'notes',
        root: join(shared, 'notes'),
        permission: 'read_write',
        allowedExtensions: ['.md', '.txt'],
        maxFileBytes: 2097152
      }
    ]
  });
  const manager = new WorkspaceManager({
    root: workspaceRoot,
    store,
    diskFreeBytes: () => 8 * 1024 * 1024 * 1024
  });
  const research = manager.create({
    ownerScope: 'selfhost',
    title: 'files',
    outputLanguage: 'zh-Hans',
    storefront: 'US',
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    grants: [
      {
        alias: 'notes',
        permission: 'read',
        allowedExtensions: ['.md', '.txt'],
        maxFileBytes: 2097152
      }
    ]
  });
  const tools = new FileTools({
    store,
    researchId: research.researchId,
    workspaceDir: manager.internalPath(research.researchId),
    adminGrants,
    sharedWriteEnabled: true,
    sharedVersionRoot: versions
  });
  return { dir, store, manager, tools, research, shared, versions, close: () => store.close() };
}

function isCode(code: string) {
  return (error: unknown) => error instanceof DomainError && error.code === code;
}

test('list read write and search stay on virtual URIs', () => {
  const { tools, close } = harness();
  tools.writeFile('research://memory/research.md', 'accounting notes\n');
  const listed = tools.listFiles('research://memory', 1);
  assert.equal(listed.some((entry) => entry.uri === 'research://memory/research.md'), true);
  assert.equal(listed.every((entry) => entry.uri.startsWith('research://')), true);
  const read = tools.readFile('research://memory/research.md');
  assert.equal(read.text, 'accounting notes\n');
  const found = tools.searchFiles('research://', 'research.md');
  assert.equal(found.some((entry) => entry.uri.endsWith('research.md')), true);
  close();
});

test('symlink escape and encoded traversal are rejected without leaking real paths', () => {
  const { tools, manager, research, close } = harness();
  const dest = manager.internalPath(research.researchId);
  symlinkSync('/etc/passwd', join(dest, 'memory', 'escape.md'));
  assert.throws(() => tools.readFile('research://memory/escape.md'), isCode('WORKSPACE_PATH_UNSAFE'));
  try {
    tools.readFile('research://memory/%2e%2e/%2e%2e/etc/passwd');
    assert.fail('expected rejection');
  } catch (error) {
    assert.equal(error instanceof DomainError, true);
    assert.equal((error as DomainError).code, 'WORKSPACE_PATH_UNSAFE');
    assert.equal((error as DomainError).params.uri, 'research://memory/%2e%2e/%2e%2e/etc/passwd');
    assert.equal(JSON.stringify(error).includes(dest), false);
  }
  close();
});

test('read grant cannot write and unknown alias is denied', () => {
  const { tools, close } = harness();
  const sharedRead = tools.readFile('shared://notes/inbox.md');
  assert.equal(sharedRead.text.includes('old notes'), true);
  assert.throws(() => tools.writeFile('shared://notes/inbox.md', 'hacked\n'), isCode('WORKSPACE_GRANT_READ_ONLY'));
  assert.throws(() => tools.listFiles('shared://secret'), isCode('WORKSPACE_GRANT_DENIED'));
  close();
});

test('shared overwrite copies previous bytes into the private version root', () => {
  const dir = mkdtempSync(join(tmpdir(), 'file-tools-rw-'));
  const db = openDatabase(join(dir, 'a.db'), MIGRATIONS);
  const store = new V2Store(db);
  const workspaceRoot = join(dir, 'workspaces');
  const shared = join(dir, 'shared', 'notes');
  const versions = join(dir, 'shared-versions');
  mkdirSync(workspaceRoot, { recursive: true });
  mkdirSync(shared, { recursive: true });
  mkdirSync(versions, { recursive: true });
  writeFileSync(join(shared, 'inbox.md'), 'old notes\n');
  const adminGrants = parseAdminGrants({
    grants: [
      {
        alias: 'notes',
        root: shared,
        permission: 'read_write',
        allowedExtensions: ['.md'],
        maxFileBytes: 2097152
      }
    ]
  });
  const manager = new WorkspaceManager({
    root: workspaceRoot,
    store,
    diskFreeBytes: () => 8 * 1024 * 1024 * 1024
  });
  const research = manager.create({
    ownerScope: 'selfhost',
    title: 'rw',
    outputLanguage: 'zh-Hans',
    storefront: 'US',
    targetLanguage: 'zh-Hans',
    translationQuality: 'quality',
    grants: [
      {
        alias: 'notes',
        permission: 'read_write',
        allowedExtensions: ['.md'],
        maxFileBytes: 2097152
      }
    ]
  });
  const tools = new FileTools({
    store,
    researchId: research.researchId,
    workspaceDir: manager.internalPath(research.researchId),
    adminGrants,
    sharedWriteEnabled: true,
    sharedVersionRoot: versions
  });
  tools.writeFile('shared://notes/inbox.md', 'new notes\n');
  assert.equal(readFileSync(join(shared, 'inbox.md'), 'utf8'), 'new notes\n');
  const aliases = readdirSync(join(versions, 'notes'));
  assert.equal(aliases.length, 1);
  const archived = readFileSync(join(versions, 'notes', aliases[0] as string, 'inbox.md'), 'utf8');
  assert.equal(archived, 'old notes\n');
  const audit = JSON.parse(readFileSync(join(versions, 'notes', aliases[0] as string, 'audit.json'), 'utf8')) as {
    alias: string;
    relativePath: string;
  };
  assert.equal(audit.alias, 'notes');
  assert.equal(audit.relativePath, 'inbox.md');
  assert.equal(JSON.stringify(audit).includes(shared), false);
  store.close();
});

test('hard links and FIFO special files are rejected', () => {
  const { tools, manager, research, close } = harness();
  const dest = manager.internalPath(research.researchId);
  const real = join(dest, 'memory', 'research.md');
  writeFileSync(real, 'notes\n');
  const hard = join(dest, 'memory', 'linked.md');
  linkSync(real, hard);
  assert.throws(() => tools.readFile('research://memory/linked.md'), isCode('WORKSPACE_PATH_UNSAFE'));
  const fifo = join(dest, 'memory', 'pipe.md');
  const made = spawnSync('mkfifo', [fifo], { encoding: 'utf8' });
  if (made.status === 0) {
    assert.throws(() => tools.readFile('research://memory/pipe.md'), isCode('WORKSPACE_FILE_TYPE_REJECTED'));
  }
  close();
});


test('large transcript files can be read in bounded chunks', () => {
  const { tools, close } = harness();
  const first = 'a'.repeat(2 * 1024 * 1024);
  const rest = 'b'.repeat(1024 * 1024);
  tools.writeFile('research://memory/long.md', first + rest);
  const page = tools.readFile('research://memory/long.md');
  assert.equal(page.text, first);
  assert.equal(page.truncated, true);
  const tail = tools.readFile('research://memory/long.md', first.length);
  assert.equal(tail.text, rest);
  assert.equal(tail.truncated, false);
  assert.equal(tools.readFile('research://memory/long.md', 0, 32 * 1024 * 1024).text.length, first.length);
  close();
});
