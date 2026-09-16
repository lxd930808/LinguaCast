import { spawn } from 'node:child_process';

import { DomainError } from '../domain/types.js';

export interface HttpGet {
  (url: URL, timeoutMs?: number): Promise<{
    status: number;
    json: unknown;
    text: string;
    retryAfterSeconds?: number;
  }>;
}

export const defaultHttpGet: HttpGet = async (url, timeoutMs = 15_000) => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: controller.signal, redirect: 'manual' });
    const retryAfter = response.headers.get('retry-after');
    const text = await response.text();
    let json: unknown = null;
    try {
      json = JSON.parse(text);
    } catch {
      json = null;
    }
    return {
      status: response.status,
      json,
      text,
      retryAfterSeconds: retryAfter ? Number(retryAfter) || 30 : undefined
    };
  } finally {
    clearTimeout(timer);
  }
};

export interface ProcessRunner {
  run(
    file: string,
    args: string[],
    options: { cwd: string; timeoutMs: number; stdoutMax: number; stderrMax: number }
  ): Promise<{ stdout: string; stderr: string; code: number | null }>;
}

export const defaultProcessRunner: ProcessRunner = {
  async run(file, args, options) {
    return new Promise((resolve, reject) => {
      const child = spawn(file, args, { cwd: options.cwd, stdio: ['ignore', 'pipe', 'pipe'] });
      let stdout = '';
      let stderr = '';
      let killed = false;
      const timer = setTimeout(() => {
        killed = true;
        child.kill('SIGKILL');
      }, options.timeoutMs);
      child.stdout.on('data', (chunk: Buffer) => {
        stdout += chunk.toString('utf8');
        if (Buffer.byteLength(stdout) > options.stdoutMax) {
          killed = true;
          child.kill('SIGKILL');
        }
      });
      child.stderr.on('data', (chunk: Buffer) => {
        stderr += chunk.toString('utf8');
        if (Buffer.byteLength(stderr) > options.stderrMax) {
          killed = true;
          child.kill('SIGKILL');
        }
      });
      child.on('error', (error) => {
        clearTimeout(timer);
        reject(error);
      });
      child.on('close', (code) => {
        clearTimeout(timer);
        if (killed && code !== 0) {
          reject(new DomainError('YTDLP_TIMEOUT', 'yt-dlp timed out or exceeded output limits', true, 503));
          return;
        }
        resolve({ stdout, stderr, code });
      });
    });
  }
};
