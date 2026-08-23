import { spawn } from 'node:child_process';

export interface CommandResult {
  code: number;
  stdout: string;
  stderr: string;
}

export async function runCommand(
  command: string,
  args: string[],
  options?: { cwd?: string; timeoutMs?: number }
): Promise<CommandResult> {
  return await new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options?.cwd,
      stdio: ['ignore', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';
    let settled = false;

    const timer =
      options?.timeoutMs != null
        ? setTimeout(() => {
            child.kill('SIGKILL');
            if (!settled) {
              settled = true;
              reject(new Error(`${command} timed out after ${options.timeoutMs}ms`));
            }
          }, options.timeoutMs)
        : null;

    child.stdout.on('data', (chunk: Buffer) => {
      stdout += chunk.toString('utf8');
    });
    child.stderr.on('data', (chunk: Buffer) => {
      stderr += chunk.toString('utf8');
    });
    child.on('error', (error) => {
      if (timer) clearTimeout(timer);
      if (!settled) {
        settled = true;
        reject(error);
      }
    });
    child.on('close', (code) => {
      if (timer) clearTimeout(timer);
      if (!settled) {
        settled = true;
        resolve({ code: code ?? 1, stdout, stderr });
      }
    });
  });
}

export function summarizeFfmpegStderr(stderr: string, maxLines = 40): string {
  const lines = stderr
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);
  const interesting = lines.filter(
    (line) =>
      /error|invalid|failed|unable|unknown|does not contain/i.test(line) ||
      /Output #|Stream #|Duration:|frame=|video:|audio:/.test(line)
  );
  const selected = (interesting.length > 0 ? interesting : lines).slice(-maxLines);
  return selected.join('\n');
}

export interface FfprobeStreamInfo {
  codecType: string | null;
  codecName: string | null;
  width: number | null;
  height: number | null;
  durationSeconds: number | null;
  averageFrameRate: string | null;
}

export interface FfprobeResult {
  durationSeconds: number | null;
  streams: FfprobeStreamInfo[];
  raw: unknown;
}

export async function ffprobeJson(
  ffprobePath: string,
  filePath: string
): Promise<FfprobeResult> {
  const result = await runCommand(ffprobePath, [
    '-v',
    'error',
    '-print_format',
    'json',
    '-show_format',
    '-show_streams',
    filePath
  ]);
  if (result.code !== 0) {
    throw new Error(
      `ffprobe failed (${result.code}): ${summarizeFfmpegStderr(result.stderr)}`
    );
  }

  const parsed = JSON.parse(result.stdout) as {
    format?: { duration?: string };
    streams?: Array<{
      codec_type?: string;
      codec_name?: string;
      width?: number;
      height?: number;
      duration?: string;
      avg_frame_rate?: string;
    }>;
  };

  const formatDuration = parsed.format?.duration
    ? Number.parseFloat(parsed.format.duration)
    : null;

  const streams = (parsed.streams ?? []).map((stream) => ({
    codecType: stream.codec_type ?? null,
    codecName: stream.codec_name ?? null,
    width: stream.width ?? null,
    height: stream.height ?? null,
    durationSeconds: stream.duration
      ? Number.parseFloat(stream.duration)
      : null,
    averageFrameRate: stream.avg_frame_rate ?? null
  }));

  const streamDuration = streams
    .map((s) => s.durationSeconds)
    .filter((v): v is number => typeof v === 'number' && Number.isFinite(v))
    .sort((a, b) => b - a)[0];

  return {
    durationSeconds:
      formatDuration != null && Number.isFinite(formatDuration)
        ? formatDuration
        : streamDuration ?? null,
    streams,
    raw: parsed
  };
}

export async function detectFfmpegVersion(ffmpegPath: string): Promise<string | null> {
  try {
    const result = await runCommand(ffmpegPath, ['-version'], { timeoutMs: 10_000 });
    if (result.code !== 0) return null;
    return result.stdout.split('\n')[0]?.trim() ?? null;
  } catch {
    return null;
  }
}
