import { existsSync } from 'node:fs';
import { access, constants, mkdir, open, readFile, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import type { IncomingMessage, ServerResponse } from 'node:http';

import { parseUrl, sendJson } from './http-utils.js';
import type { ServiceConfig } from '../config/index.js';

export const SERVICE_NAME = 'linguacast-assistant';
export const SERVICE_VERSION = '0.1.0';

export interface ReadinessCheckResult {
  ok: boolean;
  detail?: string;
}

export type ReadinessCheck = () => Promise<ReadinessCheckResult>;

export interface ReadinessChecks {
  config: ReadinessCheck;
  database: ReadinessCheck;
  tempDir: ReadinessCheck;
  piConfig: ReadinessCheck;
  ytdlp: ReadinessCheck;
  youtubeApi?: ReadinessCheck;
  podcastIndex?: ReadinessCheck;
  apple?: ReadinessCheck;
  rss?: ReadinessCheck;
  workspace?: ReadinessCheck;
  skills?: ReadinessCheck;
  rg?: ReadinessCheck;
  web?: ReadinessCheck;
}

export function tempDirWritableCheck(tempRoot: string): ReadinessCheck {
  return async () => {
    try {
      await mkdir(tempRoot, { recursive: true });
      const probe = join(tempRoot, `.ready-${process.pid}.tmp`);
      const handle = await open(probe, 'w');
      await handle.close();
      await unlink(probe);
      return { ok: true };
    } catch (error) {
      return { ok: false, detail: `temp dir not writable: ${(error as NodeJS.ErrnoException).code ?? 'unknown'}` };
    }
  };
}

export function piConfigCheck(piConfigDir: string): ReadinessCheck {
  return async () => {
    try {
      const modelsPath = join(piConfigDir, 'models.json');
      const settingsPath = join(piConfigDir, 'settings.json');
      const path = existsSync(modelsPath) ? modelsPath : settingsPath;
      const raw = await readFile(path, 'utf8');
      const parsed = JSON.parse(raw) as {
        models?: unknown[];
        defaultProvider?: string;
        defaultModel?: string;
      };
      if (Array.isArray(parsed.models) && parsed.models.length > 0) {
        return { ok: true, detail: `models=${parsed.models.length}` };
      }
      if (parsed.defaultProvider && parsed.defaultModel) {
        return { ok: true, detail: `settings=${parsed.defaultProvider}/${parsed.defaultModel}` };
      }
      return { ok: false, detail: 'models.json has no models' };
    } catch (error) {
      return { ok: false, detail: `pi config unreadable: ${(error as NodeJS.ErrnoException).code ?? 'parse'}` };
    }
  };
}

export function ytdlpCheck(ytdlpPath: string): ReadinessCheck {
  return async () => {
    try {
      await access(ytdlpPath, constants.X_OK);
    } catch {
      const which = spawnSync('which', [ytdlpPath], { encoding: 'utf8' });
      if (which.status !== 0) {
        return { ok: false, detail: 'yt-dlp executable not found' };
      }
    }
    const probe = spawnSync(ytdlpPath, ['--version'], { encoding: 'utf8', timeout: 5000 });
    if (probe.status !== 0) {
      return { ok: false, detail: 'yt-dlp --version failed' };
    }
    return { ok: true, detail: (probe.stdout || '').trim().slice(0, 32) };
  };
}

export function configPresenceCheck(config: ServiceConfig): ReadinessCheck {
  return async () => {
    const identityReady = config.identity.mode === 'account'
      ? Boolean(config.identity.accountServiceUrl && config.identity.introspectionToken && config.identity.contextSigningKey)
      : Boolean(config.serviceToken);
    const ok = identityReady && Boolean(config.v10.token && config.v10.baseUrl);
    return { ok, detail: ok ? 'secrets present' : 'required configuration missing' };
  };
}

export function youtubeApiCheck(config: ServiceConfig): ReadinessCheck {
  return async () => ({
    ok: true,
    detail: config.youtubeApiKey ? 'configured' : 'not_configured'
  });
}

export function podcastIndexCheck(config: ServiceConfig): ReadinessCheck {
  return async () => {
    if (!config.podcastIndexEnabled) return { ok: true, detail: 'disabled' };
    if (!config.podcastIndexApiKey || !config.podcastIndexApiSecret) {
      return { ok: true, detail: 'misconfigured' };
    }
    return { ok: true, detail: 'configured' };
  };
}

export function appleSearchCheck(config: ServiceConfig): ReadinessCheck {
  return async () => ({ ok: true, detail: config.appleSearchBaseUrl ? 'configured' : 'missing' });
}

export function rssCheck(): ReadinessCheck {
  return async () => ({ ok: true, detail: 'ssrf_guard_enabled' });
}

export function workspaceCheck(root: string, enabled: boolean): ReadinessCheck {
  return async () => {
    if (!enabled) return { ok: true, detail: 'disabled' };
    if (!root.trim()) return { ok: false, detail: 'not_configured' };
    try {
      await mkdir(root, { recursive: true });
      const probe = join(root, `.ready-${process.pid}.tmp`);
      const handle = await open(probe, 'w');
      await handle.close();
      await unlink(probe);
      return { ok: true, detail: 'writable' };
    } catch (error) {
      return { ok: false, detail: `not_writable:${(error as NodeJS.ErrnoException).code ?? 'unknown'}` };
    }
  };
}

export function skillsCheck(enabled: boolean, loader: () => unknown): ReadinessCheck {
  return async () => {
    if (!enabled) return { ok: true, detail: 'disabled' };
    try {
      const records = loader();
      const count = Array.isArray(records) ? records.length : 0;
      return { ok: count > 0, detail: `skills=${count}` };
    } catch {
      return { ok: false, detail: 'unavailable' };
    }
  };
}

export function rgCheck(rgPath: string, enabled: boolean): ReadinessCheck {
  return async () => {
    if (!enabled) return { ok: true, detail: 'disabled' };
    const probe = spawnSync(rgPath, ['--version'], { encoding: 'utf8', timeout: 5000 });
    if (probe.status !== 0) return { ok: false, detail: 'not_found' };
    return { ok: true, detail: (probe.stdout || '').trim().split('\n')[0]?.slice(0, 32) };
  };
}

export function webCheck(enabled: boolean, configured: boolean): ReadinessCheck {
  return async () => {
    if (!enabled) return { ok: true, detail: 'disabled' };
    return { ok: true, detail: configured ? 'configured' : 'not_configured' };
  };
}

export function handleHealthLive(res: ServerResponse): void {
  sendJson(res, 200, { status: 'live', service: SERVICE_NAME, version: SERVICE_VERSION });
}

export async function handleHealthReady(
  req: IncomingMessage,
  res: ServerResponse,
  checks: ReadinessChecks
): Promise<void> {
  void req;
  const [config, database, tempDir, piConfig, ytdlp, youtubeApi, podcastIndex, apple, rss, workspace, skills, rg, web] =
    await Promise.all([
      checks.config(),
      checks.database(),
      checks.tempDir(),
      checks.piConfig(),
      checks.ytdlp(),
      checks.youtubeApi ? checks.youtubeApi() : Promise.resolve({ ok: true, detail: 'optional' }),
      checks.podcastIndex ? checks.podcastIndex() : Promise.resolve({ ok: true, detail: 'optional' }),
      checks.apple ? checks.apple() : Promise.resolve({ ok: true, detail: 'optional' }),
      checks.rss ? checks.rss() : Promise.resolve({ ok: true, detail: 'optional' }),
      checks.workspace ? checks.workspace() : Promise.resolve({ ok: true, detail: 'disabled' }),
      checks.skills ? checks.skills() : Promise.resolve({ ok: true, detail: 'disabled' }),
      checks.rg ? checks.rg() : Promise.resolve({ ok: true, detail: 'disabled' }),
      checks.web ? checks.web() : Promise.resolve({ ok: true, detail: 'disabled' })
    ]);
  const requiredOk =
    config.ok &&
    database.ok &&
    tempDir.ok &&
    piConfig.ok &&
    ytdlp.ok &&
    (!checks.workspace || workspace.ok) &&
    (!checks.skills || skills.ok) &&
    (!checks.rg || rg.ok);
  sendJson(res, requiredOk ? 200 : 503, {
    status: requiredOk ? 'ready' : 'degraded',
    service: SERVICE_NAME,
    version: SERVICE_VERSION,
    checks: {
      config,
      database,
      tempDir,
      piConfig,
      ytdlp,
      youtubeApi,
      podcastIndex,
      apple,
      rss,
      workspace,
      skills,
      rg,
      web
    }
  });
}

export function isHealthLiveRequest(req: IncomingMessage): boolean {
  return req.method === 'GET' && parseUrl(req).pathname === '/v1/assistant-health/live';
}

export function isHealthReadyRequest(req: IncomingMessage): boolean {
  return req.method === 'GET' && parseUrl(req).pathname === '/v1/assistant-health/ready';
}
