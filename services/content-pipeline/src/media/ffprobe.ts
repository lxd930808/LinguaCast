import { spawn } from 'node:child_process';

import { PipelineJobError } from '../jobs/worker.js';

// ffprobe/ffmpeg wrappers (WP4). Processes run with timeouts, truncated
// stderr capture, and no shell. ffprobe output is parsed from JSON only.

export interface MediaProbe {
  formatName: string;
  codecName: string | null;
  durationSeconds: number;
  bitrate: number | null;
  sampleRate: number | null;
  channels: number | null;
}

export interface CommandOptions {
  timeoutMs: number;
  /** Keep at most this many stderr bytes (tail). */
  maxStderrBytes?: number;
  lowPriority?: boolean;
}

export interface CommandResult {
  code: number;
  stdout: string;
  stderr: string;
}

export function runProcess(
  command: string,
  args: string[],
  options: CommandOptions
): Promise<CommandResult> {
  const maxStderr = options.maxStderrBytes ?? 4096;
  const useNice = options.lowPriority && process.platform !== 'win32';
  const cmd = useNice ? 'nice' : command;
  const finalArgs = useNice ? ['-n', '10', command, ...args] : args;

  return new Promise((resolve, reject) => {
    const child = spawn(cmd, finalArgs, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    let settled = false;

    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      if (!settled) {
        settled = true;
        reject(new Error(`${command} timed out after ${options.timeoutMs}ms`));
      }
    }, options.timeoutMs);
    timer.unref?.();

    child.stdout.on('data', (chunk: Buffer) => {
      stdout += chunk.toString('utf8');
    });
    child.stderr.on('data', (chunk: Buffer) => {
      stderr = (stderr + chunk.toString('utf8')).slice(-maxStderr);
    });
    child.on('error', (error) => {
      clearTimeout(timer);
      if (!settled) {
        settled = true;
        reject(error);
      }
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (!settled) {
        settled = true;
        resolve({ code: code ?? 1, stdout, stderr });
      }
    });
  });
}

export interface ProbeOptions {
  ffprobePath?: string;
  timeoutMs?: number;
}

export async function probeMedia(filePath: string, options: ProbeOptions = {}): Promise<MediaProbe> {
  const result = await runProcess(
    options.ffprobePath ?? 'ffprobe',
    [
      '-v', 'error',
      '-print_format', 'json',
      '-show_format',
      '-show_streams',
      filePath
    ],
    { timeoutMs: options.timeoutMs ?? 30_000 }
  );
  if (result.code !== 0) {
    throw new PipelineJobError({
      code: 'UNSUPPORTED_AUDIO',
      message: `ffprobe failed: ${result.stderr.trim().slice(-500) || `exit ${result.code}`}`,
      retryable: false,
      failedStage: 'preparing_audio'
    });
  }
  let parsed: {
    format?: { format_name?: string; duration?: string; bit_rate?: string };
    streams?: Array<{
      codec_type?: string;
      codec_name?: string;
      sample_rate?: string;
      channels?: number;
      duration?: string;
      height?: number;
      width?: number;
    }>;
  };
  try {
    parsed = JSON.parse(result.stdout);
  } catch {
    throw new PipelineJobError({
      code: 'UNSUPPORTED_AUDIO',
      message: 'ffprobe returned unparseable output',
      retryable: false,
      failedStage: 'preparing_audio'
    });
  }
  const audio = parsed.streams?.find((s) => s.codec_type === 'audio');
  const durationSeconds = Number(parsed.format?.duration ?? audio?.duration ?? NaN);
  if (!audio || !Number.isFinite(durationSeconds) || durationSeconds <= 0) {
    throw new PipelineJobError({
      code: 'UNSUPPORTED_AUDIO',
      message: 'no decodable audio stream or unknown duration',
      retryable: false,
      failedStage: 'preparing_audio'
    });
  }
  const bitrate = Number(parsed.format?.bit_rate);
  return {
    formatName: parsed.format?.format_name ?? '',
    codecName: audio.codec_name ?? null,
    durationSeconds,
    bitrate: Number.isFinite(bitrate) ? bitrate : null,
    sampleRate: audio.sample_rate ? Number(audio.sample_rate) : null,
    channels: audio.channels ?? null
  };
}

export interface ContainerProbe {
  formatName: string;
  durationSeconds: number;
  videoCodec: string | null;
  audioCodec: string | null;
  height: number | null;
  width: number | null;
  videoDurationSeconds: number | null;
  audioDurationSeconds: number | null;
  hasVideo: boolean;
  hasAudio: boolean;
}

/** Probe a local MP4 for both video and audio tracks. Used by V12 promotion. */
export async function probeContainer(filePath: string, options: ProbeOptions = {}): Promise<ContainerProbe> {
  const result = await runProcess(
    options.ffprobePath ?? 'ffprobe',
    [
      '-v', 'error',
      '-print_format', 'json',
      '-show_format',
      '-show_streams',
      filePath
    ],
    { timeoutMs: options.timeoutMs ?? 30_000 }
  );
  if (result.code !== 0) {
    throw new PipelineJobError({
      code: 'UNSUPPORTED_AUDIO',
      message: `ffprobe failed: ${result.stderr.trim().slice(-500) || `exit ${result.code}`}`,
      retryable: false,
      failedStage: 'preparing_audio'
    });
  }
  let parsed: {
    format?: { format_name?: string; duration?: string };
    streams?: Array<{
      codec_type?: string;
      codec_name?: string;
      duration?: string;
      height?: number;
      width?: number;
    }>;
  };
  try {
    parsed = JSON.parse(result.stdout);
  } catch {
    throw new PipelineJobError({
      code: 'UNSUPPORTED_AUDIO',
      message: 'ffprobe returned unparseable output',
      retryable: false,
      failedStage: 'preparing_audio'
    });
  }
  const video = parsed.streams?.find((s) => s.codec_type === 'video');
  const audio = parsed.streams?.find((s) => s.codec_type === 'audio');
  const durationSeconds = Number(
    parsed.format?.duration ?? video?.duration ?? audio?.duration ?? NaN
  );
  return {
    formatName: parsed.format?.format_name ?? '',
    durationSeconds: Number.isFinite(durationSeconds) ? durationSeconds : 0,
    videoCodec: video?.codec_name ?? null,
    audioCodec: audio?.codec_name ?? null,
    height: typeof video?.height === 'number' ? video.height : null,
    width: typeof video?.width === 'number' ? video.width : null,
    videoDurationSeconds: video?.duration && Number.isFinite(Number(video.duration)) ? Number(video.duration) : null,
    audioDurationSeconds: audio?.duration && Number.isFinite(Number(audio.duration)) ? Number(audio.duration) : null,
    hasVideo: Boolean(video),
    hasAudio: Boolean(audio)
  };
}
