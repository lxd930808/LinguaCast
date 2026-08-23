import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { packageHlsStreaming } from '../src/media/hls-streaming-packager.js';

const videoId = process.argv[2] ?? 'dQw4w9WgXcQ';
const preferredHeight = Number.parseInt(process.argv[3] ?? '720', 10) || 720;

async function main(): Promise<void> {
  const workDir = await mkdtemp(path.join(tmpdir(), 'yt-hls-stream-'));
  console.log(`videoId=${videoId} preferredHeight=${preferredHeight}`);
  console.log(`workDir=${workDir}`);

  const result = await packageHlsStreaming({
    ffmpegPath: 'ffmpeg',
    workDir,
    videoId,
    preferredHeight,
    onProgress: ({ videoBytes, audioBytes }) => {
      process.stdout.write(`\rbytes video=${videoBytes} audio=${audioBytes}`);
    },
    onPlayable: (info) => {
      console.log(
        `\nPLAYABLE early height=${info.height} codecs=${info.videoCodec}/${info.audioCodec}`
      );
      console.log(`master=${info.masterPath}`);
    }
  });

  console.log('\nDONE', {
    earlyPlayableMs: result.earlyPlayableMs,
    totalElapsedMs: result.totalElapsedMs,
    height: result.height,
    masterPath: result.masterPath
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
