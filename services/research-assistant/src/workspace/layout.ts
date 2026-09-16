import { chmodSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

import { DomainError } from '../domain/types.js';

export const RESEARCH_ID_PATTERN = /^[0-9A-HJKMNP-TV-Z]{26}$/;
export const TEMP_DIR_PREFIX = '.tmp-';
export const DIR_MODE = 0o750;
export const FILE_MODE = 0o640;
export const MANIFEST_FILE = 'manifest.json';

export const WORKSPACE_SUBDIRS = [
  'sources',
  'sources/web',
  'sources/web/searches',
  'sources/web/pages',
  'sources/podcasts',
  'sources/podcasts/searches',
  'sources/youtube',
  'sources/youtube/searches',
  'transcripts',
  'transcripts/podcasts',
  'transcripts/youtube',
  'memory',
  'reports',
  '.versions'
] as const;

export interface WorkspaceManifestV1 {
  schemaVersion: 1;
  researchId: string;
  createdAt: string;
  updatedAt: string;
  artifacts: unknown[];
}

export function assertResearchId(researchId: string): void {
  if (!RESEARCH_ID_PATTERN.test(researchId)) {
    throw new DomainError('WORKSPACE_PATH_UNSAFE', 'research id is not a valid directory identity', false, 400);
  }
}

export function officialDirName(researchId: string): string {
  assertResearchId(researchId);
  return researchId;
}

export function tempDirName(researchId: string): string {
  assertResearchId(researchId);
  return `${TEMP_DIR_PREFIX}${researchId}`;
}

export function isTempDirName(name: string): boolean {
  return name.startsWith(TEMP_DIR_PREFIX) && RESEARCH_ID_PATTERN.test(name.slice(TEMP_DIR_PREFIX.length));
}

export function researchIdFromTempDirName(name: string): string | null {
  if (!isTempDirName(name)) return null;
  return name.slice(TEMP_DIR_PREFIX.length);
}

export function isOfficialDirName(name: string): boolean {
  return RESEARCH_ID_PATTERN.test(name);
}

export function officialPath(root: string, researchId: string): string {
  return join(root, officialDirName(researchId));
}

export function tempPath(root: string, researchId: string): string {
  return join(root, tempDirName(researchId));
}

export function manifestPath(workspaceDir: string): string {
  return join(workspaceDir, MANIFEST_FILE);
}

export function buildInitialManifest(researchId: string, createdAt: string): WorkspaceManifestV1 {
  assertResearchId(researchId);
  return {
    schemaVersion: 1,
    researchId,
    createdAt,
    updatedAt: createdAt,
    artifacts: []
  };
}

export function encodeManifest(manifest: WorkspaceManifestV1): string {
  return `${JSON.stringify(manifest, null, 2)}\n`;
}

export function parseManifest(raw: string): WorkspaceManifestV1 {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new DomainError('WORKSPACE_CORRUPT', 'workspace manifest is not valid JSON', false, 409);
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new DomainError('WORKSPACE_CORRUPT', 'workspace manifest is not an object', false, 409);
  }
  const record = value as Record<string, unknown>;
  if (record.schemaVersion !== 1 || typeof record.researchId !== 'string' || typeof record.createdAt !== 'string') {
    throw new DomainError('WORKSPACE_CORRUPT', 'workspace manifest is missing required fields', false, 409);
  }
  if (!RESEARCH_ID_PATTERN.test(record.researchId) || !Array.isArray(record.artifacts)) {
    throw new DomainError('WORKSPACE_CORRUPT', 'workspace manifest fields are invalid', false, 409);
  }
  return {
    schemaVersion: 1,
    researchId: record.researchId,
    createdAt: record.createdAt,
    updatedAt: typeof record.updatedAt === 'string' ? record.updatedAt : record.createdAt,
    artifacts: record.artifacts
  };
}

export function readManifestFile(workspaceDir: string): WorkspaceManifestV1 {
  const path = manifestPath(workspaceDir);
  let st;
  try {
    st = lstatSync(path);
  } catch {
    throw new DomainError('WORKSPACE_CORRUPT', 'workspace manifest is missing', false, 409);
  }
  if (st.isSymbolicLink() || !st.isFile()) {
    throw new DomainError('WORKSPACE_PATH_UNSAFE', 'workspace manifest is not a regular file', false, 400);
  }
  return parseManifest(readFileSync(path, 'utf8'));
}

export function ensureDirectory(path: string, mode = DIR_MODE): void {
  mkdirSync(path, { recursive: true });
  const st = lstatSync(path);
  if (st.isSymbolicLink() || !st.isDirectory()) {
    throw new DomainError('WORKSPACE_PATH_UNSAFE', 'workspace path is not a directory', false, 400);
  }
  chmodSync(path, mode);
}

export function createLayout(workspaceDir: string): void {
  ensureDirectory(workspaceDir);
  for (const relative of WORKSPACE_SUBDIRS) {
    ensureDirectory(join(workspaceDir, relative));
  }
}

export function hasCompleteLayout(workspaceDir: string): boolean {
  if (!existsSync(workspaceDir)) return false;
  const root = lstatSync(workspaceDir);
  if (root.isSymbolicLink() || !root.isDirectory()) return false;
  for (const relative of WORKSPACE_SUBDIRS) {
    const path = join(workspaceDir, relative);
    if (!existsSync(path)) return false;
    const st = lstatSync(path);
    if (st.isSymbolicLink() || !st.isDirectory()) return false;
  }
  if (!existsSync(manifestPath(workspaceDir))) return false;
  const manifest = lstatSync(manifestPath(workspaceDir));
  return !manifest.isSymbolicLink() && manifest.isFile();
}

export function assertSafeRoot(root: string): void {
  ensureDirectory(root);
}

export function listRootEntries(root: string): string[] {
  if (!existsSync(root)) return [];
  return readdirSync(root);
}
