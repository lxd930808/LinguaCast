import { spawn } from 'node:child_process';
import { access, readdir, rename, rm, stat } from 'node:fs/promises';
import path from 'node:path';

export interface YtDlpDownloadResult {
  outputPath: string;
  height: number | null;
  videoCodec: string | null;
  audioCodec: string | null;
  durationSeconds: number | null;
  formatId: string | null;
  diagnostics: Record<string, unknown>;
}

export interface YtDlpDownloadOptions {
  videoId: string;
  preferredHeight: number;
  workDir: string;
  ytDlpBin: string;
  potBaseUrl?: string | null;
  jsRuntime?: string | null;
  signal?: AbortSignal;
  onProgress?: (progress: number) => void;
}

function formatSelector(preferredHeight: number): string {
  const h = Math.max(144, Math.floor(preferredHeight));
  // Prefer separate H.264 + AAC, then progressive MP4 under the height cap.
  return [
    `bv*[height<=${h}][vcodec^=avc1]+ba[acodec^=mp4a]`,
    `b[height<=${h}][ext=mp4][vcodec^=avc1]`,
    `b[height<=${h}][ext=mp4]`
  ].join('/');
}

async function pathExists(filePath: string): Promise<boolean> {
  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
}

function parseProgressLine(line: string): number | null {
  // yt-dlp --progress-template "download:%(progress._percent_str)s"
  const match = /(\d+(?:\.\d+)?)\s*%/.exec(line);
  if (!match) return null;
  const value = Number.parseFloat(match[1]!);
  if (!Number.isFinite(value)) return null;
  return Math.min(1, Math.max(0, value / 100));
}

async function findDownloadedMedia(workDir: string): Promise<string | null> {
  const entries = await readdir(workDir);
  const candidates = entries
    .filter((name) => /\.(mp4|mkv|webm|m4a)$/i.test(name))
    .filter((name) => !name.startsWith('.'))
    .filter((name) => name !== 'output.mp4' && name !== 'audio.m4a');
  if (candidates.length === 0) return null;

  let best: { path: string; size: number } | null = null;
  for (const name of candidates) {
    const full = path.join(workDir, name);
    const info = await stat(full);
    if (!info.isFile()) continue;
    if (!best || info.size > best.size) {
      best = { path: full, size: info.size };
    }
  }
  return best?.path ?? null;
}

