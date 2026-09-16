import { createHash } from 'node:crypto';
import {
  chmodSync,
  closeSync,
  existsSync,
  fsyncSync,
  lstatSync,
  openSync,
  renameSync,
  rmSync,
  statfsSync,
  writeFileSync
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';

import type { V2GrantRecord, V2Store } from '../db/v2/store.js';
import { nowIso } from '../domain/ids.js';
import { DomainError } from '../domain/types.js';
import { newResearchId, type ResearchStatus, type WorkspaceIntegrity } from '../research-v2/state.js';
import {
  assertResearchId,
  assertSafeRoot,
  buildInitialManifest,
  createLayout,
  DIR_MODE,
  encodeManifest,
  FILE_MODE,
  hasCompleteLayout,
  isOfficialDirName,
  isTempDirName,
  listRootEntries,
  officialPath,
  readManifestFile,
  researchIdFromTempDirName,
  tempPath
} from './layout.js';

export const DEFAULT_HARD_FREE_BYTES = 256 * 1024 * 1024;
export const DEFAULT_SOFT_FREE_BYTES = 1024 * 1024 * 1024;
export const DEFAULT_MAX_RESEARCH_BYTES = 512 * 1024 * 1024;

export interface WorkspaceQuota {
  hardFreeBytes: number;
  softFreeBytes: number;
  maxResearchBytes: number;
}

export interface WorkspaceGrantInput {
  alias: string;
  permission: 'read' | 'read_write';
  allowedExtensions: string[];
  maxFileBytes: number;
}

export interface CreateWorkspaceInput {
  ownerScope: string;
  title: string;
  outputLanguage: string;
  storefront: string;
  targetLanguage: string;
  translationQuality: string;
  researchId?: string;
  grants?: WorkspaceGrantInput[];
}

export interface WorkspaceHandle {
  researchId: string;
  status: ResearchStatus;
  workspaceStatus: WorkspaceIntegrity;
  directoryId: string;
  createdAt: string;
}

export interface WorkspaceStats {
  researchId: string;
  bytes: number;
  files: number;
  directories: number;
}

export interface WorkspaceReconcileReport {
  recovered: string[];
  failedCreates: string[];
  purgedDeleting: string[];
  orphanTempDirs: string[];
  orphanOfficialDirs: string[];
  missingDirs: string[];
}

export interface WorkspaceManagerOptions {
  root: string;
  store: V2Store;
  quota?: Partial<WorkspaceQuota>;
  diskFreeBytes?: (root: string) => number;
}

function defaultDiskFreeBytes(root: string): number {
  const stats = statfsSync(root);
  return Number(stats.bavail) * Number(stats.bsize);
}

function sha256Buffer(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('hex');
}

function fsyncFile(path: string): void {
  const fd = openSync(path, 'r');
  try {
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
}

function writeFileAtomic(path: string, contents: string, mode = FILE_MODE): void {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, contents, { encoding: 'utf8', mode });
  chmodSync(tmp, mode);
  fsyncFile(tmp);
  renameSync(tmp, path);
  chmodSync(path, mode);
  fsyncFile(path);
  fsyncFile(dirname(path));
}

function removeTree(path: string): void {
  if (!existsSync(path)) return;
  const st = lstatSync(path);
  if (st.isSymbolicLink()) {
    throw new DomainError('WORKSPACE_PATH_UNSAFE', 'refusing to remove a workspace symlink', false, 400);
  }
  rmSync(path, { recursive: true, force: true });
}

function measureTree(dir: string): WorkspaceStats {
  let bytes = 0;
  let files = 0;
  let directories = 1;
  const stack = [dir];
  while (stack.length > 0) {
    const current = stack.pop() as string;
    let entries: string[];
    try {
      entries = listRootEntries(current);
    } catch {
      continue;
    }
    for (const name of entries) {
      const full = join(current, name);
      const st = lstatSync(full);
      if (st.isSymbolicLink()) continue;
      if (st.isDirectory()) {
        directories += 1;
        stack.push(full);
      } else if (st.isFile()) {
        files += 1;
        bytes += st.size;
      }
    }
  }
  return { researchId: '', bytes, files, directories };
}

export class WorkspaceManager {
  readonly root: string;
  private readonly store: V2Store;
  private readonly quota: WorkspaceQuota;
  private readonly diskFreeBytes: (root: string) => number;
  private readonly openIds = new Set<string>();

  constructor(options: WorkspaceManagerOptions) {
    this.root = resolve(options.root);
    this.store = options.store;
    this.quota = {
      hardFreeBytes: options.quota?.hardFreeBytes ?? DEFAULT_HARD_FREE_BYTES,
      softFreeBytes: options.quota?.softFreeBytes ?? DEFAULT_SOFT_FREE_BYTES,
      maxResearchBytes: options.quota?.maxResearchBytes ?? DEFAULT_MAX_RESEARCH_BYTES
    };
    this.diskFreeBytes = options.diskFreeBytes ?? defaultDiskFreeBytes;
    assertSafeRoot(this.root);
  }

  assertCanCreate(): void {
    const free = this.diskFreeBytes(this.root);
    if (free < this.quota.hardFreeBytes) {
      throw new DomainError('STORAGE_FULL', 'disk hard watermark reached; new research is not allowed', true, 503);
    }
  }

  assertCanWriteLarge(): void {
    const free = this.diskFreeBytes(this.root);
    if (free < this.quota.softFreeBytes) {
      throw new DomainError('WORKSPACE_QUOTA_EXCEEDED', 'disk soft watermark reached; large writes are paused', true, 503);
    }
  }

  create(input: CreateWorkspaceInput): WorkspaceHandle {
    this.assertCanCreate();
    const researchId = input.researchId ?? newResearchId();
    assertResearchId(researchId);
    const existing = this.store.getResearch(researchId, true);
    if (existing) {
      return this.finishExisting(researchId);
    }
    const now = nowIso();
    const grants = (input.grants ?? []).map(
      (grant): V2GrantRecord => ({
        researchId,
        alias: grant.alias,
        permission: grant.permission,
        allowedExtensions: grant.allowedExtensions,
        maxFileBytes: grant.maxFileBytes,
        status: 'ready',
        grantedAt: now
      })
    );
    try {
      this.store.createResearch(
        {
          researchId,
          ownerScope: input.ownerScope,
          title: input.title,
          status: 'creating',
          workspaceStatus: 'pending',
          outputLanguage: input.outputLanguage,
          storefront: input.storefront,
          targetLanguage: input.targetLanguage,
          translationQuality: input.translationQuality,
          activeTurnId: null,
          createdAt: now,
          updatedAt: now,
          deletedAt: null
        },
        {
          researchId,
          directoryId: researchId,
          manifestVersion: 1,
          manifestSha256: null,
          integrityStatus: 'pending',
          lastRecoveredAt: null,
          createdAt: now,
          updatedAt: now
        },
        grants
      );
    } catch (error) {
      const raced = this.store.getResearch(researchId, true);
      if (raced) return this.finishExisting(researchId);
      throw error;
    }
    try {
      this.materialize(researchId, now);
    } catch (error) {
      this.removeDirs(researchId);
      const current = this.store.getResearch(researchId, true);
      if (current?.status === 'creating') {
        this.store.setResearchStatus(researchId, 'creating', 'failed');
      }
      if (error instanceof DomainError) throw error;
      throw new DomainError('WORKSPACE_CREATE_FAILED', 'atomic workspace create did not commit', true, 503);
    }
    this.store.setResearchStatus(researchId, 'creating', 'ready');
    this.markWorkspaceRow(
      researchId,
      'ready',
      sha256Buffer(Buffer.from(encodeManifest(readManifestFile(officialPath(this.root, researchId)))))
    );
    return this.toHandle(researchId);
  }

  open(researchId: string): WorkspaceHandle {
    assertResearchId(researchId);
    const research = this.store.getResearch(researchId, true);
    if (!research || research.status === 'deleted' || research.status === 'deleting') {
      throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    }
    if (research.status === 'creating') {
      throw new DomainError('WORKSPACE_NOT_READY', 'workspace is still creating', true, 409);
    }
    if (research.status === 'failed') {
      throw new DomainError('WORKSPACE_CREATE_FAILED', 'workspace create failed', true, 503);
    }
    const dir = officialPath(this.root, researchId);
    if (!existsSync(dir)) {
      throw new DomainError('WORKSPACE_DEGRADED', 'workspace directory is missing', true, 409);
    }
    this.assertOfficialDir(researchId);
    const manifest = readManifestFile(dir);
    if (manifest.researchId !== researchId) {
      throw new DomainError('WORKSPACE_CORRUPT', 'workspace manifest does not match research', false, 409);
    }
    this.openIds.add(researchId);
    return this.toHandle(researchId);
  }

  close(handle: WorkspaceHandle): void {
    this.openIds.delete(handle.researchId);
  }

  delete(researchId: string): void {
    assertResearchId(researchId);
    const research = this.store.getResearch(researchId, true);
    if (!research || research.status === 'deleted') {
      this.removeDirs(researchId);
      return;
    }
    if (research.status === 'creating') {
      this.store.setResearchStatus(researchId, 'creating', 'failed');
    }
    const latest = this.store.getResearch(researchId, true);
    if (latest && latest.status !== 'deleting' && latest.status !== 'deleted') {
      this.store.setResearchStatus(researchId, latest.status, 'deleting');
    }
    this.openIds.delete(researchId);
    this.removeDirs(researchId);
    const deleting = this.store.getResearch(researchId, true);
    if (deleting?.status === 'deleting') {
      this.store.finalizeDeleted(researchId);
    }
  }

  stats(researchId: string): WorkspaceStats {
    assertResearchId(researchId);
    const dir = officialPath(this.root, researchId);
    if (!existsSync(dir)) {
      return { researchId, bytes: 0, files: 0, directories: 0 };
    }
    this.assertOfficialDir(researchId);
    const measured = measureTree(dir);
    if (measured.bytes > this.quota.maxResearchBytes) {
      throw new DomainError('WORKSPACE_QUOTA_EXCEEDED', 'research workspace exceeds the configured size cap', true, 503);
    }
    return { ...measured, researchId };
  }

  reconcile(): WorkspaceReconcileReport {
    assertSafeRoot(this.root);
    const report: WorkspaceReconcileReport = {
      recovered: [],
      failedCreates: [],
      purgedDeleting: [],
      orphanTempDirs: [],
      orphanOfficialDirs: [],
      missingDirs: []
    };
    const known = this.listKnownResearch();
    const knownIds = new Set(known.map((row) => row.researchId));

    for (const name of listRootEntries(this.root)) {
      if (isTempDirName(name)) {
        const researchId = researchIdFromTempDirName(name) as string;
        const row = known.find((item) => item.researchId === researchId);
        if (row?.status === 'creating') {
          if (hasCompleteLayout(tempPath(this.root, researchId))) {
            this.finishExisting(researchId);
            report.recovered.push(researchId);
          }
          continue;
        }
        removeTree(tempPath(this.root, researchId));
        report.orphanTempDirs.push(name);
        continue;
      }
      if (isOfficialDirName(name) && !knownIds.has(name)) {
        report.orphanOfficialDirs.push(name);
      }
    }

    for (const row of known) {
      const dir = officialPath(this.root, row.researchId);
      const present = existsSync(dir);
      if (row.status === 'deleting') {
        this.delete(row.researchId);
        report.purgedDeleting.push(row.researchId);
        continue;
      }
      if (row.status === 'creating') {
        if (report.recovered.includes(row.researchId)) continue;
        try {
          this.finishExisting(row.researchId);
          report.recovered.push(row.researchId);
        } catch {
          this.removeDirs(row.researchId);
          const current = this.store.getResearch(row.researchId, true);
          if (current?.status === 'creating') {
            this.store.setResearchStatus(row.researchId, 'creating', 'failed');
          }
          report.failedCreates.push(row.researchId);
        }
        continue;
      }
      if (row.status === 'failed') {
        this.removeDirs(row.researchId);
        continue;
      }
      if (!present && row.status !== 'deleted') {
        report.missingDirs.push(row.researchId);
        if (row.status === 'ready') {
          this.store.setResearchStatus(row.researchId, 'ready', 'degraded');
          this.markWorkspaceRow(row.researchId, 'degraded', null);
        }
      }
    }

    return report;
  }

  internalPath(researchId: string): string {
    assertResearchId(researchId);
    return officialPath(this.root, researchId);
  }

  private finishExisting(researchId: string): WorkspaceHandle {
    const research = this.store.getResearch(researchId, true);
    if (!research) {
      throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    }
    if (research.status === 'deleted' || research.status === 'deleting') {
      throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    }
    if (research.status === 'failed') {
      throw new DomainError('WORKSPACE_CREATE_FAILED', 'workspace create failed', true, 503);
    }
    if (research.status === 'ready' || research.status === 'degraded' || research.status === 'corrupt') {
      if (!hasCompleteLayout(officialPath(this.root, researchId))) {
        throw new DomainError('WORKSPACE_DEGRADED', 'workspace directory is incomplete', true, 409);
      }
      return this.toHandle(researchId);
    }
    const now = research.createdAt;
    this.materialize(researchId, now);
    if (research.status === 'creating') {
      this.store.setResearchStatus(researchId, 'creating', 'ready');
    }
    this.markWorkspaceRow(
      researchId,
      'ready',
      sha256Buffer(Buffer.from(encodeManifest(readManifestFile(officialPath(this.root, researchId)))))
    );
    return this.toHandle(researchId);
  }

  private materialize(researchId: string, createdAt: string): void {
    const dest = officialPath(this.root, researchId);
    if (hasCompleteLayout(dest)) {
      this.assertOfficialDir(researchId);
      const manifest = readManifestFile(dest);
      if (manifest.researchId !== researchId) {
        throw new DomainError('WORKSPACE_CORRUPT', 'workspace manifest does not match research', false, 409);
      }
      return;
    }
    if (existsSync(dest)) {
      throw new DomainError('WORKSPACE_CREATE_FAILED', 'incomplete workspace directory already exists', true, 503);
    }
    const staging = tempPath(this.root, researchId);
    if (hasCompleteLayout(staging)) {
      renameSync(staging, dest);
      chmodSync(dest, DIR_MODE);
      fsyncFile(this.root);
      this.assertOfficialDir(researchId);
      return;
    }
    removeTree(staging);
    try {
      createLayout(staging);
      const manifest = buildInitialManifest(researchId, createdAt);
      writeFileAtomic(join(staging, 'manifest.json'), encodeManifest(manifest));
      if (!hasCompleteLayout(staging)) {
        throw new DomainError('WORKSPACE_CREATE_FAILED', 'staging workspace layout is incomplete', true, 503);
      }
      renameSync(staging, dest);
      chmodSync(dest, DIR_MODE);
      fsyncFile(this.root);
      this.assertOfficialDir(researchId);
    } catch (error) {
      removeTree(staging);
      throw error;
    }
  }

  private assertOfficialDir(researchId: string): void {
    const dir = officialPath(this.root, researchId);
    let st;
    try {
      st = lstatSync(dir);
    } catch {
      throw new DomainError('WORKSPACE_NOT_READY', 'workspace directory is missing', true, 409);
    }
    if (st.isSymbolicLink() || !st.isDirectory()) {
      throw new DomainError('WORKSPACE_PATH_UNSAFE', 'workspace directory is not a regular directory', false, 400);
    }
  }

  private markWorkspaceRow(researchId: string, integrity: WorkspaceIntegrity, manifestSha256: string | null): void {
    this.store
      .getDb()
      .prepare(
        `UPDATE v2_workspaces SET integrity_status = ?, manifest_sha256 = COALESCE(?, manifest_sha256),
           last_recovered_at = ?, updated_at = ? WHERE research_id = ?`
      )
      .run(integrity, manifestSha256, nowIso(), nowIso(), researchId);
  }

  private removeDirs(researchId: string): void {
    removeTree(tempPath(this.root, researchId));
    const dest = officialPath(this.root, researchId);
    if (existsSync(dest)) {
      this.assertOfficialDir(researchId);
      removeTree(dest);
    }
  }

  private toHandle(researchId: string): WorkspaceHandle {
    const research = this.store.getResearch(researchId, true);
    if (!research) {
      throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    }
    this.openIds.add(researchId);
    return {
      researchId,
      status: research.status,
      workspaceStatus: research.workspaceStatus,
      directoryId: researchId,
      createdAt: research.createdAt
    };
  }

  private listKnownResearch(): Array<{ researchId: string; status: ResearchStatus }> {
    const rows = this.store.getDb().prepare('SELECT research_id AS researchId, status FROM v2_researches').all() as Array<{
      researchId: string;
      status: ResearchStatus;
    }>;
    return rows;
  }
}
