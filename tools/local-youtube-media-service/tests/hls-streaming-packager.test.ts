import assert from 'node:assert/strict';
import { mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, it } from 'node:test';

import { resetStreamingHlsArtifacts } from '../src/media/hls-streaming-packager.js';

const tempRoots: string[] = [];

afterEach(async () => {
  await Promise.all(
    tempRoots.splice(0).map((root) => rm(root, { recursive: true, force: true }))
  );
});

describe('resetStreamingHlsArtifacts', () => {
  it('removes a partial HLS generation without deleting job metadata', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'yt-hls-reset-'));
    tempRoots.push(root);
    await Promise.all([
      writeFile(path.join(root, 'master.m3u8'), 'old'),
      writeFile(path.join(root, 'index.m3u8'), 'old'),
      writeFile(path.join(root, 'init.mp4'), 'old'),
      writeFile(path.join(root, 'segment-00000.m4s'), 'old'),
      writeFile(path.join(root, 'job.json'), '{}')
    ]);

    await resetStreamingHlsArtifacts(root);

    assert.deepEqual(await readdir(root), ['job.json']);
  });
});