export async function downloadWithYtDlp(
  options: YtDlpDownloadOptions
): Promise<YtDlpDownloadResult> {
  const {
    videoId,
    preferredHeight,
    workDir,
    ytDlpBin,
    potBaseUrl,
    jsRuntime,
    signal,
    onProgress
  } = options;

  const url = `https://www.youtube.com/watch?v=${videoId}`;
  const outTemplate = path.join(workDir, 'ytdlp.%(ext)s');
  const args = [
    // googlevideo URLs are IP-bound; dual-stack hosts often 403 when
    // InnerTube signs for IPv4 but the download egresses via IPv6.
    '--force-ipv4',
    '--no-update',
    '--no-playlist',
    '--newline',
    '--no-mtime',
    '--merge-output-format',
    'mp4',
    '-f',
    formatSelector(preferredHeight),
    '--progress',
    '--progress-template',
    'download:%(progress._percent_str)s',
    '-o',
    outTemplate,
    '--print',
    'after_move:%(height)s\t%(vcodec)s\t%(acodec)s\t%(duration)s\t%(format_id)s\t%(filepath)s',
    url
  ];

  if (jsRuntime) {
    args.unshift('--js-runtimes', jsRuntime);
  }
  if (potBaseUrl) {
    args.push(
      '--extractor-args',
      `youtubepot-bgutilhttp:base_url=${potBaseUrl}`
    );
  }

  const diagnostics: Record<string, unknown> = {
    transport: 'ytdlp',
    formatSelector: formatSelector(preferredHeight),
    potBaseUrl: potBaseUrl ?? null,
    args: args.filter((arg) => !arg.includes(workDir))
  };

  await new Promise<void>((resolve, reject) => {
    const child = spawn(ytDlpBin, args, {
      cwd: workDir,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe']
    });

    let stderr = '';
    let stdout = '';
    let settled = false;

    const onAbort = () => {
      child.kill('SIGTERM');
    };
    if (signal) {
      if (signal.aborted) {
        onAbort();
      } else {
        signal.addEventListener('abort', onAbort, { once: true });
      }
    }

    child.stdout?.on('data', (chunk: Buffer) => {
      const text = chunk.toString('utf8');
      stdout += text;
      for (const line of text.split(/\r?\n/)) {
        if (!line.startsWith('download:')) continue;
        const progress = parseProgressLine(line);
        if (progress !== null) onProgress?.(progress);
      }
    });
    child.stderr?.on('data', (chunk: Buffer) => {
      stderr += chunk.toString('utf8');
      for (const line of chunk.toString('utf8').split(/\r?\n/)) {
        const progress = parseProgressLine(line);
        if (progress !== null) onProgress?.(progress);
      }
    });

    child.on('error', (error) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener('abort', onAbort);
      reject(
        Object.assign(new Error(`Failed to spawn yt-dlp: ${error.message}`), {
          code: 'MEDIA_DOWNLOAD_FAILED',
          diagnostics
        })
      );
    });

    child.on('close', (code) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener('abort', onAbort);
      if (signal?.aborted) {
        reject(
          Object.assign(new Error('yt-dlp download cancelled'), {
            code: 'MEDIA_DOWNLOAD_FAILED',
            diagnostics
          })
        );
        return;
      }
      if (code !== 0) {
        const message = stderr.trim() || `yt-dlp exited with code ${code}`;
        const sabrOnly = /SABR|missing a URL|no video formats/i.test(message);
        reject(
          Object.assign(new Error(message.slice(0, 2000)), {
            code: sabrOnly ? 'VIDEO_UNAVAILABLE' : 'MEDIA_DOWNLOAD_FAILED',
            diagnostics: { ...diagnostics, exitCode: code, stderrTail: message.slice(-1500) }
          })
        );
        return;
      }
      diagnostics.stdoutTail = stdout.slice(-1500);
      resolve();
    });
  });

  // Prefer the filepath from --print after_move when present.
  let downloaded: string | null = null;
  let height: number | null = null;
  let videoCodec: string | null = null;
  let audioCodec: string | null = null;
  let durationSeconds: number | null = null;
  let formatId: string | null = null;

  const printLines = (diagnostics.stdoutTail as string | undefined)
    ?.split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  if (printLines) {
    for (const line of printLines) {
      if (line.startsWith('download:')) continue;
      const parts = line.split('\t');
      if (parts.length >= 6) {
        height = Number.parseInt(parts[0]!, 10);
        if (!Number.isFinite(height)) height = null;
        videoCodec = parts[1] && parts[1] !== 'none' ? parts[1] : null;
        audioCodec = parts[2] && parts[2] !== 'none' ? parts[2] : null;
        const duration = Number.parseFloat(parts[3]!);
        durationSeconds = Number.isFinite(duration) ? duration : null;
        formatId = parts[4] || null;
        if (parts[5] && (await pathExists(parts[5]))) {
          downloaded = parts[5];
        }
      }
    }
  }

  if (!downloaded) {
    downloaded = await findDownloadedMedia(workDir);
  }
  if (!downloaded) {
    throw Object.assign(new Error('yt-dlp finished but no media file was found'), {
      code: 'MEDIA_DOWNLOAD_FAILED',
      diagnostics
    });
  }

  const outputPath = path.join(workDir, 'output.mp4');
  if (path.resolve(downloaded) !== path.resolve(outputPath)) {
    await rename(downloaded, outputPath);
  }

  // Drop leftover temp/partial files from yt-dlp.
  for (const name of await readdir(workDir)) {
    if (name === 'output.mp4' || name === 'job.json' || name === 'audio.m4a') continue;
    if (name.startsWith('.')) continue;
    await rm(path.join(workDir, name), { force: true, recursive: true }).catch(() => undefined);
  }

  return {
    outputPath,
    height,
    videoCodec,
    audioCodec,
    durationSeconds,
    formatId,
    diagnostics: {
      ...diagnostics,
      outputPath: 'output.mp4',
      height,
      videoCodec,
      audioCodec,
      formatId
    }
  };
}

export { formatSelector, parseProgressLine };
