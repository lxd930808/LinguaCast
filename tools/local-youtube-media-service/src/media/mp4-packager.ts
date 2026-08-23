import path from 'node:path';

import {
  ffprobeJson,
  runCommand,
  summarizeFfmpegStderr
} from './ffmpeg-runner.js';

export interface Mp4PackageInput {
  ffmpegPath: string;
  ffprobePath: string;
  workDir: string;
  videoPath: string;
  audioPath: string;
  videoCodecHint?: string | null;
  audioCodecHint?: string | null;
}

export interface Mp4PackageResult {
  outputPath: string;
  height: number | null;
  width: number | null;
  durationSeconds: number | null;
  videoCodec: string | null;
  audioCodec: string | null;
  ffprobeSummary: Record<string, unknown>;
}

function isAvcCodec(codec: string | null | undefined): boolean {
  if (!codec) return false;
  return /avc1|avc3|h264/i.test(codec);
}

function isAacCodec(codec: string | null | undefined): boolean {
  if (!codec) return false;
  return /mp4a|aac/i.test(codec);
}

export async function packageMp4(input: Mp4PackageInput): Promise<Mp4PackageResult> {
  const videoProbe = await ffprobeJson(input.ffprobePath, input.videoPath);
  const audioProbe = await ffprobeJson(input.ffprobePath, input.audioPath);

  const videoStream = videoProbe.streams.find((s) => s.codecType === 'video');
  const audioStream = audioProbe.streams.find((s) => s.codecType === 'audio');

  const videoCodec = videoStream?.codecName ?? input.videoCodecHint ?? null;
  const audioCodec = audioStream?.codecName ?? input.audioCodecHint ?? null;

  if (!isAvcCodec(videoCodec) && !isAvcCodec(input.videoCodecHint)) {
    throw Object.assign(
      new Error(`UNSUPPORTED_CODEC: video codec ${videoCodec ?? 'unknown'} is not H.264`),
      { code: 'UNSUPPORTED_CODEC' }
    );
  }
  if (!isAacCodec(audioCodec) && !isAacCodec(input.audioCodecHint)) {
    throw Object.assign(
      new Error(`UNSUPPORTED_CODEC: audio codec ${audioCodec ?? 'unknown'} is not AAC`),
      { code: 'UNSUPPORTED_CODEC' }
    );
  }

  const outputPath = path.join(input.workDir, 'output.mp4');
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
    '-movflags',
    '+faststart',
    outputPath
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

  const outputProbe = await ffprobeJson(input.ffprobePath, outputPath);
  const outVideo = outputProbe.streams.find((s) => s.codecType === 'video');
  const outAudio = outputProbe.streams.find((s) => s.codecType === 'audio');

  return {
    outputPath,
    height: outVideo?.height ?? videoStream?.height ?? null,
    width: outVideo?.width ?? videoStream?.width ?? null,
    durationSeconds: outputProbe.durationSeconds,
    videoCodec: outVideo?.codecName ?? videoCodec,
    audioCodec: outAudio?.codecName ?? audioCodec,
    ffprobeSummary: {
      durationSeconds: outputProbe.durationSeconds,
      video: outVideo,
      audio: outAudio
    }
  };
}
