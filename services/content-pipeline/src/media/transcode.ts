import { stat } from 'node:fs/promises';

import { PipelineJobError } from '../jobs/worker.js';
import { probeMedia, runProcess, type MediaProbe } from './ffprobe.js';

// MP3 normalization (WP4): media that is already a sane MP3 passes through
// untouched (bit-identical, no generation loss); everything else is
// transcoded to a stable 128 kbps / 44.1 kHz MP3 with a bounded ffmpeg.

export interface TranscodeOptions {
  ffmpegPath?: string;
  ffprobePath?: string;
  timeoutMs?: number;
  maxOutputBytes: number;
  /** Allowed duration drift between input and output. */
  maxDurationDriftSeconds?: number;
}

export interface NormalizedAudio {
  filePath: string;
  transcoded: boolean;
  probe: MediaProbe;
}

/** True when the source is already a streamable MP3 we can publish as-is. */
export function isStableMp3(probe: MediaProbe): boolean {
  if (probe.codecName !== 'mp3') return false;
  const formats = probe.formatName.split(',');
  if (!formats.includes('mp3')) return false;
  // Reject degenerate probes; VBR files report null bitrate and are fine.
  if (probe.bitrate !== null && (probe.bitrate < 24_000 || probe.bitrate > 640_000)) return false;
  return true;
}

/**
 * Returns the input path unchanged when it is a stable MP3, otherwise
 * transcodes to `outputPath` and validates the result (duration drift,
 * output size).
 */
export async function ensureStableMp3(
  inputPath: string,
  outputPath: string,
  inputProbe: MediaProbe,
  options: TranscodeOptions
): Promise<NormalizedAudio> {
  if (isStableMp3(inputProbe)) {
    return { filePath: inputPath, transcoded: false, probe: inputProbe };
  }

  const result = await runProcess(
    options.ffmpegPath ?? 'ffmpeg',
    [
      '-hide_banner',
      '-loglevel', 'error',
      '-y',
      '-i', inputPath,
      '-vn', '-sn', '-dn',
      '-codec:a', 'libmp3lame',
      '-b:a', '128k',
      '-ar', '44100',
      outputPath
    ],
    { timeoutMs: options.timeoutMs ?? 10 * 60 * 1000, lowPriority: true }
  );
  if (result.code !== 0) {
    throw new PipelineJobError({
      code: 'UNSUPPORTED_AUDIO',
      message: `transcode failed: ${result.stderr.trim().slice(-500) || `exit ${result.code}`}`,
      retryable: false,
      failedStage: 'preparing_audio'
    });
  }

  const outputStat = await stat(outputPath);
  if (outputStat.size > options.maxOutputBytes) {
    throw new PipelineJobError({
      code: 'MEDIA_TOO_LARGE',
      message: `transcoded output ${outputStat.size} bytes exceeds limit ${options.maxOutputBytes}`,
      retryable: false,
      failedStage: 'preparing_audio',
      params: { maxBytes: options.maxOutputBytes }
    });
  }

  const outputProbe = await probeMedia(outputPath, { ffprobePath: options.ffprobePath });
  const drift = Math.abs(outputProbe.durationSeconds - inputProbe.durationSeconds);
  const allowedDrift = Math.max(
    options.maxDurationDriftSeconds ?? 1.5,
    inputProbe.durationSeconds * 0.02
  );
  if (drift > allowedDrift) {
    throw new PipelineJobError({
      code: 'UNSUPPORTED_AUDIO',
      message: `duration drift ${drift.toFixed(2)}s exceeds tolerance after transcode`,
      retryable: false,
      failedStage: 'preparing_audio'
    });
  }
  if (!isStableMp3(outputProbe)) {
    throw new PipelineJobError({
      code: 'UNSUPPORTED_AUDIO',
      message: 'transcoded output did not probe as MP3',
      retryable: false,
      failedStage: 'preparing_audio'
    });
  }

  return { filePath: outputPath, transcoded: true, probe: outputProbe };
}
