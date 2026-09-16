import {
  chmodSync,
  closeSync,
  copyFileSync,
  existsSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync
} from 'node:fs';
import { dirname, join } from 'node:path';
import { ulid } from 'ulid';

import type { V2ArtifactRecord, V2OperationRecord, V2Store } from '../db/v2/store.js';
import { nowIso } from '../domain/ids.js';
import { DomainError } from '../domain/types.js';
import { newArtifactId, newOperationId } from '../research-v2/state.js';
import { DIR_MODE, FILE_MODE } from '../workspace/layout.js';
import {
  type ArtifactKind,
  type EvidenceLevel,
  type ManifestArtifact,
  decodeManifest,
  readManifest,
  sha256Bytes,
  upsertManifestArtifact,
  writeManifestAtomic
} from './manifest.js';

// Long transcripts include per-segment metadata and can exceed several MiB.
export const MAX_ARTIFACT_BYTES = 32 * 1024 * 1024;
export const MAX_VERSIONS = 5;
export const MAX_VERSION_BYTES = MAX_VERSIONS * MAX_ARTIFACT_BYTES;

export interface SaveArtifactPassage {
  passageId?: string;
  text: string;
  startMs?: number | null;
  endMs?: number | null;
}

export interface SaveArtifactInput {
  kind: ArtifactKind;
  contents: string;
  producer: string;
  evidenceLevel: EvidenceLevel;
  sourceURL?: string | null;
  contentKey?: string | null;
  mediaType?: string;
  relativePath?: string;
  passages?: SaveArtifactPassage[];
}

export interface ArtifactBody {
  artifactId: string;
  kind: string;
  mediaType: string;
  bytes: number;
  sha256: string;
  evidenceLevel: string;
  text: string;
  truncated: boolean;
}

const KIND_META: Record<ArtifactKind, { mediaType: string; path: (id: string) => string }> = {
  web_search: { mediaType: 'application/json', path: (id) => `sources/web/searches/${id}.json` },
  web_page: { mediaType: 'text/markdown', path: (id) => `sources/web/pages/${id}.md` },
  podcast_search: { mediaType: 'application/json', path: (id) => `sources/podcasts/searches/${id}.json` },
  youtube_search: { mediaType: 'application/json', path: (id) => `sources/youtube/searches/${id}.json` },
  transcript: { mediaType: 'text/markdown', path: (id) => `transcripts/podcasts/${id}/transcript.md` },
  research_memory: { mediaType: 'text/markdown', path: () => 'memory/research.md' },
  report: { mediaType: 'text/markdown', path: (id) => `reports/${id}.md` }
};

const RELATIVE_PATH_PATTERN = /^(sources|transcripts|memory|reports)(\/[A-Za-z0-9._-]+)+$/;

function assertRelativePath(relativePath: string): void {
  if (!RELATIVE_PATH_PATTERN.test(relativePath)) {
    throw new DomainError('ARTIFACT_WRITE_FAILED', 'artifact relative path is invalid', false, 400);
  }
}

function stablePassageId(artifactId: string, passageId?: string): string {
  if (!passageId) return ulid();
  if (passageId.startsWith(`${artifactId}:`) || passageId.startsWith(artifactId)) return passageId;
  return `${artifactId}:${passageId}`;
}

