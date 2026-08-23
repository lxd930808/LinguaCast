import {
  readFile,
  rename,
  rm,
  stat,
  truncate,
  writeFile
} from 'node:fs/promises';
import path from 'node:path';

import type { DirectMediaIdentity } from './resumable-range-stream.js';

const MANIFEST_FILE = 'direct-resume.json';

export interface DirectResumeTrack extends DirectMediaIdentity {
  fileName: string;
}

export interface DirectResumeManifest {
  version: 1;
  videoId: string;
  video: DirectResumeTrack;
  audio: DirectResumeTrack;
}

function isResumeTrack(value: unknown): value is DirectResumeTrack {
  if (!value || typeof value !== 'object') return false;
  const track = value as Record<string, unknown>;
  return (
    typeof track.fileName === 'string' &&
    track.fileName.length > 0 &&
    path.basename(track.fileName) === track.fileName &&
    Number.isSafeInteger(track.itag) &&
    Number(track.itag) > 0 &&
    (typeof track.mimeType === 'string' || track.mimeType === null) &&
    Number.isSafeInteger(track.contentLength) &&
    Number(track.contentLength) > 0 &&
    (typeof track.lastModified === 'string' || track.lastModified === null)
  );
}

function trackIdentityMatches(
  left: DirectResumeTrack,
  right: DirectResumeTrack
): boolean {
  return (
    left.fileName === right.fileName &&
    left.itag === right.itag &&
    left.mimeType === right.mimeType &&
    left.contentLength === right.contentLength &&
    left.lastModified === right.lastModified
  );
}

export function resumeManifestMatches(
  left: DirectResumeManifest,
  right: DirectResumeManifest
): boolean {
  return (
    left.version === right.version &&
    left.videoId === right.videoId &&
    trackIdentityMatches(left.video, right.video) &&
    trackIdentityMatches(left.audio, right.audio)
  );
}

export async function readDirectResumeManifest(
  workDir: string
): Promise<DirectResumeManifest | null> {
  try {
    const parsed = JSON.parse(
      await readFile(path.join(workDir, MANIFEST_FILE), 'utf8')
    ) as unknown;
    if (
      !parsed ||
      typeof parsed !== 'object' ||
      Array.isArray(parsed)
    ) {
      return null;
    }
    const manifest = parsed as Record<string, unknown>;
    if (
      manifest.version !== 1 ||
      typeof manifest.videoId !== 'string' ||
      !/^[A-Za-z0-9_-]{11}$/.test(manifest.videoId) ||
      !isResumeTrack(manifest.video) ||
      !isResumeTrack(manifest.audio)
    ) {
      return null;
    }
    return manifest as unknown as DirectResumeManifest;
  } catch {
    return null;
  }
}

export async function writeDirectResumeManifest(
  workDir: string,
  manifest: DirectResumeManifest
): Promise<void> {
  const manifestPath = path.join(workDir, MANIFEST_FILE);
  const tempPath = `${manifestPath}.tmp`;
  await writeFile(tempPath, JSON.stringify(manifest, null, 2));
  await rename(tempPath, manifestPath);
}

export async function resetDirectResume(
  workDir: string,
  manifests: Array<DirectResumeManifest | null | undefined>
): Promise<void> {
  const names = new Set<string>();
  for (const manifest of manifests) {
    if (!manifest) continue;
    names.add(manifest.video.fileName);
    names.add(manifest.audio.fileName);
  }
  await Promise.all([
    ...[...names]
      .filter((name) => path.basename(name) === name)
      .map((name) => rm(path.join(workDir, name), { force: true })),
    rm(path.join(workDir, MANIFEST_FILE), { force: true }),
    rm(path.join(workDir, `${MANIFEST_FILE}.tmp`), { force: true })
  ]);
}

export async function prepareResumeOffset(options: {
  filePath: string;
  totalLength: number;
  chunkSize: number;
}): Promise<number> {
  const { filePath, totalLength, chunkSize } = options;
  if (!Number.isSafeInteger(totalLength) || totalLength <= 0) {
    throw new RangeError(`Invalid media length: ${totalLength}`);
  }
  if (!Number.isSafeInteger(chunkSize) || chunkSize <= 0) {
    throw new RangeError(`Invalid chunk size: ${chunkSize}`);
  }

  const fileSize = await stat(filePath)
    .then((value) => value.size)
    .catch(() => 0);
  if (fileSize === totalLength) return totalLength;

  const confirmedOffset =
    fileSize > totalLength ? 0 : Math.floor(fileSize / chunkSize) * chunkSize;
  if (fileSize !== confirmedOffset) {
    await truncate(filePath, confirmedOffset);
  }
  return confirmedOffset;
}
