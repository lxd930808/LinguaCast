import type { IncomingMessage, ServerResponse } from 'node:http';

import type { ServiceConfig } from '../config.js';
import { SERVICE_VERSION } from '../config.js';
import { detectFfmpegVersion } from '../media/ffmpeg-runner.js';
import { sendJson } from './http-utils.js';

export async function handleHealth(
  _req: IncomingMessage,
  res: ServerResponse,
  config: ServiceConfig
): Promise<void> {
  const ffmpegVersion = await detectFfmpegVersion(config.ffmpegPath);
  sendJson(res, 200, {
    status: 'ok',
    serviceVersion: SERVICE_VERSION,
    ffmpegAvailable: Boolean(ffmpegVersion),
    ffmpegVersion
  });
}
