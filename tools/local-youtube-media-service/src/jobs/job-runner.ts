import { copyFile, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';

import type { ServiceConfig } from '../config.js';
import { packageHlsStreaming } from '../media/hls-streaming-packager.js';
import { packageMp4 } from '../media/mp4-packager.js';
import { ffprobeJson, runCommand } from '../media/ffmpeg-runner.js';
import { fetchSabrTracks } from '../youtube/youtube-resolver.js';
import {
  deleteR2Object,
  mediaObjectKey,
  uploadFileToR2
} from '../ytdlp/r2-uploader.js';
import { downloadWithYtDlp } from '../ytdlp/yt-dlp-engine.js';
import { mediaUrl, type JobErrorCode } from './job-model.js';
import type { JobStore } from './job-store.js';

function errorChain(error: unknown): Array<Record<string, unknown>> {
  const chain: Array<Record<string, unknown>> = [];
  let current: unknown = error;
  for (let depth = 0; depth < 4; depth += 1) {
    if (!current || typeof current !== 'object') break;
    chain.push({
      name: current instanceof Error ? current.name : undefined,
      message: current instanceof Error ? current.message : String(current),
      code:
        'code' in current && current.code !== undefined
          ? String(current.code)
          : undefined
    });
    current = 'cause' in current ? current.cause : undefined;
  }
  return chain;
}

function mapErrorCode(error: unknown): JobErrorCode {
  if (error && typeof error === 'object' && 'code' in error) {
    const code = String((error as { code?: unknown }).code);
    switch (code) {
      case 'VIDEO_UNAVAILABLE':
      case 'SABR_REQUEST_FAILED':
      case 'SABR_PARSE_FAILED':
      case 'SABR_ATTESTATION_REQUIRED':
      case 'MEDIA_DOWNLOAD_FAILED':
      case 'UNSUPPORTED_CODEC':
      case 'FFMPEG_FAILED':
      case 'MEDIA_EXPIRED':
      case 'INVALID_VIDEO_ID':
      case 'DISK_FULL':
      case 'BUSY':
        return code;
      default:
        break;
    }
  }
  const message = error instanceof Error ? error.message : String(error);
  if (/unavailable|private|not available|no video formats/i.test(message)) {
    return 'VIDEO_UNAVAILABLE';
  }
  if (/ffmpeg/i.test(message)) return 'FFMPEG_FAILED';
  if (/unsupported_codec|codec/i.test(message)) return 'UNSUPPORTED_CODEC';
  if (/sabr|ustreamer|po.?token|botguard/i.test(message)) return 'SABR_REQUEST_FAILED';
  if (/yt-dlp|download/i.test(message)) return 'MEDIA_DOWNLOAD_FAILED';
  return 'INTERNAL_ERROR';
}

export class JobRunner {
  private readonly running = new Map<string, AbortController>();
  private readonly waitQueue: string[] = [];

  constructor(
    private readonly store: JobStore,
    private readonly config: ServiceConfig
  ) {}

  enqueue(jobId: string): void {
    if (this.running.has(jobId) || this.waitQueue.includes(jobId)) return;
    this.waitQueue.push(jobId);
    this.pump();
  }

  cancel(jobId: string): void {
    const index = this.waitQueue.indexOf(jobId);
    if (index >= 0) this.waitQueue.splice(index, 1);
    const controller = this.running.get(jobId);
    if (controller) controller.abort();
  }

  activeCount(): number {
    return this.running.size;
  }

  private pump(): void {
    while (
      this.running.size < this.config.maxConcurrentJobs &&
      this.waitQueue.length > 0
    ) {
      const jobId = this.waitQueue.shift()!;
      if (this.running.has(jobId)) continue;
      const controller = new AbortController();
      this.running.set(jobId, controller);
      void this.run(jobId, controller.signal).finally(() => {
        this.running.delete(jobId);
        this.pump();
      });
    }
  }

  private async run(jobId: string, signal: AbortSignal): Promise<void> {
    const job = this.store.get(jobId);
    if (!job) return;

    const startedAt = Date.now();
    console.info(
      `[job ${jobId}] start videoId=${job.videoId} mode=${job.mode} engine=${this.config.downloadEngine}`
    );

    try {
      this.store.markStatus(jobId, 'resolving', 0.05);

      if (this.config.downloadEngine === 'ytdlp') {
        await this.runYtDlp(jobId, startedAt, signal);
        return;
      }

      if (job.mode === 'hls') {
        await this.runStreamingHls(jobId, startedAt);
        return;
      }

      await this.runSabrMp4(jobId, startedAt);
    } catch (error) {
      if (signal.aborted) {
        this.store.fail(jobId, 'MEDIA_DOWNLOAD_FAILED', 'Job cancelled');
        return;
      }
      const code = mapErrorCode(error);
      const message = error instanceof Error ? error.message : String(error);
      const failureDiagnostics =
        error &&
        typeof error === 'object' &&
        'diagnostics' in error &&
        error.diagnostics &&
        typeof error.diagnostics === 'object'
          ? (error.diagnostics as Record<string, unknown>)
          : {};
      this.store.update(jobId, {
        diagnostics: {
          ...failureDiagnostics,
          failure: {
            code,
            chain: errorChain(error)
          }
        }
      });
      this.store.fail(jobId, code, message);
      console.error(`[job ${jobId}] failed code=${code} message=${message}`);
    }
  }

  private async runYtDlp(
    jobId: string,
    startedAt: number,
    signal: AbortSignal
  ): Promise<void> {
    const job = this.store.get(jobId);
    if (!job) return;

    this.store.markStatus(jobId, 'fetching', 0.1);
    const downloaded = await downloadWithYtDlp({
      videoId: job.videoId,
      preferredHeight: job.preferredHeight,
      workDir: job.workDir,
      ytDlpBin: this.config.ytDlpBin,
      potBaseUrl: this.config.potBaseUrl,
      jsRuntime: this.config.jsRuntime,
      signal,
      onProgress: (ratio) => {
        this.store.update(jobId, {
          status: 'fetching',
          progress: 0.1 + ratio * 0.65
        });
      }
    });

    this.store.update(jobId, {
      diagnostics: {
        ...downloaded.diagnostics,
        fetchElapsedMs: Date.now() - startedAt
      }
    });

    this.store.markStatus(jobId, 'packaging', 0.8);

    // Ensure AVPlayer-friendly container; stream-copy when already H.264/AAC MP4.
    const remuxed = path.join(job.workDir, 'output.remux.mp4');
    try {
      const remux = await runCommand(this.config.ffmpegPath, [
        '-y',
        '-i',
        downloaded.outputPath,
        '-c',
        'copy',
        '-movflags',
        '+faststart',
        remuxed
      ]);
      if (remux.code === 0) {
        await copyFile(remuxed, downloaded.outputPath);
      }
      await rm(remuxed, { force: true });
    } catch {
      await rm(remuxed, { force: true }).catch(() => undefined);
    }

    let height = downloaded.height;
    let videoCodec = downloaded.videoCodec;
    let audioCodec = downloaded.audioCodec;
    let durationSeconds = downloaded.durationSeconds;
    try {
      const probe = await ffprobeJson(this.config.ffprobePath, downloaded.outputPath);
      const video = probe.streams.find((s) => s.codecType === 'video');
      const audio = probe.streams.find((s) => s.codecType === 'audio');
      height = video?.height ?? height;
      videoCodec = video?.codecName ?? videoCodec;
      audioCodec = audio?.codecName ?? audioCodec;
      durationSeconds = probe.durationSeconds ?? durationSeconds;
    } catch {
      // optional
    }

    // Optional AAC extract for ASR (best-effort).
    const audioPath = path.join(job.workDir, 'audio.m4a');
    try {
      const extract = await runCommand(this.config.ffmpegPath, [
        '-y',
        '-i',
        downloaded.outputPath,
        '-vn',
        '-c:a',
        'copy',
        audioPath
      ]);
      if (extract.code !== 0) {
        await rm(audioPath, { force: true }).catch(() => undefined);
      }
    } catch {
      await rm(audioPath, { force: true }).catch(() => undefined);
    }

    if (job.mode === 'hls') {
      const hlsDir = path.join(job.workDir, 'hls');
      await mkdir(hlsDir, { recursive: true });
      const hls = await runCommand(this.config.ffmpegPath, [
        '-y',
        '-i',
        downloaded.outputPath,
        '-c',
        'copy',
        '-f',
        'hls',
        '-hls_time',
        '4',
        '-hls_playlist_type',
        'vod',
        '-hls_segment_filename',
        path.join(hlsDir, 'seg_%03d.m4s'),
        path.join(hlsDir, 'master.m3u8')
      ]);
      if (hls.code !== 0) {
        throw Object.assign(new Error(hls.stderr.slice(0, 500) || 'HLS remux failed'), {
          code: 'FFMPEG_FAILED'
        });
      }
      await copyFile(path.join(hlsDir, 'master.m3u8'), path.join(job.workDir, 'master.m3u8'));
    }

    const playbackUrls = await this.publishPlayback(jobId, {
      kind: job.mode,
      localVideoName: job.mode === 'hls' ? 'master.m3u8' : 'output.mp4',
      localAudioName: job.mode === 'mp4' ? 'audio.m4a' : null
    });

    this.store.ready(jobId, {
      kind: job.mode,
      url: playbackUrls.url,
      audioUrl: playbackUrls.audioUrl,
      height,
      videoCodec,
      audioCodec,
      durationSeconds,
      itagVideo: null,
      itagAudio: null
    });
    this.store.update(jobId, {
      diagnostics: {
        packageElapsedMs: Date.now() - startedAt,
        engine: 'ytdlp'
      }
    });
    console.info(
      `[job ${jobId}] ready engine=ytdlp height=${height} elapsedMs=${Date.now() - startedAt}`
    );
  }

  private async publishPlayback(
    jobId: string,
    files: {
      kind: 'mp4' | 'hls';
      localVideoName: string;
      localAudioName: string | null;
    }
  ): Promise<{ url: string; audioUrl?: string }> {
    const job = this.store.get(jobId);
    if (!job) throw new Error('job missing');

    const token = this.config.requireMediaAuth ? this.config.bearerToken : null;
    if (!this.config.r2 || files.kind === 'hls') {
      // HLS segments stay on the origin; R2 only hosts complete MP4/audio.
      return {
        url: mediaUrl(
          this.config.publicBaseUrl,
          jobId,
          files.localVideoName,
          token
        ),
        audioUrl: files.localAudioName
          ? mediaUrl(
              this.config.publicBaseUrl,
              jobId,
              files.localAudioName,
              token
            )
          : undefined
      };
    }

    const r2Keys: string[] = [];
    const videoKey = mediaObjectKey(
      this.config.r2.keyPrefix,
      jobId,
      files.localVideoName
    );
    const videoUpload = await uploadFileToR2({
      config: this.config.r2,
      localPath: path.join(job.workDir, files.localVideoName),
      key: videoKey,
      contentType: 'video/mp4'
    });
    r2Keys.push(videoKey);

    let audioUrl: string | undefined;
    if (files.localAudioName) {
      const audioLocal = path.join(job.workDir, files.localAudioName);
      try {
        const audioKey = mediaObjectKey(
          this.config.r2.keyPrefix,
          jobId,
          files.localAudioName
        );
        const audioUpload = await uploadFileToR2({
          config: this.config.r2,
          localPath: audioLocal,
          key: audioKey,
          contentType: 'audio/mp4'
        });
        r2Keys.push(audioKey);
        audioUrl = audioUpload.url;
      } catch {
        // optional
      }
    }

    this.store.update(jobId, {
      diagnostics: { r2Keys, r2Bytes: videoUpload.bytes }
    });
    const current = this.store.get(jobId);
    if (current) {
      current.r2Keys = r2Keys;
    }

    await rm(path.join(job.workDir, files.localVideoName), { force: true }).catch(
      () => undefined
    );
    if (files.localAudioName) {
      await rm(path.join(job.workDir, files.localAudioName), {
        force: true
      }).catch(() => undefined);
    }

    return { url: videoUpload.url, audioUrl };
  }

  private async runSabrMp4(jobId: string, startedAt: number): Promise<void> {
    const job = this.store.get(jobId);
    if (!job) return;

    this.store.markStatus(jobId, 'fetching', 0.1);
    const sabr = await fetchSabrTracks({
      videoId: job.videoId,
      preferredHeight: job.preferredHeight,
      workDir: job.workDir,
      onResolved: (info) => {
        this.store.update(jobId, {
          diagnostics: {
            transport: info.transport,
            videoItag: info.videoItag,
            audioItag: info.audioItag,
            videoCodec: info.videoCodec,
            audioCodec: info.audioCodec,
            videoHeight: info.videoHeight,
            videoTarget: info.videoTarget,
            audioTarget: info.audioTarget,
            resumedVideoBytes: info.resumedVideoBytes,
            resumedAudioBytes: info.resumedAudioBytes
          }
        });
      },
      onDiagnostic: (diagnostic) => {
        if (diagnostic.kind === 'chunk-complete') return;
        this.store.update(jobId, {
          diagnostics: { directDownload: diagnostic }
        });
      },
      onProgress: ({ videoBytes, audioBytes, videoTarget, audioTarget }) => {
        const videoRatio =
          videoTarget && videoTarget > 0 ? videoBytes / videoTarget : 0;
        const audioRatio =
          audioTarget && audioTarget > 0 ? audioBytes / audioTarget : 0;
        const ratio =
          videoTarget || audioTarget
            ? Math.min(1, (videoRatio + audioRatio) / 2)
            : 0;
        this.store.update(jobId, {
          status: 'fetching',
          progress: 0.1 + ratio * 0.55,
          diagnostics: {
            videoBytes,
            audioBytes,
            videoTarget,
            audioTarget
          }
        });
      }
    });

    this.store.update(jobId, {
      diagnostics: {
        ...sabr.diagnostics,
        fetchElapsedMs: Date.now() - startedAt
      }
    });

    this.store.markStatus(jobId, 'packaging', 0.7);
    const packaged = await packageMp4({
      ffmpegPath: this.config.ffmpegPath,
      ffprobePath: this.config.ffprobePath,
      workDir: job.workDir,
      videoPath: sabr.video.filePath,
      audioPath: sabr.audio.filePath,
      videoCodecHint: sabr.video.codec,
      audioCodecHint: sabr.audio.codec
    });

    const playbackUrls = await this.publishPlayback(jobId, {
      kind: 'mp4',
      localVideoName: 'output.mp4',
      localAudioName: 'audio.m4a'
    });

    this.store.ready(jobId, {
      kind: 'mp4',
      url: playbackUrls.url,
      audioUrl: playbackUrls.audioUrl,
      height: packaged.height,
      videoCodec: packaged.videoCodec,
      audioCodec: packaged.audioCodec,
      durationSeconds: packaged.durationSeconds ?? sabr.durationSeconds,
      itagVideo: sabr.video.itag,
      itagAudio: sabr.audio.itag
    });
    this.store.update(jobId, {
      diagnostics: {
        packageElapsedMs: Date.now() - startedAt,
        ffprobe: packaged.ffprobeSummary
      }
    });

    console.info(
      `[job ${jobId}] ready height=${this.store.get(jobId)?.playback?.height} elapsedMs=${Date.now() - startedAt}`
    );
  }

  private async runStreamingHls(jobId: string, startedAt: number): Promise<void> {
    const job = this.store.get(jobId);
    if (!job) return;

    this.store.markStatus(jobId, 'fetching', 0.1);
    let markedReady = false;

    const result = await packageHlsStreaming({
      ffmpegPath: this.config.ffmpegPath,
      workDir: job.workDir,
      videoId: job.videoId,
      preferredHeight: job.preferredHeight,
      onProgress: ({ videoBytes, audioBytes, videoTarget, audioTarget }) => {
        const videoRatio =
          videoTarget && videoTarget > 0 ? videoBytes / videoTarget : 0;
        const audioRatio =
          audioTarget && audioTarget > 0 ? audioBytes / audioTarget : 0;
        const ratio =
          videoTarget || audioTarget
            ? Math.min(0.95, (videoRatio + audioRatio) / 2)
            : 0;
        if (markedReady) {
          this.store.update(jobId, {
            progress: Math.max(0.35, 0.35 + ratio * 0.6),
            diagnostics: {
              videoBytes,
              audioBytes,
              videoTarget,
              audioTarget
            }
          });
        } else {
          this.store.update(jobId, {
            status: 'packaging',
            progress: 0.15 + ratio * 0.2,
            diagnostics: {
              videoBytes,
              audioBytes,
              videoTarget,
              audioTarget
            }
          });
        }
      },
      onPlayable: (info) => {
        markedReady = true;
        this.store.ready(
          jobId,
          {
            kind: 'hls',
            url: `${this.config.publicBaseUrl}/media/${jobId}/master.m3u8`,
            height: info.height,
            videoCodec: info.videoCodec,
            audioCodec: info.audioCodec,
            durationSeconds: info.durationSeconds,
            itagVideo: info.itagVideo,
            itagAudio: info.itagAudio
          },
          0.35
        );
        this.store.update(jobId, {
          diagnostics: {
            ...info.diagnostics,
            earlyPlayableMs: info.diagnostics.earlyPlayableMs ?? Date.now() - startedAt
          }
        });
        console.info(
          `[job ${jobId}] playable (streaming HLS) earlyMs=${Date.now() - startedAt}`
        );
      }
    });

    if (!markedReady) {
      this.store.ready(jobId, {
        kind: 'hls',
        url: `${this.config.publicBaseUrl}/media/${jobId}/master.m3u8`,
        height: result.height,
        videoCodec: result.videoCodec,
        audioCodec: result.audioCodec,
        durationSeconds: result.durationSeconds,
        itagVideo: result.itagVideo,
        itagAudio: result.itagAudio
      });
    } else {
      this.store.update(jobId, { progress: 1 });
    }

    this.store.update(jobId, {
      diagnostics: {
        ...result.diagnostics,
        packageElapsedMs: Date.now() - startedAt,
        earlyPlayableMs: result.earlyPlayableMs,
        totalElapsedMs: result.totalElapsedMs
      }
    });

    console.info(
      `[job ${jobId}] hls complete height=${result.height} earlyMs=${result.earlyPlayableMs} totalMs=${result.totalElapsedMs}`
    );
  }
}

export async function deleteJobArtifacts(
  store: JobStore,
  config: ServiceConfig,
  jobId: string
): Promise<void> {
  const job = store.get(jobId);
  const keys = job?.r2Keys ?? [];
  if (config.r2 && keys.length > 0) {
    for (const key of keys) {
      await deleteR2Object(config.r2, key).catch((error) => {
        console.warn(`[job ${jobId}] R2 delete failed key=${key}: ${error}`);
      });
    }
  }
  await store.remove(jobId);
}
