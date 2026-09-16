import type { Stats } from 'node:fs';
import {
  chmodSync,
  closeSync,
  copyFileSync,
  existsSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  writeFileSync
} from 'node:fs';
import { dirname, extname, join } from 'node:path';
import { ulid } from 'ulid';

import type { V2Store } from '../db/v2/store.js';
import { nowIso } from '../domain/ids.js';
import { DomainError } from '../domain/types.js';
import { FILE_MODE } from './layout.js';
import { isContained, resolveEffectiveGrant, type AdminGrant, type EffectiveGrant } from './grants.js';
import {
  joinVirtual,
  parseVirtualUri,
  type ParsedVirtualUri
} from './virtual-path.js';

export const RESEARCH_ALLOWED_EXTENSIONS = ['.md', '.json', '.txt'];
export const DEFAULT_MAX_FILE_BYTES = 32 * 1024 * 1024;
export const MAX_READ_CHUNK_BYTES = 2 * 1024 * 1024;
export const DEFAULT_LIST_DEPTH = 2;
export const MAX_LIST_DEPTH = 4;
export const MAX_LIST_ENTRIES = 200;
export const MAX_SEARCH_RESULTS = 100;

export interface FileEntry {
  uri: string;
  kind: 'file' | 'directory';
  bytes: number | null;
}

export interface FileToolsOptions {
  store: V2Store;
  researchId: string;
  workspaceDir: string;
  adminGrants: AdminGrant[];
  sharedWriteEnabled: boolean;
  sharedVersionRoot: string;
  maxFileBytes?: number;
}

interface ResolvedPath {
  uri: ParsedVirtualUri;
  realPath: string;
  rootReal: string;
  grant: EffectiveGrant | null;
  exists: boolean;
  stats: Stats | null;
}

function pathUnsafe(reason: string, uri?: string): DomainError {
  return new DomainError('WORKSPACE_PATH_UNSAFE', 'virtual path is not allowed', false, 400, {
    reason,
    ...(uri ? { uri } : {})
  });
}

