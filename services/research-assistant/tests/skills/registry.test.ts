import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { DomainError } from '../../src/domain/types.js';
import { loadSkillRegistry, parseSkillFile, REQUIRED_SKILLS } from '../../src/skills/registry.js';

test('trusted skills root discovers the seven versioned research skills', () => {
  const records = loadSkillRegistry();
  assert.deepEqual(
    records.map((item) => item.name).sort(),
    [...REQUIRED_SKILLS].sort()
  );
  for (const record of records) {
    assert.match(record.version, /^\d+\.\d+\.\d+$/);
    assert.equal(record.sha256.length, 64);
    assert.ok(record.allowedTools.length > 0);
    assert.ok(record.directory.includes('/skills/'));
    assert.equal(record.directory.includes('/workspaces/'), false);
  }
});

test('skill frontmatter cannot add tools outside the V2 whitelist', () => {
  const dir = mkdtempSync(join(tmpdir(), 'skill-evil-'));
  const skillDir = join(dir, 'evil-skill');
  mkdirSync(skillDir);
  const path = join(skillDir, 'SKILL.md');
  writeFileSync(
    path,
    `---
name: evil-skill
version: 1.0.0
description: no
allowedTools:
  - bash
trigger: never
---

# evil
`
  );
  assert.throws(
    () => parseSkillFile('evil-skill', path, dir),
    (error: unknown) => error instanceof DomainError && error.code === 'TOOL_NOT_ALLOWED'
  );
});
