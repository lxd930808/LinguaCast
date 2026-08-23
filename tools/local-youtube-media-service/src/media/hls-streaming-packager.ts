import { spawn, type ChildProcess } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import { access, mkdir, readdir, unlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

import { summarizeFfmpegStderr } from './ffmpeg-runner.js';
import {
  openSabrSession,
  type OpenSabrSessionResult
} from '../sabr/sabr-session.js';

const execFileAsync = promisify(execFile);

export interface StreamingHlsOptions {
  ffmpegPath: string;
  workDir: string;
  videoId: string;
  preferredHeight: number;
  onProgress?: (info: {
    videoBytes: number;
    audioBytes: number;
    videoTarget?: number;
    audioTarget?: number;
  }) => void;
  /** Fired once init + first media segment + playlist exist. */
  onPlayable?: (info: {
    masterPath: string;
    playlistPath: string;
    height: number | null;
    videoCodec: string | null;
    audioCodec: string | null;
    durationSeconds: number | null;
    itagVideo: number | null;
    itagAudio: number | null;
    diagnostics: Record<string, unknown>;
  }) => void;
}

export interface StreamingHlsResult {
  masterPath: string;
  playlistPath: string;
  height: number | null;
  durationSeconds: number | null;
  videoCodec: string | null;
  audioCodec: string | null;
  itagVideo: number | null;
  itagAudio: number | null;
  diagnostics: Record<string, unknown>;
  earlyPlayableMs: number | null;
  totalElapsedMs: number;
}

async function mkfifo(filePath: string): Promise<void> {
  try {
    await unlink(filePath);
  } catch {
    // ignore missing
  }
  await execFileAsync('mkfifo', [filePath]);
}

export async function resetStreamingHlsArtifacts(
  workDir: string
): Promise<void> {
  const names = await readdir(workDir).catch(() => []);
  const generated = names.filter(
    (name) =>
      name === 'master.m3u8' ||
      name === 'index.m3u8' ||
      name === 'init.mp4' ||
      name === 'video.fifo' ||
      name === 'audio.fifo' ||
      /^segment-\d+\.m4s$/.test(name)
  );
  await Promise.allSettled(
    generated.map((name) => unlink(path.join(workDir, name)))
  );
}

async function waitForPlayableArtifacts(
  workDir: string,
  timeoutMs: number,
  signal?: AbortSignal
): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  const initPath = path.join(workDir, 'init.mp4');
  const playlistPath = path.join(workDir, 'index.m3u8');

  while (Date.now() < deadline) {
    if (signal?.aborted) return false;
    try {
      await access(initPath);
      await access(playlistPath);
      const names = await readdir(workDir);
      if (names.some((name) => /^segment-\d+\.m4s$/.test(name))) {
        return true;
      }
    } catch {
      // keep polling
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  return false;
}

async function ensureEndList(playlistPath: string): Promise<void> {
  const { readFile } = await import('node:fs/promises');
  try {
    const body = await readFile(playlistPath, 'utf8');
    if (!body.includes('#EXT-X-ENDLIST')) {
      await writeFile(
        playlistPath,
        body.endsWith('\n') ? `${body}#EXT-X-ENDLIST\n` : `${body}\n#EXT-X-ENDLIST\n`,
        'utf8'
      );
    }
  } catch {
    // playlist may already be finalized by ffmpeg event mode
  }
}

function writeMasterPlaylist(options: {
  masterPath: string;
  width: number | null;
  height: number | null;
  videoCodec: string | null;
  audioCodec: string | null;
  bandwidth: number;
}): Promise<void> {
  const codecs = [
    options.videoCodec && /avc|h264/i.test(options.videoCodec)
      ? 'avc1.640028'
      : options.videoCodec,
    options.audioCodec && /aac|mp4a/i.test(options.audioCodec)
      ? 'mp4a.40.2'
      : options.audioCodec
  ]
    .filter(Boolean)
    .join(',');

  const body = [
    '#EXTM3U',
    '#EXT-X-VERSION:7',
    `#EXT-X-STREAM-INF:BANDWIDTH=${options.bandwidth},RESOLUTION=${options.width ?? 0}x${options.height ?? 0},CODECS="${codecs}"`,
    'index.m3u8',
    ''
  ].join('\n');
  return writeFile(options.masterPath, body, 'utf8');
}

async function pumpWebStreamToFifo(
  webStream: ReadableStream<Uint8Array>,
  fifoPath: string,
  onBytes: (n: number) => void
): Promise<number> {
  let bytes = 0;
  const nodeReadable = Readable.fromWeb(webStream as any);
  const writable = createWriteStream(fifoPath);
  nodeReadable.on('data', (chunk: Buffer) => {
    bytes += chunk.byteLength;
    onBytes(bytes);
  });
  await pipeline(nodeReadable, writable);
  return bytes;
}

function spawnFfmpegHls(
  ffmpegPath: string,
  workDir: string,
  videoFifo: string,
  audioFifo: string
): { child: ChildProcess; done: Promise<void>; stderr: () => string } {
  const playlistPath = path.join(workDir, 'index.m3u8');
  const segmentPattern = path.join(workDir, 'segment-%05d.m4s');
  const args = [
    '-y',
    '-i',
    videoFifo,
    '-i',
    audioFifo,
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
    '-hls_list_size',
    '0',
    '-hls_playlist_type',
    'event',
    '-hls_segment_type',
    'fmp4',
    '-hls_fmp4_init_filename',
    'init.mp4',
    '-hls_flags',
    'independent_segments+append_list',
    '-hls_segment_filename',
    segmentPattern,
    playlistPath
  ];

  const child = spawn(ffmpegPath, args, {
    cwd: workDir,
    stdio: ['ignore', 'pipe', 'pipe']
  });

  let stderr = '';
  child.stderr?.on('data', (chunk: Buffer) => {
    stderr += chunk.toString('utf8');
  });

  const done = new Promise<void>((resolve, reject) => {
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) resolve();
      else {
        reject(
          Object.assign(
            new Error(`FFMPEG_FAILED: ${summarizeFfmpegStderr(stderr)}`),
            { code: 'FFMPEG_FAILED', stderr: summarizeFfmpegStderr(stderr) }
          )
        );
      }
    });
  });

  return { child, done, stderr: () => stderr };
}

