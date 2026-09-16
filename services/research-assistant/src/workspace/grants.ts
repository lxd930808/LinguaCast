import { existsSync, lstatSync, realpathSync, readFileSync } from 'node:fs';
import { resolve, sep } from 'node:path';

import type { V2GrantRecord } from '../db/v2/store.js';
import { DomainError } from '../domain/types.js';
import { GRANT_ALIAS_PATTERN } from './virtual-path.js';

export interface AdminGrant {
  alias: string;
  root: string;
  permission: 'read' | 'read_write';
  allowedExtensions: string[];
  maxFileBytes: number;
}

export interface EffectiveGrant {
  alias: string;
  root: string;
  permission: 'read' | 'read_write';
  allowedExtensions: string[];
  maxFileBytes: number;
}

const EXTENSION_PATTERN = /^\.[a-z0-9]{1,16}$/;
const MAX_GRANT_FILE_BYTES = 20 * 1024 * 1024;

function configError(message: string): Error {
  return new Error(`Invalid shared grants configuration: ${message}`);
}

export function isContained(rootReal: string, candidateReal: string): boolean {
  return candidateReal === rootReal || candidateReal.startsWith(`${rootReal}${sep}`);
}

export function normalizeExtension(value: string): string {
  return value.trim().toLowerCase();
}

export function parseAdminGrants(value: unknown): AdminGrant[] {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw configError('root must be an object with a grants array');
  }
  const grants = (value as { grants?: unknown }).grants;
  if (!Array.isArray(grants)) {
    throw configError('grants must be an array');
  }
  const seen = new Set<string>();
  const parsed: AdminGrant[] = [];
  for (const item of grants) {
    if (!item || typeof item !== 'object' || Array.isArray(item)) {
      throw configError('grant must be an object');
    }
    const record = item as Record<string, unknown>;
    const alias = typeof record.alias === 'string' ? record.alias : '';
    if (!GRANT_ALIAS_PATTERN.test(alias)) {
      throw configError('alias is invalid');
    }
    if (seen.has(alias)) {
      throw configError(`alias ${alias} is duplicated`);
    }
    seen.add(alias);
    if (typeof record.root !== 'string' || record.root.trim() === '') {
      throw configError(`root for ${alias} is missing`);
    }
    if (record.permission !== 'read' && record.permission !== 'read_write') {
      throw configError(`permission for ${alias} is invalid`);
    }
    if (!Array.isArray(record.allowedExtensions) || record.allowedExtensions.length === 0) {
      throw configError(`allowedExtensions for ${alias} is invalid`);
    }
    const allowedExtensions = record.allowedExtensions.map((ext) => {
      if (typeof ext !== 'string' || !EXTENSION_PATTERN.test(normalizeExtension(ext))) {
        throw configError(`extension for ${alias} is invalid`);
      }
      return normalizeExtension(ext);
    });
    const maxFileBytes = Number(record.maxFileBytes);
    if (!Number.isInteger(maxFileBytes) || maxFileBytes < 1 || maxFileBytes > MAX_GRANT_FILE_BYTES) {
      throw configError(`maxFileBytes for ${alias} is invalid`);
    }
    const root = resolve(record.root);
    if (!existsSync(root)) {
      throw configError(`root for ${alias} is missing`);
    }
    const st = lstatSync(root);
    if (st.isSymbolicLink() || !st.isDirectory()) {
      throw configError(`root for ${alias} is not a directory`);
    }
    parsed.push({
      alias,
      root: realpathSync(root),
      permission: record.permission,
      allowedExtensions,
      maxFileBytes
    });
  }
  for (let i = 0; i < parsed.length; i += 1) {
    for (let j = i + 1; j < parsed.length; j += 1) {
      const left = parsed[i] as AdminGrant;
      const right = parsed[j] as AdminGrant;
      if (isContained(left.root, right.root) || isContained(right.root, left.root)) {
        throw configError('grant roots overlap');
      }
    }
  }
  return parsed;
}

export function loadAdminGrants(path: string): AdminGrant[] {
  if (!path.trim()) return [];
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    throw configError('grants file is not valid JSON');
  }
  return parseAdminGrants(raw);
}

export function resolveEffectiveGrant(
  adminGrants: AdminGrant[],
  researchGrants: V2GrantRecord[],
  alias: string
): EffectiveGrant {
  const research = researchGrants.find((grant) => grant.alias === alias && grant.status === 'ready');
  if (!research) {
    throw new DomainError('WORKSPACE_GRANT_DENIED', 'alias is not granted to this research', false, 403, { alias });
  }
  const admin = adminGrants.find((grant) => grant.alias === alias);
  if (!admin) {
    throw new DomainError('WORKSPACE_GRANT_UNAVAILABLE', 'granted alias root is missing or unmounted', true, 409, {
      alias
    });
  }
  const extensions = admin.allowedExtensions.filter((ext) =>
    research.allowedExtensions.map(normalizeExtension).includes(ext)
  );
  if (extensions.length === 0) {
    throw new DomainError('WORKSPACE_GRANT_DENIED', 'alias is not granted to this research', false, 403, { alias });
  }
  return {
    alias,
    root: admin.root,
    permission: admin.permission === 'read' || research.permission === 'read' ? 'read' : 'read_write',
    allowedExtensions: extensions,
    maxFileBytes: Math.min(admin.maxFileBytes, research.maxFileBytes)
  };
}
