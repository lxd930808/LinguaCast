import { spawn } from 'node:child_process';

import { DomainError } from '../domain/types.js';
import type { FileTools } from './file-tools.js';
import { parseVirtualUri } from './virtual-path.js';

export const DEFAULT_MAX_GREP_MATCHES = 200;
export const DEFAULT_MAX_GREP_MS = 5000;
export const DEFAULT_GREP_TEXT_CHARS = 240;
export const DEFAULT_GREP_STDOUT_MAX = 1024 * 1024;

export interface GrepFilesRequest {
  root: string;
  pattern: string;
  mode: 'literal' | 'regex';
  glob?: string;
  caseSensitive?: boolean;
}

export interface GrepFilesMatch {
  uri: string;
  line: number;
  column: number;
  text: string;
  truncated: boolean;
}

export interface GrepFilesResult {
  matches: GrepFilesMatch[];
  matchCount: number;
  truncated: boolean;
}

export interface GrepRunResult {
  stdout: string;
  code: number | null;
  timedOut: boolean;
}

export interface GrepRunOptions {
  cwd: string;
  timeoutMs: number;
  stdoutMax: number;
  signal?: AbortSignal;
}

export interface GrepRunner {
  run(file: string, args: string[], options: GrepRunOptions): Promise<GrepRunResult>;
}

const GLOB_PATTERN = /^[A-Za-z0-9.*?_[\]!-]+$/;
const FORBIDDEN_ARGS = new Set([
  '-P',
  '--pcre2',
  '--engine=auto',
  '--engine=pcre2',
  '--pre',
  '--pre-glob',
  '--ignore-file',
  '--files-from',
  '--debug',
  '--trace'
]);

