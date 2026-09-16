import { randomUUID } from 'node:crypto';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import type { ContentSource, ContentType } from '../domain/job-model.js';
import { runProcess } from '../media/ffprobe.js';
import { assertPublicUrl, type SsrfCheckOptions } from '../media/ssrf.js';
import type { MediaServiceClient } from '../providers/media/types.js';

/**
 * Server-side duration probe used before reserving quota (V18 WP04). The
 * client-reported duration is never trusted. Podcasts: a bounded head download
 * (every redirect re-validated against SSRF rules) and ffprobe on the partial
 * file. Videos: media-service metadata. Unknown duration returns null and the
 * job is rejected with MEDIA_DURATION_UNKNOWN.
 */

export interface DurationProbeInput {
  contentType: ContentType;
  source: ContentSource;
}

export interface DurationProber {
  probe(input: DurationProbeInput, signal?: AbortSignal): Promise<number | null>;
}

export interface HeadFetchResult {
  bytes: Buffer;
  totalBytes: number | null;
  complete: boolean;
}

const REDIRECTS = new Set([301, 302, 303, 307, 308]);

/** Fetches at most `maxBytes` from a public URL; redirects are followed manually and re-validated. */
export async function fetchHead(
  sourceUrl: string,
  options: { maxBytes: number; ssrf?: SsrfCheckOptions; fetchImpl?: typeof fetch; timeoutMs?: number; maxRedirects?: number }
): Promise<HeadFetchResult | null> {
  const fetchImpl = options.fetchImpl ?? fetch;
  let current = sourceUrl;
  for (let redirects = 0; redirects <= (options.maxRedirects ?? 5); redirects += 1) {
    let url: URL;
    try {
      url = new URL(current);
      await assertPublicUrl(url, options.ssrf);
    } catch {
      return null;
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? 20_000);
    try {
      const response = await fetchImpl(current, {
        redirect: 'manual',
        headers: { range: `bytes=0-${options.maxBytes - 1}` },
        signal: controller.signal
      });
      if (REDIRECTS.has(response.status)) {
        const location = response.headers.get('location');
        await response.body?.cancel().catch(() => undefined);
        if (!location) return null;
        current = new URL(location, current).toString();
        continue;
      }
      if (response.status !== 200 && response.status !== 206) {
        await response.body?.cancel().catch(() => undefined);
        return null;
      }
      const rangeTotal = /\/(\d+)$/.exec(response.headers.get('content-range') ?? '')?.[1];
      const lengthHeader = response.headers.get('content-length');
      const totalBytes = rangeTotal ? Number(rangeTotal) : response.status === 200 && lengthHeader ? Number(lengthHeader) : null;
      const chunks: Buffer[] = [];
      let received = 0;
      const reader = response.body?.getReader();
      while (reader && received < options.maxBytes) {
        const { done, value } = await reader.read();
        if (done) break;
        const chunk = Buffer.from(value);
        chunks.push(chunk);
        received += chunk.length;
      }
      await reader?.cancel().catch(() => undefined);
      const bytes = Buffer.concat(chunks).subarray(0, options.maxBytes);
      return {
        bytes,
        totalBytes: totalBytes !== null && Number.isFinite(totalBytes) ? totalBytes : null,
        complete: totalBytes !== null && bytes.length >= totalBytes
      };
    } catch {
      return null;
    } finally {
      clearTimeout(timer);
    }
  }
  return null;
}

export interface FormatProbe {
  durationSeconds: number | null;
  bitrate: number | null;
}

/**
 * `bitrate` is the audio stream's codec bitrate. The container-level bit_rate
 * is derived from file size ÷ duration, which would make the constant-bitrate
 * check in estimateDuration tautological for partial files.
 */
export async function probeFormat(filePath: string, ffprobePath = 'ffprobe', timeoutMs = 15_000): Promise<FormatProbe | null> {
  try {
    const result = await runProcess(
      ffprobePath,
      ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', filePath],
      { timeoutMs }
    );
    if (result.code !== 0) return null;
    const parsed = JSON.parse(result.stdout) as {
      format?: { duration?: string };
      streams?: Array<{ codec_type?: string; bit_rate?: string }>;
    };
    const duration = Number(parsed.format?.duration);
    const bitrate = Number(parsed.streams?.find((stream) => stream.codec_type === 'audio')?.bit_rate);
    return {
      durationSeconds: Number.isFinite(duration) && duration > 0 ? duration : null,
      bitrate: Number.isFinite(bitrate) && bitrate > 0 ? bitrate : null
    };
  } catch {
    return null;
  }
}

/**
 * Chooses the full-length duration from a probe of the first bytes:
 *  - whole file fetched → the probed duration;
 *  - probed duration ≈ partial bytes × 8 / bitrate → ffprobe only estimated from
 *    the partial size (constant bitrate, no header) → scale to the total length;
 *  - otherwise the container header (Xing/VBRI/moov) reported the full duration.
 */
export function estimateDuration(input: {
  probedSeconds: number | null;
  bitrate: number | null;
  partialBytes: number;
  totalBytes: number | null;
  complete: boolean;
}): number | null {
  const { probedSeconds, bitrate, partialBytes, totalBytes, complete } = input;
  if (probedSeconds === null || probedSeconds <= 0) return null;
  if (complete) return probedSeconds;
  if (bitrate !== null) {
    const partialEstimate = (partialBytes * 8) / bitrate;
    if (Math.abs(probedSeconds - partialEstimate) <= Math.max(1, partialEstimate * 0.05)) {
      return totalBytes !== null ? (totalBytes * 8) / bitrate : null;
    }
  }
  return probedSeconds;
}

export interface DefaultDurationProberOptions {
  tempRoot: string;
  mediaClient?: MediaServiceClient;
  ffprobePath?: string;
  headBytes?: number;
  ssrf?: SsrfCheckOptions;
  fetchImpl?: typeof fetch;
}

export class DefaultDurationProber implements DurationProber {
  constructor(private readonly options: DefaultDurationProberOptions) {}

  async probe(input: DurationProbeInput, signal?: AbortSignal): Promise<number | null> {
    if (input.contentType === 'video') {
      if (!this.options.mediaClient?.probeDuration) return null;
      return this.options.mediaClient.probeDuration(input.source.sourceId, signal).catch(() => null);
    }
    const head = await fetchHead(input.source.url, {
      maxBytes: this.options.headBytes ?? 2 * 1024 * 1024,
      ssrf: this.options.ssrf,
      fetchImpl: this.options.fetchImpl
    });
    if (!head || head.bytes.length === 0) return null;
    const dir = join(this.options.tempRoot, 'duration-probe');
    const filePath = join(dir, `${randomUUID()}.bin`);
    try {
      await mkdir(dir, { recursive: true });
      await writeFile(filePath, head.bytes);
      const format = await probeFormat(filePath, this.options.ffprobePath);
      if (!format) return null;
      return estimateDuration({
        probedSeconds: format.durationSeconds,
        bitrate: format.bitrate,
        partialBytes: head.bytes.length,
        totalBytes: head.totalBytes,
        complete: head.complete
      });
    } finally {
      await rm(filePath, { force: true });
    }
  }
}
