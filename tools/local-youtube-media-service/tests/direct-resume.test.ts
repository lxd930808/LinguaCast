import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, it } from 'node:test';

import {
  readDirectResumeManifest,
  resumeManifestMatches,
  writeDirectResumeManifest,
  prepareResumeOffset,
  type DirectResumeManifest
} from '../src/sabr/direct-resume.js';

const tempRoots: string[] = [];

afterEach(async () => {
  await Promise.all(
    tempRoots.splice(0).map((root) => rm(root, { recursive: true, force: true }))
  );
});

describe('prepareResumeOffset', () => {
  it('truncates an interrupted block back to the last confirmed boundary', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'yt-direct-resume-'));
    tempRoots.push(root);
    const filePath = path.join(root, 'video.mp4');
    await writeFile(
      filePath,
      Uint8Array.from({ length: 13 }, (_, index) => index)
    );

    const offset = await prepareResumeOffset({
      filePath,
      totalLength: 20,
      chunkSize: 8
    });

    assert.equal(offset, 8);
    assert.equal((await readFile(filePath)).byteLength, 8);
  });

  it('persists track identity and rejects a changed refreshed resource', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'yt-direct-resume-'));
    tempRoots.push(root);
    const manifest: DirectResumeManifest = {
      version: 1,
      videoId: 'QN9IaiOoxY8',
      video: {
        fileName: 'video.mp4',
        itag: 137,
        mimeType: 'video/mp4; codecs="avc1.640028"',
        contentLength: 100,
        lastModified: '123'
      },
      audio: {
        fileName: 'audio.m4a',
        itag: 140,
        mimeType: 'audio/mp4; codecs="mp4a.40.2"',
        contentLength: 20,
        lastModified: '456'
      }
    };

    await writeDirectResumeManifest(root, manifest);
    const restored = await readDirectResumeManifest(root);
    assert.deepEqual(restored, manifest);
    assert.equal(resumeManifestMatches(manifest, restored!), true);
    assert.equal(
      resumeManifestMatches(manifest, {
        ...manifest,
        video: { ...manifest.video, contentLength: 101 }
      }),
      false
    );
  });

  it('rejects a malformed manifest before using its file paths', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'yt-direct-resume-'));
    tempRoots.push(root);
    await writeFile(
      path.join(root, 'direct-resume.json'),
      JSON.stringify({
        version: 1,
        videoId: 'QN9IaiOoxY8',
        video: {
          fileName: '../outside.mp4',
          itag: 137,
          mimeType: 'video/mp4',
          contentLength: 100,
          lastModified: null
        },
        audio: {
          fileName: 'audio.m4a',
          itag: 140,
          mimeType: 'audio/mp4',
          contentLength: 20,
          lastModified: null
        }
      })
    );

    assert.equal(await readDirectResumeManifest(root), null);
  });
});