export function buildGrepArgv(input: GrepFilesRequest, maxMatches: number): string[] {
  if (input.mode !== 'literal' && input.mode !== 'regex') {
    throw new DomainError('GREP_ARGUMENT_REJECTED', 'unsupported grep mode', false, 400);
  }
  if (typeof input.pattern !== 'string' || input.pattern.length < 1 || input.pattern.length > 512) {
    throw new DomainError('GREP_ARGUMENT_REJECTED', 'unsupported grep pattern shape', false, 400);
  }
  if (input.pattern.includes('\0')) {
    throw new DomainError('GREP_ARGUMENT_REJECTED', 'unsupported grep pattern shape', false, 400);
  }
  if (input.mode === 'regex' && /\(\?(=|!|<=|<!|P|R)/.test(input.pattern)) {
    throw new DomainError('GREP_PATTERN_REJECTED', 'regex was rejected by the linear-time engine', false, 400);
  }
  if (input.glob !== undefined) {
    if (
      input.glob.length < 1 ||
      input.glob.length > 128 ||
      input.glob.startsWith('-') ||
      input.glob.includes('/') ||
      input.glob.includes('\\') ||
      input.glob.includes('\0') ||
      input.glob.includes('..') ||
      !GLOB_PATTERN.test(input.glob)
    ) {
      throw new DomainError('GREP_ARGUMENT_REJECTED', 'unsupported grep glob', false, 400);
    }
  }
  const argv = [
    '--json',
    '--no-config',
    '--no-follow',
    '--engine=default',
    '--max-count',
    String(maxMatches)
  ];
  if (input.glob) {
    argv.push('-g', input.glob);
  }
  if (input.caseSensitive !== true) {
    argv.push('--ignore-case');
  }
  if (input.mode === 'literal') {
    argv.push('-F');
  }
  argv.push('--regexp', input.pattern, '--', '.');
  if (argv.some((arg) => FORBIDDEN_ARGS.has(arg) || arg.startsWith('--pre') || arg.startsWith('--pcre'))) {
    throw new DomainError('GREP_ARGUMENT_REJECTED', 'unsupported grep flag', false, 400);
  }
  return argv;
}

export const defaultGrepRunner: GrepRunner = {
  async run(file, args, options) {
    return new Promise((resolve, reject) => {
      const child = spawn(file, args, {
        cwd: options.cwd,
        shell: false,
        detached: true,
        stdio: ['ignore', 'pipe', 'pipe']
      });
      let stdout = Buffer.alloc(0);
      let timedOut = false;
      let outputCapped = false;
      const killGroup = () => {
        if (child.pid) {
          try {
            process.kill(-child.pid, 'SIGKILL');
          } catch {
            child.kill('SIGKILL');
          }
        }
      };
      const timer = setTimeout(() => {
        timedOut = true;
        killGroup();
      }, options.timeoutMs);
      child.stdout?.on('data', (chunk: Buffer) => {
        stdout = Buffer.concat([stdout, chunk]);
        if (stdout.length > options.stdoutMax) {
          outputCapped = true;
          killGroup();
        }
      });
      child.stderr?.resume();
      const onAbort = () => {
        timedOut = true;
        killGroup();
      };
      if (options.signal?.aborted) {
        onAbort();
      } else {
        options.signal?.addEventListener('abort', onAbort, { once: true });
      }
      child.on('error', (error) => {
        clearTimeout(timer);
        options.signal?.removeEventListener('abort', onAbort);
        reject(error);
      });
      child.on('close', (code) => {
        clearTimeout(timer);
        options.signal?.removeEventListener('abort', onAbort);
        resolve({
          stdout: stdout.subarray(0, options.stdoutMax).toString('utf8'),
          code,
          timedOut: timedOut || outputCapped
        });
      });
    });
  }
};

export class GrepAdapter {
  constructor(
    private readonly rgPath: string,
    private readonly maxMatches = DEFAULT_MAX_GREP_MATCHES,
    private readonly timeoutMs = DEFAULT_MAX_GREP_MS,
    private readonly runner: GrepRunner = defaultGrepRunner
  ) {}

  async grep(tools: FileTools, input: GrepFilesRequest, signal?: AbortSignal): Promise<GrepFilesResult> {
    parseVirtualUri(input.root);
    const argv = buildGrepArgv(input, this.maxMatches);
    const { cwd, parsed } = tools.resolveForGrep(input.root);
    let run: GrepRunResult;
    try {
      run = await this.runner.run(this.rgPath, argv, {
        cwd,
        timeoutMs: this.timeoutMs,
        stdoutMax: DEFAULT_GREP_STDOUT_MAX,
        signal
      });
    } catch {
      throw new DomainError('GREP_TIMEOUT', 'grep process group was terminated', true, 504);
    }
    if (run.timedOut && run.stdout.trim() === '') {
      throw new DomainError('GREP_TIMEOUT', 'grep process group was terminated', true, 504);
    }
    if (run.code !== 0 && run.code !== 1 && !run.timedOut) {
      if (/regex parse error|invalid regex|PCRE2/i.test(run.stdout)) {
        throw new DomainError('GREP_PATTERN_REJECTED', 'regex was rejected by the linear-time engine', false, 400);
      }
      throw new DomainError('GREP_ARGUMENT_REJECTED', 'unsupported grep invocation', false, 400);
    }
    return this.parseOutput(run.stdout, tools, parsed, run.timedOut);
  }

  private parseOutput(
    stdout: string,
    tools: FileTools,
    parsed: ReturnType<typeof parseVirtualUri>,
    timedOut: boolean
  ): GrepFilesResult {
    const matches: GrepFilesMatch[] = [];
    let truncated = timedOut;
    for (const line of stdout.split('\n')) {
      if (!line.trim()) continue;
      let event: { type?: string; data?: Record<string, unknown> };
      try {
        event = JSON.parse(line) as { type?: string; data?: Record<string, unknown> };
      } catch {
        continue;
      }
      if (event.type === 'binary') {
        continue;
      }
      if (event.type !== 'match' || !event.data) continue;
      const data = event.data;
      const pathText =
        data.path && typeof data.path === 'object' && typeof (data.path as { text?: string }).text === 'string'
          ? (data.path as { text: string }).text
          : null;
      if (!pathText || pathText.startsWith('/') || pathText.includes('\0')) continue;
      const uri = tools.toVirtualFromRelative(parsed, pathText);
      if (!uri) continue;
      const lines = data.lines as { text?: string } | undefined;
      const rawText = typeof lines?.text === 'string' ? lines.text.replace(/\n$/, '') : '';
      if (rawText.includes('\0')) continue;
      const truncatedText = rawText.length > DEFAULT_GREP_TEXT_CHARS;
      const submatches = Array.isArray(data.submatches) ? data.submatches : [];
      const column =
        submatches[0] && typeof (submatches[0] as { start?: number }).start === 'number'
          ? Number((submatches[0] as { start: number }).start) + 1
          : 1;
      matches.push({
        uri,
        line: typeof data.line_number === 'number' && data.line_number > 0 ? data.line_number : 1,
        column: column < 1 ? 1 : column,
        text: rawText.slice(0, DEFAULT_GREP_TEXT_CHARS),
        truncated: truncatedText
      });
      if (matches.length >= this.maxMatches) {
        truncated = true;
        break;
      }
    }
    return {
      matches,
      matchCount: matches.length,
      truncated
    };
  }
}
