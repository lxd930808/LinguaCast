import { statfs } from 'node:fs/promises';

import { PipelineJobError } from '../jobs/worker.js';

// Disk headroom guard (WP4/WP1): jobs must not start a download when free
// space is below the watermark; mid-flight failures surface STORAGE_FULL.

export interface DiskSpace {
  freeBytes: number;
  totalBytes: number;
}

export async function diskSpace(path: string): Promise<DiskSpace> {
  const stats = await statfs(path);
  return {
    freeBytes: Number(stats.bavail) * Number(stats.bsize),
    totalBytes: Number(stats.blocks) * Number(stats.bsize)
  };
}

/**
 * Throws a retryable STORAGE_FULL PipelineJobError when the filesystem
 * holding `path` has less than `watermarkBytes` free (plus `requiredBytes`
 * headroom when known).
 */
export async function assertDiskHeadroom(
  path: string,
  watermarkBytes: number,
  requiredBytes = 0
): Promise<DiskSpace> {
  let space: DiskSpace;
  try {
    space = await diskSpace(path);
  } catch (error) {
    throw new PipelineJobError(
      {
        code: 'STORAGE_FULL',
        message: `cannot stat temp filesystem: ${error instanceof Error ? error.message : String(error)}`,
        retryable: true,
        failedStage: 'fetching_audio'
      },
      error
    );
  }
  if (space.freeBytes < watermarkBytes + requiredBytes) {
    throw new PipelineJobError({
      code: 'STORAGE_FULL',
      message: `free disk ${space.freeBytes} bytes below watermark ${watermarkBytes} (+${requiredBytes} required)`,
      retryable: true,
      retryAfterSeconds: 300,
      failedStage: 'fetching_audio'
    });
  }
  return space;
}