function fsyncNamed(path: string): void {
  const fd = openSync(path, 'r');
  try {
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
}

export class ArtifactWriter {
  constructor(
    private readonly store: V2Store,
    private readonly researchId: string,
    private readonly workspaceDir: string
  ) {}

  save(input: SaveArtifactInput): V2ArtifactRecord {
    const research = this.store.getResearch(this.researchId);
    if (!research || research.status === 'deleted' || research.status === 'deleting') {
      throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    }
    const artifactId = newArtifactId();
    const meta = KIND_META[input.kind];
    const relativePath = input.relativePath ?? meta.path(artifactId);
    assertRelativePath(relativePath);
    const mediaType = input.mediaType ?? meta.mediaType;
    const body = Buffer.from(input.contents, 'utf8');
    if (body.length > MAX_ARTIFACT_BYTES) {
      throw new DomainError('ARTIFACT_WRITE_FAILED', 'artifact exceeds the size cap', true, 503);
    }
    const digest = sha256Bytes(body);
    const now = nowIso();
    const dest = join(this.workspaceDir, relativePath);
    const tempName = `.tmp-artifact-${artifactId}`;
    const tempPath = join(dirname(dest), tempName);

    this.store.insertArtifact({
      artifactId,
      researchId: this.researchId,
      kind: input.kind,
      status: 'pending',
      relativePath,
      mediaType,
      bytes: body.length,
      sha256: digest,
      producer: input.producer,
      evidenceLevel: input.evidenceLevel,
      sourceReference: {
        sourceURL: input.sourceURL ?? null,
        contentKey: input.contentKey ?? null
      },
      createdAt: now,
      updatedAt: now
    });
    const operationId = newOperationId();
    this.store.insertOperation({
      operationId,
      researchId: this.researchId,
      artifactId,
      tempName,
      targetRelativePath: relativePath,
      expectedSha256: digest,
      stage: 'pending_file',
      errorCode: null,
      createdAt: now,
      updatedAt: now
    });

    const previousId = this.previousArtifactId(relativePath);
    try {
      mkdirSync(dirname(dest), { recursive: true, mode: DIR_MODE });
      if (existsSync(dest) && lstatSync(dest).isFile()) {
        this.retainVersion(previousId ?? artifactId, dest);
      }
      writeFileSync(tempPath, body, { mode: FILE_MODE });
      chmodSync(tempPath, FILE_MODE);
      fsyncNamed(tempPath);
      if (sha256Bytes(readFileSync(tempPath)) !== digest) {
        throw new DomainError('ARTIFACT_WRITE_FAILED', 'artifact temp hash mismatch', true, 503);
      }
      renameSync(tempPath, dest);
      chmodSync(dest, FILE_MODE);
      fsyncNamed(dest);
      fsyncNamed(dirname(dest));
      this.store.setOperationStage(operationId, 'pending_manifest');
      this.commitManifest(artifactId, {
        artifactId,
        kind: input.kind,
        status: 'ready',
        relativePath,
        mediaType,
        bytes: body.length,
        sha256: digest,
        createdAt: now,
        producer: input.producer,
        sourceURL: input.sourceURL ?? null,
        contentKey: input.contentKey ?? null,
        evidenceLevel: input.evidenceLevel
      });
      if (previousId) {
        const previous = this.store.getArtifact(this.researchId, previousId);
        if (previous?.status === 'ready') {
          this.store.setArtifactStatus(previousId, 'ready', 'superseded');
        }
      }
      this.store.setArtifactStatus(artifactId, 'pending', 'ready');
      this.indexPassages(artifactId, input.contents, input.passages);
      this.store.setOperationStage(operationId, 'completed');
      return this.store.getArtifact(this.researchId, artifactId) as V2ArtifactRecord;
    } catch (error) {
      this.cleanupTemp(tempPath);
      try {
        this.store.setArtifactStatus(artifactId, 'pending', 'failed');
      } catch {
        // already moved
      }
      this.store.setOperationStage(operationId, 'failed', 'ARTIFACT_WRITE_FAILED');
      if (error instanceof DomainError) throw error;
      throw new DomainError('ARTIFACT_WRITE_FAILED', 'pending file manifest ready did not commit', true, 503);
    }
  }

  get(artifactId: string): ArtifactBody {
    const record = this.store.getArtifact(this.researchId, artifactId);
    if (!record) {
      throw new DomainError('ARTIFACT_NOT_FOUND', 'artifact is missing', false, 404);
    }
    if (record.status === 'pending') {
      throw new DomainError('ARTIFACT_NOT_READY', 'artifact is still pending', true, 409);
    }
    if (record.status === 'corrupt' || record.status === 'failed') {
      throw new DomainError('ARTIFACT_CORRUPT', 'artifact is corrupt', false, 409);
    }
    const dest = join(this.workspaceDir, record.relativePath);
    let bytes: Buffer;
    try {
      const st = lstatSync(dest);
      if (st.isSymbolicLink() || !st.isFile()) {
        this.markCorrupt(record);
        throw new DomainError('ARTIFACT_CORRUPT', 'artifact file is not a regular file', false, 409);
      }
      bytes = readFileSync(dest);
    } catch (error) {
      if (error instanceof DomainError) throw error;
      this.markCorrupt(record);
      throw new DomainError('ARTIFACT_CORRUPT', 'artifact file is missing', false, 409);
    }
    if (sha256Bytes(bytes) !== record.sha256 || bytes.length !== record.bytes) {
      this.markCorrupt(record);
      throw new DomainError('ARTIFACT_CORRUPT', 'artifact hash mismatch', false, 409);
    }
    const text = bytes.toString('utf8');
    return {
      artifactId: record.artifactId,
      kind: record.kind,
      mediaType: record.mediaType,
      bytes: record.bytes,
      sha256: record.sha256,
      evidenceLevel: record.evidenceLevel,
      text,
      truncated: false
    };
  }

  recover(): { completed: string[]; failed: string[]; corrupt: string[] } {
    const report = { completed: [] as string[], failed: [] as string[], corrupt: [] as string[] };
    for (const stage of ['pending_file', 'pending_manifest'] as const) {
      for (const operation of this.store.listOperationsByStage(stage)) {
        if (operation.researchId !== this.researchId) continue;
        try {
          this.recoverOperation(operation);
          report.completed.push(operation.operationId);
        } catch {
          this.store.setOperationStage(operation.operationId, 'failed', 'ARTIFACT_WRITE_FAILED');
          if (operation.artifactId) {
            const artifact = this.store.getArtifact(this.researchId, operation.artifactId);
            if (artifact?.status === 'pending') {
              try {
                this.store.setArtifactStatus(operation.artifactId, 'pending', 'failed');
              } catch {
                // ignore
              }
            }
          }
          report.failed.push(operation.operationId);
        }
      }
    }
    for (const artifact of this.store.listArtifacts(this.researchId, undefined, 'ready')) {
      const dest = join(this.workspaceDir, artifact.relativePath);
      if (!existsSync(dest)) {
        this.markCorrupt(artifact);
        report.corrupt.push(artifact.artifactId);
        continue;
      }
      const bytes = readFileSync(dest);
      if (sha256Bytes(bytes) !== artifact.sha256) {
        this.markCorrupt(artifact);
        report.corrupt.push(artifact.artifactId);
      }
    }
    return report;
  }

  rebuildFromManifest(): number {
    let manifest;
    try {
      manifest = readManifest(this.workspaceDir);
    } catch {
      throw new DomainError('WORKSPACE_CORRUPT', 'workspace manifest cannot be rebuilt from', false, 409);
    }
    if (manifest.researchId !== this.researchId) {
      throw new DomainError('WORKSPACE_CORRUPT', 'workspace manifest does not match research', false, 409);
    }
    let restored = 0;
    for (const item of manifest.artifacts) {
      if (item.status !== 'ready') continue;
      const existing = this.store.getArtifact(this.researchId, item.artifactId);
      if (existing) continue;
      const dest = join(this.workspaceDir, item.relativePath);
      if (!existsSync(dest)) continue;
      const bytes = readFileSync(dest);
      if (sha256Bytes(bytes) !== item.sha256) continue;
      this.store.insertArtifact({
        artifactId: item.artifactId,
        researchId: this.researchId,
        kind: item.kind,
        status: 'ready',
        relativePath: item.relativePath,
        mediaType: item.mediaType,
        bytes: item.bytes,
        sha256: item.sha256,
        producer: item.producer,
        evidenceLevel: item.evidenceLevel,
        sourceReference: { sourceURL: item.sourceURL, contentKey: item.contentKey },
        createdAt: item.createdAt,
        updatedAt: item.createdAt
      });
      this.indexPassages(item.artifactId, bytes.toString('utf8'));
      restored += 1;
    }
    return restored;
  }

  private recoverOperation(operation: V2OperationRecord): void {
    if (!operation.artifactId) {
      throw new Error('missing artifact');
    }
    const dest = join(this.workspaceDir, operation.targetRelativePath);
    const tempPath = join(dirname(dest), operation.tempName);
    if (operation.stage === 'pending_file') {
      const destOk =
        existsSync(dest) &&
        Boolean(operation.expectedSha256) &&
        sha256Bytes(readFileSync(dest)) === operation.expectedSha256;
      if (!destOk) {
        if (!existsSync(tempPath) || !operation.expectedSha256) {
          this.cleanupTemp(tempPath);
          throw new Error('incomplete file');
        }
        if (sha256Bytes(readFileSync(tempPath)) !== operation.expectedSha256) {
          this.cleanupTemp(tempPath);
          throw new Error('hash mismatch');
        }
        mkdirSync(dirname(dest), { recursive: true, mode: DIR_MODE });
        renameSync(tempPath, dest);
      } else {
        this.cleanupTemp(tempPath);
      }
      this.store.setOperationStage(operation.operationId, 'pending_manifest');
    }
    const artifact = this.store.getArtifact(this.researchId, operation.artifactId);
    if (!artifact || !existsSync(dest) || sha256Bytes(readFileSync(dest)) !== artifact.sha256) {
      throw new Error('file not ready for manifest');
    }
    this.commitManifest(artifact.artifactId, {
      artifactId: artifact.artifactId,
      kind: artifact.kind as ArtifactKind,
      status: 'ready',
      relativePath: artifact.relativePath,
      mediaType: artifact.mediaType,
      bytes: artifact.bytes,
      sha256: artifact.sha256,
      createdAt: artifact.createdAt,
      producer: artifact.producer,
      sourceURL: null,
      contentKey: null,
      evidenceLevel: artifact.evidenceLevel as EvidenceLevel
    });
    if (artifact.status === 'pending') {
      this.store.setArtifactStatus(artifact.artifactId, 'pending', 'ready');
    }
    this.store.setOperationStage(operation.operationId, 'completed');
  }

  private commitManifest(_artifactId: string, artifact: ManifestArtifact): void {
    let manifest;
    try {
      manifest = readManifest(this.workspaceDir);
    } catch (error) {
      if (error instanceof DomainError && error.code === 'WORKSPACE_CORRUPT') throw error;
      throw error;
    }
    if (manifest.researchId !== this.researchId) {
      throw new DomainError('WORKSPACE_CORRUPT', 'workspace manifest does not match research', false, 409);
    }
    const next = upsertManifestArtifact(manifest, artifact, nowIso());
    const digest = writeManifestAtomic(this.workspaceDir, next);
    this.store
      .getDb()
      .prepare(
        `UPDATE v2_workspaces SET manifest_sha256 = ?, integrity_status = 'ready', updated_at = ? WHERE research_id = ?`
      )
      .run(digest, nowIso(), this.researchId);
  }

  private previousArtifactId(relativePath: string): string | null {
    const ready = this.store
      .listArtifacts(this.researchId)
      .find((item) => item.relativePath === relativePath && item.status === 'ready');
    return ready?.artifactId ?? null;
  }

  private retainVersion(artifactId: string, source: string): void {
    const dir = join(this.workspaceDir, '.versions', artifactId);
    mkdirSync(dir, { recursive: true, mode: DIR_MODE });
    const versionId = ulid();
    const dest = join(dir, versionId);
    copyFileSync(source, dest);
    chmodSync(dest, FILE_MODE);
    const entries = readdirSync(dir)
      .map((name) => {
        const path = join(dir, name);
        const st = statSync(path);
        return { name, path, mtime: st.mtimeMs, size: st.size };
      })
      .sort((left, right) => right.mtime - left.mtime);
    let kept = 0;
    let total = 0;
    for (const entry of entries) {
      if (kept < MAX_VERSIONS && total + entry.size <= MAX_VERSION_BYTES) {
        kept += 1;
        total += entry.size;
      } else {
        rmSync(entry.path, { force: true });
      }
    }
  }

  private indexPassages(artifactId: string, text: string, passages?: SaveArtifactPassage[]): void {
    this.store.removePassagesForArtifact(artifactId);
    const now = nowIso();
    const rows =
      passages && passages.length > 0
        ? passages.slice(0, 2000).map((passage, ordinal) => ({
            passageId: stablePassageId(artifactId, passage.passageId),
            text: passage.text.slice(0, 4000),
            startMs: passage.startMs ?? null,
            endMs: passage.endMs ?? null,
            ordinal
          }))
        : text
            .split(/\n{2,}/)
            .map((part) => part.trim())
            .filter(Boolean)
            .slice(0, 50)
            .map((chunk, ordinal) => ({
              passageId: ulid(),
              text: chunk.slice(0, 4000),
              startMs: null,
              endMs: null,
              ordinal
            }));
    for (const row of rows) {
      this.store.insertPassage({
        passageId: row.passageId,
        researchId: this.researchId,
        artifactId,
        ordinal: row.ordinal,
        text: row.text,
        startMs: row.startMs,
        endMs: row.endMs,
        createdAt: now
      });
    }
  }

  private markCorrupt(record: V2ArtifactRecord): void {
    this.store.removePassagesForArtifact(record.artifactId);
    if (record.status === 'ready') {
      try {
        this.store.setArtifactStatus(record.artifactId, 'ready', 'corrupt');
      } catch {
        // ignore races
      }
    }
    if (existsSync(join(this.workspaceDir, 'manifest.json'))) {
      try {
        const manifest = readManifest(this.workspaceDir);
        const next = {
          ...manifest,
          artifacts: manifest.artifacts.map((item) =>
            item.artifactId === record.artifactId ? { ...item, status: 'corrupt' as const } : item
          )
        };
        writeManifestAtomic(this.workspaceDir, next);
      } catch {
        // leave corrupt manifest for readiness
      }
    }
  }

  private cleanupTemp(tempPath: string): void {
    if (existsSync(tempPath)) rmSync(tempPath, { force: true });
  }
}

export { decodeManifest };
