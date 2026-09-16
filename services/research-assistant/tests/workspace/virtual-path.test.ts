import assert from 'node:assert/strict';
import { test } from 'node:test';

import { DomainError } from '../../src/domain/types.js';
import { formatResearchUri, formatSharedUri, parseVirtualUri } from '../../src/workspace/virtual-path.js';

function isUnsafe(uri: string): boolean {
  try {
    parseVirtualUri(uri);
    return false;
  } catch (error) {
    return error instanceof DomainError && error.code === 'WORKSPACE_PATH_UNSAFE';
  }
}

test('research and shared URIs round-trip to a canonical form', () => {
  assert.equal(parseVirtualUri('research://sources/web').canonical, 'research://sources/web');
  assert.equal(parseVirtualUri('research://').canonical, 'research://');
  assert.equal(parseVirtualUri('shared://notes/inbox.md').canonical, 'shared://notes/inbox.md');
  assert.equal(formatResearchUri(['sources', 'web']), 'research://sources/web');
  assert.equal(formatSharedUri('notes', ['inbox.md']), 'shared://notes/inbox.md');
});

test('path traversal, encoding, unicode separators, and absolute paths are rejected', () => {
  assert.equal(isUnsafe('research://sources/../etc'), true);
  assert.equal(isUnsafe('research://sources/%2e%2e/etc'), true);
  assert.equal(isUnsafe('research://sources%2fweb'), true);
  assert.equal(isUnsafe('research://sources\u2215web'), true);
  assert.equal(isUnsafe('research://sources\uFF0Fweb'), true);
  assert.equal(isUnsafe('research:///etc/passwd'), true);
  assert.equal(isUnsafe('research://C:/Windows'), true);
  assert.equal(isUnsafe('file:///tmp'), true);
  assert.equal(isUnsafe('research://.versions/secret'), true);
  assert.equal(isUnsafe('shared://NOTES/x'), true);
});
