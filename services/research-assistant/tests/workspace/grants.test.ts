import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { parseAdminGrants, resolveEffectiveGrant } from '../../src/workspace/grants.js';
import { DomainError } from '../../src/domain/types.js';

function grantRoots() {
  const dir = mkdtempSync(join(tmpdir(), 'grants-'));
  const notes = join(dir, 'notes');
  const inbox = join(dir, 'inbox');
  mkdirSync(notes);
  mkdirSync(inbox);
  return { dir, notes, inbox };
}

test('admin grants reject overlapping roots and invalid aliases', () => {
  const { notes, inbox } = grantRoots();
  const grants = parseAdminGrants({
    grants: [
      {
        alias: 'notes',
        root: notes,
        permission: 'read',
        allowedExtensions: ['.md', '.txt'],
        maxFileBytes: 2097152
      },
      {
        alias: 'inbox',
        root: inbox,
        permission: 'read_write',
        allowedExtensions: ['.md'],
        maxFileBytes: 1024
      }
    ]
  });
  assert.equal(grants.length, 2);
  mkdirSync(join(notes, 'nested'));
  assert.throws(() =>
    parseAdminGrants({
      grants: [
        {
          alias: 'notes',
          root: notes,
          permission: 'read',
          allowedExtensions: ['.md'],
          maxFileBytes: 1024
        },
        {
          alias: 'nested',
          root: join(notes, 'nested'),
          permission: 'read',
          allowedExtensions: ['.md'],
          maxFileBytes: 1024
        }
      ]
    })
  );
  assert.throws(() =>
    parseAdminGrants({
      grants: [
        {
          alias: 'Notes',
          root: notes,
          permission: 'read',
          allowedExtensions: ['.md'],
          maxFileBytes: 1024
        }
      ]
    })
  );
});

test('research grants cannot exceed admin permission or missing alias', () => {
  const { notes } = grantRoots();
  const admin = parseAdminGrants({
    grants: [
      {
        alias: 'notes',
        root: notes,
        permission: 'read',
        allowedExtensions: ['.md', '.txt'],
        maxFileBytes: 2097152
      }
    ]
  });
  const now = '2026-09-03T01:00:00Z';
  const effective = resolveEffectiveGrant(
    admin,
    [
      {
        researchId: 'r1',
        alias: 'notes',
        permission: 'read_write',
        allowedExtensions: ['.md'],
        maxFileBytes: 4096,
        status: 'ready',
        grantedAt: now
      }
    ],
    'notes'
  );
  assert.equal(effective.permission, 'read');
  assert.deepEqual(effective.allowedExtensions, ['.md']);
  assert.equal(effective.maxFileBytes, 4096);
  assert.throws(
    () => resolveEffectiveGrant(admin, [], 'notes'),
    (error: unknown) => error instanceof DomainError && error.code === 'WORKSPACE_GRANT_DENIED'
  );
  assert.throws(
    () =>
      resolveEffectiveGrant(
        admin,
        [
          {
            researchId: 'r1',
            alias: 'other',
            permission: 'read',
            allowedExtensions: ['.md'],
            maxFileBytes: 1024,
            status: 'ready',
            grantedAt: now
          }
        ],
        'other'
      ),
    (error: unknown) => error instanceof DomainError && error.code === 'WORKSPACE_GRANT_UNAVAILABLE'
  );
});

test('symlink grant roots are rejected at load', () => {
  const { dir, notes } = grantRoots();
  const link = join(dir, 'link');
  symlinkSync(notes, link);
  assert.throws(() =>
    parseAdminGrants({
      grants: [
        {
          alias: 'notes',
          root: link,
          permission: 'read',
          allowedExtensions: ['.md'],
          maxFileBytes: 1024
        }
      ]
    })
  );
  writeFileSync(join(notes, 'ok.md'), 'hi');
});
