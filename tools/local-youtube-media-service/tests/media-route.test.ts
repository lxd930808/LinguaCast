import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import path from 'node:path';

import {
  resolveByteRange,
  resolveSafeMediaPath
} from '../src/api/media-route.js';

describe('resolveSafeMediaPath', () => {
  const workDir = path.resolve('/tmp/podcast-yt-media/JOB1');

  it('allows nested media files under the job directory', () => {
    const resolved = resolveSafeMediaPath(workDir, 'segment-00001.m4s');
    assert.equal(resolved, path.join(workDir, 'segment-00001.m4s'));
  });

  it('blocks path traversal', () => {
    assert.equal(resolveSafeMediaPath(workDir, '../escape.mp4'), null);
    assert.equal(resolveSafeMediaPath(workDir, '..\\escape.mp4'), null);
    assert.equal(resolveSafeMediaPath(workDir, '/etc/passwd'), null);
  });
});

describe('resolveByteRange', () => {
  it('supports suffix ranges used by media clients', () => {
    assert.deepEqual(resolveByteRange('bytes=-500', 1_000), {
      start: 500,
      end: 999
    });
  });

  it('clamps an explicit end to the file size', () => {
    assert.deepEqual(resolveByteRange('bytes=900-2000', 1_000), {
      start: 900,
      end: 999
    });
  });

  it('rejects empty and out-of-bounds ranges', () => {
    assert.equal(resolveByteRange('bytes=-0', 1_000), null);
    assert.equal(resolveByteRange('bytes=1000-', 1_000), null);
  });
});
