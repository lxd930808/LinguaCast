import { tmpdir } from 'node:os';
import path from 'node:path';

import type { R2Config } from './ytdlp/r2-uploader.js';

export const SERVICE_VERSION = '0.2.0';
export const DEFAULT_PORT = 3210;
/** Ready/failed jobs expire quickly to keep disk small (plan: 30–60 min). */
export const DEFAULT_JOB_TTL_MS = 45 * 60 * 1000;
export const DEFAULT_PREFERRED_HEIGHT = 720;
export const DEFAULT_MAX_CONCURRENT_JOBS = 1;
export const DEFAULT_MIN_FREE_BYTES = 5 * 1024 * 1024 * 1024;
export const DEFAULT_DOWNLOAD_ENGINE: DownloadEngine = 'ytdlp';

export type MediaMode = 'mp4' | 'hls';
export type DownloadEngine = 'ytdlp' | 'sabr';

export interface ServiceConfig {
  host: string;
  port: number;
  publicBaseUrl: string;
  bearerToken: string;
  mediaRoot: string;
  jobTtlMs: number;
  preferredHeight: number;
  ffmpegPath: string;
  ffprobePath: string;
  downloadEngine: DownloadEngine;
  ytDlpBin: string;
  potBaseUrl: string | null;
  jsRuntime: string | null;
  maxConcurrentJobs: number;
  minFreeBytes: number;
  requireMediaAuth: boolean;
  r2: R2Config | null;
}

function env(name: string, fallback?: string): string | undefined {
  const value = process.env[name]?.trim();
  if (value) return value;
  return fallback;
}

function envInt(name: string, fallback: number): number {
  const raw = env(name);
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function envBool(name: string, fallback: boolean): boolean {
  const raw = env(name)?.toLowerCase();
  if (raw === undefined) return fallback;
  return raw === '1' || raw === 'true' || raw === 'yes' || raw === 'on';
}

function loadR2Config(): R2Config | null {
  const accountId = env('R2_ACCOUNT_ID');
  const accessKeyId = env('R2_ACCESS_KEY_ID');
  const secretAccessKey = env('R2_SECRET_ACCESS_KEY');
  const bucket = env('R2_BUCKET');
  if (!accountId || !accessKeyId || !secretAccessKey || !bucket) {
    return null;
  }
  return {
    accountId,
    accessKeyId,
    secretAccessKey,
    bucket,
    publicBaseUrl: env('R2_PUBLIC_BASE_URL') ?? null,
    keyPrefix: env('R2_KEY_PREFIX', 'yt-media') ?? 'yt-media',
    signedUrlTtlSeconds: envInt('R2_SIGNED_URL_TTL_SECONDS', 3600)
  };
}

export function loadConfig(): ServiceConfig {
  const port = envInt('PORT', DEFAULT_PORT);
  const host = env('HOST', '0.0.0.0') ?? '0.0.0.0';
  const bearerToken = env('AUTH_TOKEN');
  if (!bearerToken) {
    throw new Error('AUTH_TOKEN is required');
  }
  const mediaRoot =
    env('MEDIA_ROOT') ?? path.join(tmpdir(), 'podcast-yt-media');
  const publicBaseUrl =
    env('PUBLIC_BASE_URL') ?? `http://127.0.0.1:${port}`;
  const engineRaw = (env('DOWNLOAD_ENGINE', DEFAULT_DOWNLOAD_ENGINE) ?? 'ytdlp').toLowerCase();
  const downloadEngine: DownloadEngine =
    engineRaw === 'sabr' ? 'sabr' : 'ytdlp';

  return {
    host,
    port,
    publicBaseUrl: publicBaseUrl.replace(/\/$/, ''),
    bearerToken,
    mediaRoot,
    jobTtlMs: envInt('JOB_TTL_MS', DEFAULT_JOB_TTL_MS),
    preferredHeight: envInt('PREFERRED_HEIGHT', DEFAULT_PREFERRED_HEIGHT),
    ffmpegPath: env('FFMPEG_PATH', 'ffmpeg') ?? 'ffmpeg',
    ffprobePath: env('FFPROBE_PATH', 'ffprobe') ?? 'ffprobe',
    downloadEngine,
    ytDlpBin: env('YT_DLP_BIN', 'yt-dlp') ?? 'yt-dlp',
    potBaseUrl: env('POT_BASE_URL') ?? null,
    jsRuntime: env('YT_DLP_JS_RUNTIME', 'node') ?? 'node',
    maxConcurrentJobs: Math.max(1, envInt('MAX_CONCURRENT_JOBS', DEFAULT_MAX_CONCURRENT_JOBS)),
    minFreeBytes: envInt('MIN_FREE_BYTES', DEFAULT_MIN_FREE_BYTES),
    requireMediaAuth: envBool('REQUIRE_MEDIA_AUTH', true),
    r2: loadR2Config()
  };
}
