import { access } from 'node:fs/promises';
import path from 'node:path';

import {
  ffprobeJson,
  runCommand,
  summarizeFfmpegStderr
} from './ffmpeg-runner.js';

export interface HlsPackageInput {
  ffmpegPath: string;
  ffprobePath: string;
  workDir: string;
  videoPath: string;
  audioPath: string;
}

export interface HlsPackageResult {
  masterPath: string;
  playlistPath: string;
  height: number | null;
  durationSeconds: number | null;
  videoCodec: string | null;
  audioCodec: string | null;
}

/**
 * First-pass HLS packager: waits for complete tracks, then muxes a single-bitrate
 * fMP4 HLS playlist. Streaming-while-fetching lands in a later iteration.
 */
export async function packageHls(input: HlsPackageInput): Promise<HlsPackageResult> {
  const playlistPath = path.join(input.workDir, 'index.m3u8');
  const segmentPattern = path.join(input.workDir, 'segment-%05d.m4s');
  const initPath = path.join(input.workDir, 'init.mp4');
  const masterPath = path.join(input.workDir, 'master.m3u8');

  const args = [
    '-y',
    '-i',
    input.videoPath,
    '-i',
    input.audioPath,
    '-c:v',
    'copy',
    '-c:a',
    'copy',
    '-map',
    '0:v:0',
    '-map',
    '1:a:0',
    '-f',
    'hls',
    '-hls_time',
    '4',
    '-hls_playlist_type',
    'vod',
    '-hls_segment_type',
    'fmp4',
    '-hls_fmp4_init_filename',
    'init.mp4',
    '-hls_segment_filename',
    segmentPattern,
    playlistPath
  ];

  const result = await runCommand(input.ffmpegPath, args, {
    cwd: input.workDir,
    timeoutMs: 30 * 60 * 1000
  });
  if (result.code !== 0) {
    throw Object.assign(
      new Error(`FFMPEG_FAILED: ${summarizeFfmpegStderr(result.stderr)}`),
      { code: 'FFMPEG_FAILED', stderr: summarizeFfmpegStderr(result.stderr) }
    );
  }

  await access(playlistPath);
  await access(initPath);

  const videoProbe = await ffprobeJson(input.ffprobePath, input.videoPath);
  const audioProbe = await ffprobeJson(input.ffprobePath, input.audioPath);
  const videoStream = videoProbe.streams.find((s) => s.codecType === 'video');
  const audioStream = audioProbe.streams.find((s) => s.codecType === 'audio');

  const bandwidthEstimate = 4_000_000;
  const codecs = [
    videoStream?.codecName === 'h264' ? 'avc1.640028' : videoStream?.codecName,
    audioStream?.codecName === 'aac' ? 'mp4a.40.2' : audioStream?.codecName
  ]
    .filter(Boolean)
    .join(',');

  const masterBody = [
    '#EXTM3U',
    '#EXT-X-VERSION:7',
    `#EXT-X-STREAM-INF:BANDWIDTH=${bandwidthEstimate},RESOLUTION=${videoStream?.width ?? 0}x${videoStream?.height ?? 0},CODECS="${codecs}"`,
    'index.m3u8',
    ''
  ].join('\n');

  const { writeFile } = await import('node:fs/promises');
  await writeFile(masterPath, masterBody, 'utf8');

  return {
    masterPath,
    playlistPath,
    height: videoStream?.height ?? null,
    durationSeconds: videoProbe.durationSeconds ?? audioProbe.durationSeconds,
    videoCodec: videoStream?.codecName ?? null,
    audioCodec: audioStream?.codecName ?? null
  };
}
