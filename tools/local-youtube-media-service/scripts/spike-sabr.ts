import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { ffprobeJson } from '../src/media/ffmpeg-runner.js';
import { packageMp4 } from '../src/media/mp4-packager.js';
import { fetchSabrTracks } from '../src/sabr/sabr-client.js';

const videoId = process.argv[2] ?? 'jNQXAC9IVRw'; // "Me at the zoo" — short public VOD
const preferredHeight = Number.parseInt(process.argv[3] ?? '1080', 10) || 1080;

async function main(): Promise<void> {
  const workDir = await mkdtemp(path.join(tmpdir(), 'yt-sabr-spike-'));
  console.log(`videoId=${videoId}`);
  console.log(`preferredHeight=${preferredHeight}`);
  console.log(`workDir=${workDir}`);

  const started = Date.now();
  const result = await fetchSabrTracks({
    videoId,
    preferredHeight,
    workDir,
    onProgress: ({ videoBytes, audioBytes }) => {
      process.stdout.write(
        `\rfetching video=${videoBytes}B audio=${audioBytes}B`
      );
    }
  });
  process.stdout.write('\n');

  console.log('title:', result.title);
  console.log('diagnostics:', JSON.stringify(result.diagnostics, null, 2));

  const videoProbe = await ffprobeJson('ffprobe', result.video.filePath);
  const audioProbe = await ffprobeJson('ffprobe', result.audio.filePath);
  console.log('videoProbe duration:', videoProbe.durationSeconds, 'streams:', videoProbe.streams);
  console.log('audioProbe duration:', audioProbe.durationSeconds, 'streams:', audioProbe.streams);

  const packaged = await packageMp4({
    ffmpegPath: 'ffmpeg',
    ffprobePath: 'ffprobe',
    workDir,
    videoPath: result.video.filePath,
    audioPath: result.audio.filePath,
    videoCodecHint: result.video.codec,
    audioCodecHint: result.audio.codec
  });

  const report = {
    videoId,
    preferredHeight,
    elapsedMs: Date.now() - started,
    title: result.title,
    diagnostics: result.diagnostics,
    packaged
  };
  const reportPath = path.join(workDir, 'spike-report.json');
  await writeFile(reportPath, JSON.stringify(report, null, 2));
  console.log('packaged:', packaged.outputPath);
  console.log('height:', packaged.height, 'duration:', packaged.durationSeconds);
  console.log('report:', reportPath);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
