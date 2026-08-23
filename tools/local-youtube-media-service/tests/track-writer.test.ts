import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, it } from 'node:test';

import { writeTrackStream } from '../src/sabr/track-writer.js';

const tempRoots: string[] = [];

async function tempRoot(): Promise<string> {
  const root = await mkdtemp(path.join(tmpdir(), 'yt-track-writer-'));
  tempRoots.push(root);
  return root;
}

afterEach(async () => {
  await Promise.all(
    tempRoots.splice(0).map((root) => rm(root, { recursive: true, force: true }))
  );
});

describe('writeTrackStream', () => {
  it('appends resumed bytes without overwriting the confirmed prefix', async () => {
    const workDir = await tempRoot();
    const confirmed = Uint8Array.from([0, 1, 2, 3, 4, 5, 6, 7]);
    const remaining = Uint8Array.from([8, 9, 10, 11]);
    await writeFile(path.join(workDir, 'video.mp4'), confirmed);

    const result = await writeTrackStream({
      workDir,
      kind: 'video',
      stream: new ReadableStream({
        start(controller) {
          controller.enqueue(remaining);
          controller.close();
        }
      }),
      mimeType: 'video/mp4',
      startOffset: confirmed.byteLength
    });

    assert.equal(result.bytesWritten, 12);
    assert.deepEqual(
      await readFile(result.filePath),
      Buffer.from([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    );
  });
});