function fsyncPath(path: string): void {
  const fd = openSync(path, 'r');
  try {
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
}

function extensionOf(segments: string[]): string {
  const name = segments.at(-1);
  if (!name || !name.includes('.', 1)) return '';
  return extname(name).toLowerCase();
}

function assertRegularTreeNode(stats: Stats, uri: string): void {
  if (stats.isSymbolicLink()) {
    throw pathUnsafe('symbolic link is not allowed', uri);
  }
  if (stats.isFile() && Number(stats.nlink) > 1) {
    throw pathUnsafe('hard link is not allowed', uri);
  }
  if (!stats.isFile() && !stats.isDirectory()) {
    throw new DomainError('WORKSPACE_FILE_TYPE_REJECTED', 'special file type is not allowed', false, 400, { uri });
  }
  if (stats.isFile() && (Number(stats.mode) & 0o111) !== 0) {
    throw new DomainError('WORKSPACE_FILE_TYPE_REJECTED', 'executable file is not allowed', false, 400, { uri });
  }
}

function walkSegments(
  rootReal: string,
  segments: string[],
  uri: string,
  allowMissingLeaf: boolean
): { realPath: string; exists: boolean; stats: Stats | null } {
  let current = rootReal;
  for (let i = 0; i < segments.length; i += 1) {
    const segment = segments[i] as string;
    const next = join(current, segment);
    const missingLeaf = allowMissingLeaf && i === segments.length - 1 && !existsSync(next);
    if (missingLeaf) {
      if (!isContained(rootReal, next)) {
        throw pathUnsafe('path escapes the authorized root', uri);
      }
      return { realPath: next, exists: false, stats: null };
    }
    let stats: ReturnType<typeof lstatSync>;
    try {
      stats = lstatSync(next);
    } catch {
      throw pathUnsafe('path is missing', uri);
    }
    assertRegularTreeNode(stats, uri);
    const resolved = realpathSync(next);
    if (!isContained(rootReal, resolved)) {
      throw pathUnsafe('path escapes the authorized root', uri);
    }
    current = resolved;
  }
  let stats: Stats | null = null;
  if (existsSync(current)) {
    stats = lstatSync(current);
    assertRegularTreeNode(stats, uri);
  }
  return { realPath: current, exists: existsSync(current), stats };
}

export class FileTools {
  private readonly store: V2Store;
  private readonly researchId: string;
  private readonly workspaceReal: string;
  private readonly adminGrants: AdminGrant[];
  private readonly sharedWriteEnabled: boolean;
  private readonly sharedVersionRoot: string;
  private readonly maxFileBytes: number;

  constructor(options: FileToolsOptions) {
    this.store = options.store;
    this.researchId = options.researchId;
    this.adminGrants = options.adminGrants;
    this.sharedWriteEnabled = options.sharedWriteEnabled;
    this.sharedVersionRoot = options.sharedVersionRoot;
    this.maxFileBytes = options.maxFileBytes ?? DEFAULT_MAX_FILE_BYTES;
    const rootStats = lstatSync(options.workspaceDir);
    if (rootStats.isSymbolicLink() || !rootStats.isDirectory()) {
      throw pathUnsafe('workspace directory is not a regular directory');
    }
    this.workspaceReal = realpathSync(options.workspaceDir);
  }

  listFiles(uri: string, depth = DEFAULT_LIST_DEPTH): FileEntry[] {
    const resolved = this.resolve(uri, false);
    if (!resolved.exists || !resolved.stats?.isDirectory()) {
      throw pathUnsafe('list target is not a directory', resolved.uri.canonical);
    }
    const capped = Math.min(MAX_LIST_DEPTH, Math.max(1, depth));
    const out: FileEntry[] = [];
    this.collectList(resolved, capped, out);
    return out.slice(0, MAX_LIST_ENTRIES);
  }

  readFile(uri: string, offset = 0, length = Math.min(this.maxFileBytes, MAX_READ_CHUNK_BYTES)): { uri: string; bytes: number; text: string; truncated: boolean } {
    const resolved = this.resolve(uri, false);
    this.assertReadableFile(resolved);
    const cap = Math.min(this.maxBytes(resolved), this.maxFileBytes);
    if (resolved.stats!.size > cap) {
      throw new DomainError('WORKSPACE_QUOTA_EXCEEDED', 'file exceeds the allowed size', true, 503, {
        uri: resolved.uri.canonical
      });
    }
    const start = Math.max(0, offset);
    const buf = readFileSync(resolved.realPath);
    if (buf.includes(0)) {
      throw new DomainError('WORKSPACE_FILE_TYPE_REJECTED', 'binary file is not allowed', false, 400, {
        uri: resolved.uri.canonical
      });
    }
    const slice = buf.subarray(start, start + Math.min(MAX_READ_CHUNK_BYTES, Math.max(0, length)));
    return {
      uri: resolved.uri.canonical,
      bytes: buf.length,
      text: slice.toString('utf8'),
      truncated: start + slice.length < buf.length
    };
  }

  writeFile(uri: string, contents: string): { uri: string; bytes: number } {
    const parsed = parseVirtualUri(uri);
    if (parsed.kind === 'research' && (parsed.segments.at(-1) === 'manifest.json' || parsed.segments[0] === '.versions')) {
      throw pathUnsafe('protected workspace path is not writable', parsed.canonical);
    }
    const resolved = this.resolve(uri, true);
    this.assertCanWrite(resolved);
    const ext = extensionOf(resolved.uri.segments);
    if (!this.allowedExtensions(resolved).includes(ext)) {
      throw new DomainError('WORKSPACE_FILE_TYPE_REJECTED', 'file extension is not allowed', false, 400, {
        uri: resolved.uri.canonical
      });
    }
    const body = Buffer.from(contents, 'utf8');
    if (body.length > this.maxBytes(resolved)) {
      throw new DomainError('WORKSPACE_QUOTA_EXCEEDED', 'write exceeds the allowed size', true, 503, {
        uri: resolved.uri.canonical
      });
    }
    if (resolved.uri.kind === 'shared' && resolved.exists && resolved.stats?.isFile()) {
      this.archiveShared(resolved);
    }
    const parent = dirname(resolved.realPath);
    if (!existsSync(parent)) {
      throw pathUnsafe('parent directory is missing', resolved.uri.canonical);
    }
    const tmp = join(parent, `.tmp-write-${ulid()}`);
    writeFileSync(tmp, body, { mode: FILE_MODE });
    chmodSync(tmp, FILE_MODE);
    fsyncPath(tmp);
    renameSync(tmp, resolved.realPath);
    chmodSync(resolved.realPath, FILE_MODE);
    fsyncPath(resolved.realPath);
    fsyncPath(parent);
    return { uri: resolved.uri.canonical, bytes: body.length };
  }

  searchFiles(uri: string, query: string): FileEntry[] {
    const needle = query.normalize('NFC').trim().toLowerCase();
    if (needle.length < 1 || needle.length > 128) {
      throw new DomainError('INVALID_REQUEST', 'search query is invalid', false, 400, { field: 'query' });
    }
    const resolved = this.resolve(uri, false);
    if (!resolved.exists || !resolved.stats?.isDirectory()) {
      throw pathUnsafe('search root is not a directory', resolved.uri.canonical);
    }
    const matches: FileEntry[] = [];
    this.walkFiles(resolved, [], (entry, relative) => {
      if (matches.length >= MAX_SEARCH_RESULTS) return false;
      const name = relative.join('/').toLowerCase();
      if (name.includes(needle)) {
        matches.push(entry);
      }
      return matches.length < MAX_SEARCH_RESULTS;
    });
    return matches;
  }

  resolveForGrep(uri: string): { cwd: string; parsed: ParsedVirtualUri } {
    const resolved = this.resolve(uri, false);
    if (!resolved.exists || !resolved.stats?.isDirectory()) {
      throw pathUnsafe('grep root is not a directory', resolved.uri.canonical);
    }
    return { cwd: resolved.realPath, parsed: resolved.uri };
  }

  toVirtualFromRelative(parsed: ParsedVirtualUri, relative: string): string | null {
    const cleaned = relative.replace(/^\.\//, '').replaceAll('\\', '/');
    if (cleaned === '' || cleaned === '.') return parsed.canonical;
    if (cleaned.startsWith('/') || cleaned.includes('..') || cleaned.includes('%')) return null;
    const extra = cleaned.split('/').filter(Boolean);
    try {
      return joinVirtual(parsed, extra);
    } catch {
      return null;
    }
  }

  private resolve(uri: string, allowMissingLeaf: boolean): ResolvedPath {
    const parsed = parseVirtualUri(uri);
    const research = this.store.getResearch(this.researchId);
    if (!research || research.status === 'deleting' || research.status === 'deleted') {
      throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    }
    if (research.status === 'creating') {
      throw new DomainError('WORKSPACE_NOT_READY', 'workspace is still creating', true, 409);
    }
    if (parsed.kind === 'research') {
      const walked = walkSegments(this.workspaceReal, parsed.segments, parsed.canonical, allowMissingLeaf);
      return { uri: parsed, rootReal: this.workspaceReal, grant: null, ...walked };
    }
    const grant = resolveEffectiveGrant(this.adminGrants, this.store.listGrants(this.researchId), parsed.alias);
    if (!existsSync(grant.root)) {
      throw new DomainError('WORKSPACE_GRANT_UNAVAILABLE', 'granted alias root is missing or unmounted', true, 409, {
        alias: parsed.alias
      });
    }
    const rootStats = lstatSync(grant.root);
    if (rootStats.isSymbolicLink() || !rootStats.isDirectory()) {
      throw new DomainError('WORKSPACE_GRANT_UNAVAILABLE', 'granted alias root is missing or unmounted', true, 409, {
        alias: parsed.alias
      });
    }
    const rootReal = realpathSync(grant.root);
    const walked = walkSegments(rootReal, parsed.segments, parsed.canonical, allowMissingLeaf);
    return { uri: parsed, rootReal, grant, ...walked };
  }

  private assertReadableFile(resolved: ResolvedPath): void {
    if (!resolved.exists || !resolved.stats?.isFile()) {
      throw pathUnsafe('read target is not a regular file', resolved.uri.canonical);
    }
    const ext = extensionOf(resolved.uri.segments);
    if (!this.allowedExtensions(resolved).includes(ext)) {
      throw new DomainError('WORKSPACE_FILE_TYPE_REJECTED', 'file extension is not allowed', false, 400, {
        uri: resolved.uri.canonical
      });
    }
  }

  private assertCanWrite(resolved: ResolvedPath): void {
    if (resolved.uri.kind === 'shared') {
      if (!this.sharedWriteEnabled) {
        throw new DomainError('SHARED_WRITE_DISABLED', 'shared directory writes are disabled', false, 403);
      }
      if (!resolved.grant || resolved.grant.permission !== 'read_write') {
        throw new DomainError('WORKSPACE_GRANT_READ_ONLY', 'alias is read-only', false, 403, {
          alias: resolved.uri.alias
        });
      }
    }
    if (resolved.exists && !resolved.stats?.isFile()) {
      throw pathUnsafe('write target is not a regular file', resolved.uri.canonical);
    }
  }

  private allowedExtensions(resolved: ResolvedPath): string[] {
    return resolved.grant?.allowedExtensions ?? RESEARCH_ALLOWED_EXTENSIONS;
  }

  private maxBytes(resolved: ResolvedPath): number {
    return resolved.grant?.maxFileBytes ?? this.maxFileBytes;
  }

  private archiveShared(resolved: ResolvedPath): void {
    if (!this.sharedVersionRoot) {
      throw new DomainError('SHARED_WRITE_DISABLED', 'shared directory writes are disabled', false, 403);
    }
    if (resolved.uri.kind !== 'shared') {
      throw new DomainError('SHARED_WRITE_DISABLED', 'shared directory writes are disabled', false, 403);
    }
    const versionId = ulid();
    const destDir = join(this.sharedVersionRoot, resolved.uri.alias, versionId);
    mkdirSync(destDir, { recursive: true, mode: 0o750 });
    const dest = join(destDir, resolved.uri.segments.at(-1) as string);
    copyFileSync(resolved.realPath, dest);
    chmodSync(dest, FILE_MODE);
    const audit = {
      at: nowIso(),
      researchId: this.researchId,
      alias: resolved.uri.alias,
      relativePath: resolved.uri.segments.join('/'),
      bytes: resolved.stats?.size ?? 0,
      versionId
    };
    writeFileSync(join(destDir, 'audit.json'), `${JSON.stringify(audit)}\n`, { mode: FILE_MODE });
  }

  private collectList(dir: ResolvedPath, depth: number, out: FileEntry[]): void {
    if (out.length >= MAX_LIST_ENTRIES) return;
    let names: string[];
    try {
      names = readdirSync(dir.realPath);
    } catch {
      return;
    }
    for (const name of names) {
      if (name === '.versions' || name.startsWith('.tmp-')) continue;
      let child: ResolvedPath;
      try {
        child = this.resolve(joinVirtual(dir.uri, [name]), false);
      } catch {
        continue;
      }
      out.push({
        uri: child.uri.canonical,
        kind: child.stats?.isDirectory() ? 'directory' : 'file',
        bytes: child.stats?.isFile() ? Number(child.stats.size) : null
      });
      if (child.stats?.isDirectory() && depth > 1) {
        this.collectList(child, depth - 1, out);
      }
      if (out.length >= MAX_LIST_ENTRIES) return;
    }
  }

  private walkFiles(
    dir: ResolvedPath,
    relative: string[],
    visit: (entry: FileEntry, relative: string[]) => boolean
  ): void {
    let names: string[];
    try {
      names = readdirSync(dir.realPath);
    } catch {
      return;
    }
    for (const name of names) {
      if (name === '.versions' || name.startsWith('.tmp-')) continue;
      let child: ResolvedPath;
      try {
        child = this.resolve(joinVirtual(dir.uri, [name]), false);
      } catch {
        continue;
      }
      const nextRelative = [...relative, name];
      if (child.stats?.isDirectory()) {
        this.walkFiles(child, nextRelative, visit);
      } else if (child.stats?.isFile()) {
        const keep = visit(
          { uri: child.uri.canonical, kind: 'file', bytes: Number(child.stats.size) },
          nextRelative
        );
        if (!keep) return;
      }
    }
  }
}
