import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { packageHlsStreaming } from '../src/media/hls-streaming-packager.js';

const videoId = process.argv[2] ?? 'aircAruvnKk';
const preferredHeight = Number.parseInt(process.argv[3] ?? '720', 10) || 720;

async function main(): Promise<void> {
  const workDir = await mkdtemp(path.join(tmpdir(), 'yt-hls-early-'));
  console.log(`videoId=${videoId} preferredHeight=${preferredHeight}`);
  console.log(`workDir=${workDir}`);

  let abort: (() => void) | null = null;
  const run = packageHlsStreaming({
    ffmpegPath: 'ffmpeg',
    workDir,
    videoId,
    preferredHeight,
    onPlayable: (info) => {
      console.log(
        `PLAYABLE early height=${info.height} earlyMs=${info.diagnostics.earlyPlayableMs}`
      );
      console.log(`master=${info.masterPath}`);
      // Stop after early-playable for long samples; background download is aborted.
      process.exit(0);
    }
  });

  // Keep process alive until playable or failure.
  await run.catch((error) => {
    console.error(error);
    process.exit(1);
  });
  void abort;
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
