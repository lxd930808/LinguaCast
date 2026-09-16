import { createHash } from 'node:crypto';
import {
  chmodSync,
  closeSync,
  existsSync,
  fsyncSync,
  lstatSync,
  openSync,
  readFileSync,
  renameSync,
  writeFileSync
} from 'node:fs';
import { dirname, join } from 'node:path';

import { DomainError } from '../domain/types.js';
import { FILE_MODE, RESEARCH_ID_PATTERN } from '../workspace/layout.js';

export const ARTIFACT_KINDS = [
  'web_search',
  'web_page',
  'podcast_search',
  'youtube_search',
  'transcript',
  'research_memory',
  'report'
] as const;

export const EVIDENCE_LEVELS = [
  'search_metadata',
  'primary_content',
  'transcript',
  'research_note',
  'user_preference'
] as const;

export type ArtifactKind = (typeof ARTIFACT_KINDS)[number];
export type EvidenceLevel = (typeof EVIDENCE_LEVELS)[number];
export type ManifestArtifactStatus = 'pending' | 'ready' | 'superseded' | 'failed' | 'corrupt';

export interface ManifestArtifact {
  artifactId: string;
  kind: ArtifactKind;
  status: ManifestArtifactStatus;
  relativePath: string;
  mediaType: string;
  bytes: number;
  sha256: string;
  createdAt: string;
  producer: string;
  sourceURL: string | null;
  contentKey: string | null;
  evidenceLevel: EvidenceLevel;
}

export interface WorkspaceManifest {
  schemaVersion: 1;
  researchId: string;
  createdAt: string;
  updatedAt: string;
  artifacts: ManifestArtifact[];
}

const RELATIVE_PATH_PATTERN = /^(manifest\.json|sources|transcripts|memory|reports)(\/[A-Za-z0-9._-]+)*$/;
const SHA256_PATTERN = /^[a-f0-9]{64}$/;

export function sha256Bytes(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('hex');
}

export function encodeManifest(manifest: WorkspaceManifest): string {
  const sorted: WorkspaceManifest = {
    ...manifest,
    artifacts: [...manifest.artifacts].sort((left, right) => {
      if (left.createdAt === right.createdAt) return left.artifactId.localeCompare(right.artifactId);
      return left.createdAt.localeCompare(right.createdAt);
    })
  };
  return `${JSON.stringify(sorted, null, 2)}\n`;
}

export function decodeManifest(raw: string): WorkspaceManifest {
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
  if (record.schemaVersion !== 1 || typeof record.researchId !== 'string' || !RESEARCH_ID_PATTERN.test(record.researchId)) {
    throw new DomainError('WORKSPACE_CORRUPT', 'workspace manifest fields are invalid', false, 409);
  }
  if (typeof record.createdAt !== 'string' || typeof record.updatedAt !== 'string' || !Array.isArray(record.artifacts)) {
    throw new DomainError('WORKSPACE_CORRUPT', 'workspace manifest fields are invalid', false, 409);
  }
  return {
    schemaVersion: 1,
    researchId: record.researchId,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
    artifacts: record.artifacts.map((item, index) => decodeArtifact(item, index))
  };
}

export function readManifest(workspaceDir: string): WorkspaceManifest {
  const path = join(workspaceDir, 'manifest.json');
  let st;
  try {
    st = lstatSync(path);
  } catch {
    throw new DomainError('WORKSPACE_CORRUPT', 'workspace manifest is missing', false, 409);
  }
  if (st.isSymbolicLink() || !st.isFile()) {
    throw new DomainError('WORKSPACE_PATH_UNSAFE', 'workspace manifest is not a regular file', false, 400);
  }
  return decodeManifest(readFileSync(path, 'utf8'));
}

