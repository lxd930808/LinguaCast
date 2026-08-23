import { statfs } from 'node:fs/promises';

export async function availableBytes(rootPath: string): Promise<number> {
  const info = await statfs(rootPath);
  return Number(info.bavail) * Number(info.bsize);
}

export async function assertDiskBudget(options: {
  mediaRoot: string;
  minFreeBytes: number;
}): Promise<void> {
  const free = await availableBytes(options.mediaRoot);
  if (free < options.minFreeBytes) {
    throw Object.assign(
      new Error(
        `Insufficient free disk (${Math.round(free / (1024 * 1024))} MiB remaining; need ${Math.round(options.minFreeBytes / (1024 * 1024))} MiB)`
      ),
      { code: 'DISK_FULL' }
    );
  }
}
