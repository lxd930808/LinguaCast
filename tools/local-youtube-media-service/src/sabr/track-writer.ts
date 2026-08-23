import { createWriteStream } from 'node:fs';
import { mkdir, stat } from 'node:fs/promises';
import path from 'node:path';

export interface TrackWriteResult {
  filePath: string;
  bytesWritten: number;
  mimeType: string | null;
  itag: number | null;
  height: number | null;
  codec: string | null;
}

function extensionForMime(mimeType: string | undefined | null, kind: 'video' | 'audio'): string {
  const mime = (mimeType ?? '').toLowerCase();
  if (kind === 'video') {
    return mime.includes('webm') ? 'webm' : 'mp4';
  }
  return mime.includes('webm') || mime.includes('opus') ? 'webm' : 'm4a';
}

export function trackFilePath(
  workDir: string,
  kind: 'video' | 'audio',
  mimeType?: string | null
): string {
  return path.join(workDir, `${kind}.${extensionForMime(mimeType, kind)}`);
}

export async function writeTrackStream(options: {
  workDir: string;
  kind: 'video' | 'audio';
  stream: ReadableStream<Uint8Array>;
  mimeType?: string | null;
  itag?: number | null;
  height?: number | null;
  codec?: string | null;
  startOffset?: number;
  onBytes?: (bytesWritten: number) => void;
}): Promise<TrackWriteResult> {
  await mkdir(options.workDir, { recursive: true });
  const filePath = trackFilePath(
    options.workDir,
    options.kind,
    options.mimeType
  );
  const startOffset = Math.max(0, options.startOffset ?? 0);
  if (startOffset > 0) {
    const existingSize = await stat(filePath)
      .then((value) => value.size)
      .catch(() => -1);
    if (existingSize !== startOffset) {
      throw Object.assign(
        new Error(
          `Track resume size mismatch: expected=${startOffset} actual=${existingSize}`
        ),
        { code: 'MEDIA_RESUME_MISMATCH' }
      );
    }
  }
  const outputStream = createWriteStream(filePath, {
    flags: startOffset > 0 ? 'a' : 'w'
  });
  // destroy(error) emits 'error'; without a listener Node treats it as fatal.
  outputStream.on('error', () => {});
  let bytesWritten = startOffset;
  options.onBytes?.(bytesWritten);
  const sink = new WritableStream<Uint8Array>({
    write(chunk) {
      return new Promise((resolve, reject) => {
        bytesWritten += chunk.byteLength;
        options.onBytes?.(bytesWritten);
        outputStream.write(Buffer.from(chunk), (error) => {
          if (error) reject(error);
          else resolve();
        });
      });
    },
    close() {
      return new Promise((resolve, reject) => {
        outputStream.end((error?: Error | null) => {
          if (error) reject(error);
          else resolve();
        });
      });
    },
    abort() {
      outputStream.destroy();
    }
  });
  try {
    await options.stream.pipeTo(sink);
  } catch (error) {
    if (!outputStream.destroyed) {
      outputStream.destroy();
    }
    throw error;
  }
  return {
    filePath,
    bytesWritten,
    mimeType: options.mimeType ?? null,
    itag: options.itag ?? null,
    height: options.height ?? null,
    codec: options.codec ?? null
  };
}
