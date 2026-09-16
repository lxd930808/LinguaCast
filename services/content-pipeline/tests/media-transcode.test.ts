import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { test } from 'node:test';

import { assertDiskHeadroom, diskSpace } from '../src/media/disk-guard.js';
import { probeMedia } from '../src/media/ffprobe.js';
import { ensureStableMp3, isStableMp3 } from '../src/media/transcode.js';
import { PipelineJobError } from '../src/jobs/worker.js';

// Transcode/probe tests (WP4). Fixtures are synthesized with ffmpeg so no
// binary blobs live in the repo; the suite skips when ffmpeg is unavailable.

const execFileAsync = promisify(execFile);

async function ffmpegAvailable(): Promise<boolean> {
  try {
    await execFileAsync('ffmpeg', ['-version']);
    await execFileAsync('ffprobe', ['-version']);
    return true;
  } catch {
    return false;
  }
}

async function synthTone(output: string, codec: 'wav' | 'mp3', seconds = 2): Promise<void> {
  const args = [
    '-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'lavfi', '-i', `sine=frequency=440:duration=${seconds}`
  ];
  if (codec === 'mp3') args.push('-codec:a', 'libmp3lame', '-b:a', '128k');
  args.push(output);
  await execFileAsync('ffmpeg', args);
}

test('media transcode suite', { skip: !(await ffmpegAvailable()) }, async (t) => {
  await t.test('probes codec, container, duration and bitrate', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'probe-test-'));
    try {
      const wav = join(dir, 'tone.wav');
      await synthTone(wav, 'wav');
      const probe = await probeMedia(wav);
      assert.equal(probe.codecName, 'pcm_s16le');
      assert.ok(probe.formatName.includes('wav'));
      assert.ok(Math.abs(probe.durationSeconds - 2) < 0.2);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  await t.test('a stable MP3 passes through untouched', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'passthrough-test-'));
    try {
      const mp3 = join(dir, 'tone.mp3');
      await synthTone(mp3, 'mp3');
      const probe = await probeMedia(mp3);
      assert.ok(isStableMp3(probe));
      const result = await ensureStableMp3(mp3, join(dir, 'out.mp3'), probe, {
        maxOutputBytes: 10 * 1024 * 1024
      });
      assert.equal(result.transcoded, false);
      assert.equal(result.filePath, mp3);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  await t.test('WAV transcodes to a stable MP3 with bounded duration drift', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'transcode-test-'));
    try {
      const wav = join(dir, 'tone.wav');
      await synthTone(wav, 'wav', 3);
      const inputProbe = await probeMedia(wav);
      assert.ok(!isStableMp3(inputProbe));
      const result = await ensureStableMp3(wav, join(dir, 'out.mp3'), inputProbe, {
        maxOutputBytes: 10 * 1024 * 1024
      });
      assert.equal(result.transcoded, true);
      assert.ok(isStableMp3(result.probe));
      const drift = Math.abs(result.probe.durationSeconds - inputProbe.durationSeconds);
      assert.ok(drift < 1.0, `duration drift ${drift}s too large`);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  await t.test('a corrupt file surfaces UNSUPPORTED_AUDIO from probe', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'corrupt-test-'));
    try {
      const bogus = join(dir, 'bogus.mp3');
      await writeFile(bogus, Buffer.from('this is not media at all'));
      try {
        await probeMedia(bogus);
        assert.fail('expected probe to fail');
      } catch (error) {
        assert.ok(error instanceof PipelineJobError);
        assert.equal(error.jobError.code, 'UNSUPPORTED_AUDIO');
      }
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});

test('disk guard enforces the watermark', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'disk-guard-test-'));
  try {
    const space = await diskSpace(dir);
    assert.ok(space.freeBytes > 0);
    // Watermark above current free space must fail with STORAGE_FULL.
    try {
      await assertDiskHeadroom(dir, space.freeBytes + 1024 * 1024);
      assert.fail('expected STORAGE_FULL');
    } catch (error) {
      assert.ok(error instanceof PipelineJobError);
      assert.equal(error.jobError.code, 'STORAGE_FULL');
      assert.equal(error.jobError.retryable, true);
    }
    // Zero watermark always passes on a writable filesystem.
    await assertDiskHeadroom(dir, 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
