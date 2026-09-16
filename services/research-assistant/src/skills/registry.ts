import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

import { DomainError } from '../domain/types.js';
import { V2_ALL_TOOLS } from '../agent/v2/tools.js';

export interface SkillRecord {
  name: string;
  version: string;
  description: string;
  allowedTools: string[];
  trigger: string;
  directory: string;
  skillPath: string;
  sha256: string;
  body: string;
}

export const REQUIRED_SKILLS = [
  'topic-research',
  'web-research',
  'podcast-search',
  'youtube-search',
  'transcribe-source',
  'evidence-synthesis',
  'report-writing'
] as const;

const FRONTMATTER = /^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/;

export function defaultSkillsRoot(): string {
  // src/skills -> <service>/skills under tsx; dist/src/skills -> dist/skills in the container
  // image, or <service>/skills for a local `npm run build && npm start`.
  const candidates = ['../../skills', '../../../skills'].map((relativePath) =>
    resolve(fileURLToPath(new URL(relativePath, import.meta.url)))
  );
  return candidates.find((path) => existsSync(join(path, REQUIRED_SKILLS[0], 'SKILL.md'))) ?? (candidates[0] as string);
}

export function loadSkillRegistry(root = defaultSkillsRoot()): SkillRecord[] {
  const trusted = realpathSync(root);
  const names = readdirSync(trusted).sort();
  const records: SkillRecord[] = [];
  for (const name of names) {
    const dir = join(trusted, name);
    if (!statSync(dir).isDirectory()) continue;
    const skillPath = join(dir, 'SKILL.md');
    if (!existsSync(skillPath)) {
      throw new DomainError('INTERNAL_ERROR', `skill ${name} is missing SKILL.md`, false, 500);
    }
    if (realpathSync(dirname(skillPath)) !== realpathSync(dir)) {
      throw new DomainError('INTERNAL_ERROR', 'skill path escaped the trusted root', false, 500);
    }
    records.push(parseSkillFile(name, skillPath, trusted));
  }
  for (const required of REQUIRED_SKILLS) {
    if (!records.some((item) => item.name === required)) {
      throw new DomainError('INTERNAL_ERROR', `required skill ${required} was not discovered`, false, 500);
    }
  }
  return records;
}

export function parseSkillFile(expectedName: string, skillPath: string, trustedRoot: string): SkillRecord {
  const raw = readFileSync(skillPath, 'utf8');
  const match = FRONTMATTER.exec(raw);
  if (!match) {
    throw new DomainError('INTERNAL_ERROR', `skill ${expectedName} is missing frontmatter`, false, 500);
  }
  const fields = parseFrontmatter(match[1] as string);
  const body = match[2] as string;
  if (fields.name !== expectedName) {
    throw new DomainError('INTERNAL_ERROR', `skill directory ${expectedName} does not match name`, false, 500);
  }
  if (!fields.version || !fields.description || !fields.trigger) {
    throw new DomainError('INTERNAL_ERROR', `skill ${expectedName} frontmatter is incomplete`, false, 500);
  }
  const allowedTools = fields.allowedTools;
  if (!Array.isArray(allowedTools) || allowedTools.length === 0) {
    throw new DomainError('INTERNAL_ERROR', `skill ${expectedName} has no allowedTools`, false, 500);
  }
  for (const tool of allowedTools) {
    if (!V2_ALL_TOOLS.includes(tool as (typeof V2_ALL_TOOLS)[number])) {
      throw new DomainError('TOOL_NOT_ALLOWED', `skill ${expectedName} requested a tool outside the V2 whitelist`, false, 403);
    }
  }
  assertNoEscapingRefs(body, dirname(skillPath), trustedRoot);
  return {
    name: fields.name,
    version: fields.version,
    description: fields.description,
    allowedTools,
    trigger: fields.trigger,
    directory: dirname(skillPath),
    skillPath,
    sha256: createHash('sha256').update(raw).digest('hex'),
    body
  };
}

function parseFrontmatter(raw: string): {
  name: string;
  version: string;
  description: string;
  trigger: string;
  allowedTools: string[];
} {
  const lines = raw.split('\n');
  const scalar: Record<string, string> = {};
  const allowedTools: string[] = [];
  let inTools = false;
  for (const line of lines) {
    if (inTools) {
      const item = line.match(/^\s+-\s+([A-Za-z0-9_]+)\s*$/);
      if (item) {
        allowedTools.push(item[1] as string);
        continue;
      }
      inTools = false;
    }
    if (/^allowedTools:\s*$/.test(line)) {
      inTools = true;
      continue;
    }
    const pair = line.match(/^([A-Za-z][A-Za-z0-9_]*)\s*:\s*(.*)$/);
    if (pair) {
      scalar[pair[1] as string] = (pair[2] as string).trim();
    }
  }
  return {
    name: scalar.name ?? '',
    version: scalar.version ?? '',
    description: scalar.description ?? '',
    trigger: scalar.trigger ?? '',
    allowedTools
  };
}

function assertNoEscapingRefs(body: string, skillDir: string, trustedRoot: string): void {
  const refs = [...body.matchAll(/\[[^\]]+\]\(([^)]+)\)/g)].map((match) => match[1] as string);
  for (const ref of refs) {
    if (/^[a-z]+:\/\//i.test(ref) || ref.startsWith('#')) continue;
    const resolved = realpathSync(resolve(skillDir, ref));
    const rel = relative(trustedRoot, resolved);
    if (rel.startsWith(`..${sep}`) || rel === '..') {
      throw new DomainError('INTERNAL_ERROR', 'skill relative reference escaped the trusted root', false, 500);
    }
  }
}

export function skillFingerprint(record: SkillRecord): { name: string; version: string; sha256: string } {
  return { name: record.name, version: record.version, sha256: record.sha256 };
}