export function writeManifestAtomic(workspaceDir: string, manifest: WorkspaceManifest): string {
  decodeManifest(encodeManifest(manifest));
  const dest = join(workspaceDir, 'manifest.json');
  const tmp = `${dest}.tmp`;
  const encoded = encodeManifest(manifest);
  writeFileSync(tmp, encoded, { encoding: 'utf8', mode: FILE_MODE });
  chmodSync(tmp, FILE_MODE);
  fsyncNamed(tmp);
  renameSync(tmp, dest);
  chmodSync(dest, FILE_MODE);
  fsyncNamed(dest);
  fsyncNamed(dirname(dest));
  return sha256Bytes(Buffer.from(encoded));
}

export function upsertManifestArtifact(manifest: WorkspaceManifest, artifact: ManifestArtifact, updatedAt: string): WorkspaceManifest {
  const artifacts = manifest.artifacts.filter((item) => item.artifactId !== artifact.artifactId);
  if (artifact.relativePath === 'memory/research.md') {
    for (const item of artifacts) {
      if (item.relativePath === 'memory/research.md' && item.status === 'ready') {
        item.status = 'superseded';
      }
    }
  }
  artifacts.push(artifact);
  return { ...manifest, updatedAt, artifacts };
}

function decodeArtifact(value: unknown, index: number): ManifestArtifact {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new DomainError('WORKSPACE_CORRUPT', `manifest artifact ${index} is invalid`, false, 409);
  }
  const record = value as Record<string, unknown>;
  if (typeof record.artifactId !== 'string' || !RESEARCH_ID_PATTERN.test(record.artifactId)) {
    throw new DomainError('WORKSPACE_CORRUPT', `manifest artifact ${index} id is invalid`, false, 409);
  }
  if (!ARTIFACT_KINDS.includes(record.kind as ArtifactKind)) {
    throw new DomainError('WORKSPACE_CORRUPT', `manifest artifact ${index} kind is invalid`, false, 409);
  }
  if (!['pending', 'ready', 'superseded', 'failed', 'corrupt'].includes(record.status as string)) {
    throw new DomainError('WORKSPACE_CORRUPT', `manifest artifact ${index} status is invalid`, false, 409);
  }
  if (typeof record.relativePath !== 'string' || !RELATIVE_PATH_PATTERN.test(record.relativePath)) {
    throw new DomainError('WORKSPACE_CORRUPT', `manifest artifact ${index} path is invalid`, false, 409);
  }
  if (typeof record.mediaType !== 'string' || typeof record.bytes !== 'number' || typeof record.sha256 !== 'string') {
    throw new DomainError('WORKSPACE_CORRUPT', `manifest artifact ${index} payload is invalid`, false, 409);
  }
  if (!SHA256_PATTERN.test(record.sha256) || typeof record.createdAt !== 'string' || typeof record.producer !== 'string') {
    throw new DomainError('WORKSPACE_CORRUPT', `manifest artifact ${index} payload is invalid`, false, 409);
  }
  if (!EVIDENCE_LEVELS.includes(record.evidenceLevel as EvidenceLevel)) {
    throw new DomainError('WORKSPACE_CORRUPT', `manifest artifact ${index} evidence is invalid`, false, 409);
  }
  return {
    artifactId: record.artifactId,
    kind: record.kind as ArtifactKind,
    status: record.status as ManifestArtifactStatus,
    relativePath: record.relativePath,
    mediaType: record.mediaType,
    bytes: record.bytes,
    sha256: record.sha256,
    createdAt: record.createdAt,
    producer: record.producer,
    sourceURL: typeof record.sourceURL === 'string' ? record.sourceURL : null,
    contentKey: typeof record.contentKey === 'string' ? record.contentKey : null,
    evidenceLevel: record.evidenceLevel as EvidenceLevel
  };
}

function fsyncNamed(path: string): void {
  const fd = openSync(path, 'r');
  try {
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
}

export function manifestExists(workspaceDir: string): boolean {
  return existsSync(join(workspaceDir, 'manifest.json'));
}
