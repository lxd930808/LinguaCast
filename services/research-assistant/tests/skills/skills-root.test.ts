import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';

import { defaultSkillsRoot, loadSkillRegistry, REQUIRED_SKILLS } from '../../src/skills/registry.js';

test('default skills root resolves to the bundled skills and loads every required skill', () => {
  const root = defaultSkillsRoot();
  for (const name of REQUIRED_SKILLS) {
    assert.ok(existsSync(join(root, name, 'SKILL.md')), name);
  }
  assert.equal(loadSkillRegistry().length >= REQUIRED_SKILLS.length, true);
});