/**
 * Stream SABR A/V through named pipes into ffmpeg HLS (event playlist).
 * Marks playable as soon as init + first segment exist; finalizes ENDLIST on EOF.
 */
export async function packageHlsStreaming(
  options: StreamingHlsOptions
): Promise<StreamingHlsResult> {
  const startedAt = Date.now();
  await mkdir(options.workDir, { recursive: true });

  const videoFifo = path.join(options.workDir, 'video.fifo');
  const audioFifo = path.join(options.workDir, 'audio.fifo');
  const playlistPath = path.join(options.workDir, 'index.m3u8');
  const masterPath = path.join(options.workDir, 'master.m3u8');

  await resetStreamingHlsArtifacts(options.workDir);
  await mkfifo(videoFifo);
  await mkfifo(audioFifo);

  let session: OpenSabrSessionResult | null = null;
  let ffmpeg: ReturnType<typeof spawnFfmpegHls> | null = null;
  let earlyPlayableMs: number | null = null;
  let playableWatcher: Promise<void> | null = null;
  const playableWatcherAbort = new AbortController();

  try {
    session = await openSabrSession({
      videoId: options.videoId,
      preferredHeight: options.preferredHeight
    });

    const width = session.selectedVideoFormat.width ?? null;
    const height = session.videoHeight;
    const bandwidth =
      (session.selectedVideoFormat.bitrate || 0) +
        (session.selectedAudioFormat.bitrate || 0) || 4_000_000;

    await writeMasterPlaylist({
      masterPath,
      width,
      height,
      videoCodec: session.videoCodec,
      audioCodec: session.audioCodec,
      bandwidth
    });

    ffmpeg = spawnFfmpegHls(
      options.ffmpegPath,
      options.workDir,
      videoFifo,
      audioFifo
    );

    let videoBytes = 0;
    let audioBytes = 0;
    const videoTarget =
      Number(session.selectedVideoFormat.contentLength || 0) || undefined;
    const audioTarget =
      Number(session.selectedAudioFormat.contentLength || 0) || undefined;
    const report = () => {
      options.onProgress?.({
        videoBytes,
        audioBytes,
        videoTarget,
        audioTarget
      });
    };

    playableWatcher = (async () => {
      const ok = await waitForPlayableArtifacts(
        options.workDir,
        120_000,
        playableWatcherAbort.signal
      );
      if (!ok || !session) return;
      earlyPlayableMs = Date.now() - startedAt;
      options.onPlayable?.({
        masterPath,
        playlistPath,
        height,
        videoCodec: session.videoCodec,
        audioCodec: session.audioCodec,
        durationSeconds: session.durationSeconds,
        itagVideo: session.selectedVideoFormat.itag ?? null,
        itagAudio: session.selectedAudioFormat.itag ?? null,
        diagnostics: {
          title: session.title,
          durationSeconds: session.durationSeconds,
          videoItag: session.selectedVideoFormat.itag ?? null,
          audioItag: session.selectedAudioFormat.itag ?? null,
          videoMime: session.videoMime,
          audioMime: session.audioMime,
          videoCodec: session.videoCodec,
          audioCodec: session.audioCodec,
          videoHeight: height,
          adaptiveFormatCount: session.adaptiveFormatCount,
          streaming: true,
          earlyPlayableMs
        }
      });
    })();

    const pumpPromise = Promise.all([
      pumpWebStreamToFifo(session.videoStream, videoFifo, (n) => {
        videoBytes = n;
        report();
      }),
      pumpWebStreamToFifo(session.audioStream, audioFifo, (n) => {
        audioBytes = n;
        report();
      })
    ]);

    const [videoWritten, audioWritten] = await pumpPromise;
    await ffmpeg.done;
    await playableWatcher;
    await ensureEndList(playlistPath);

    return {
      masterPath,
      playlistPath,
      height,
      durationSeconds: session.durationSeconds,
      videoCodec: session.videoCodec,
      audioCodec: session.audioCodec,
      itagVideo: session.selectedVideoFormat.itag ?? null,
      itagAudio: session.selectedAudioFormat.itag ?? null,
      earlyPlayableMs,
      totalElapsedMs: Date.now() - startedAt,
      diagnostics: {
        title: session.title,
        durationSeconds: session.durationSeconds,
        videoItag: session.selectedVideoFormat.itag ?? null,
        audioItag: session.selectedAudioFormat.itag ?? null,
        videoMime: session.videoMime,
        audioMime: session.audioMime,
        videoCodec: session.videoCodec,
        audioCodec: session.audioCodec,
        videoHeight: height,
        videoBytes: videoWritten,
        audioBytes: audioWritten,
        adaptiveFormatCount: session.adaptiveFormatCount,
        streaming: true,
        earlyPlayableMs
      }
    };
  } catch (error) {
    playableWatcherAbort.abort();
    session?.abort();
    ffmpeg?.child.kill('SIGKILL');
    await playableWatcher;
    throw error;
  } finally {
    await Promise.allSettled([unlink(videoFifo), unlink(audioFifo)]);
  }
}
