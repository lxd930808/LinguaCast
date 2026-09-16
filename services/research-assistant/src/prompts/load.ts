import { existsSync, readFileSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { ConfigError } from '../config/index.js';

const HERE = dirname(fileURLToPath(import.meta.url));

export const DEFAULT_SYSTEM_PROMPT_FILENAME = 'systemprompt.txt';

export function resolveSystemPromptPath(override?: string): string {
  const trimmed = override?.trim() ?? '';
  if (trimmed) {
    const path = isAbsolute(trimmed) ? trimmed : resolve(process.cwd(), trimmed);
    if (!existsSync(path)) {
      throw new ConfigError('ASSISTANT_SYSTEM_PROMPT_PATH', `file not found: ${path}`);
    }
    return path;
  }

  const candidates = [
    join(HERE, '..', '..', 'prompts', DEFAULT_SYSTEM_PROMPT_FILENAME),
    join(HERE, '..', '..', '..', 'prompts', DEFAULT_SYSTEM_PROMPT_FILENAME)
  ];
  const found = candidates.find((path) => existsSync(path));
  if (!found) {
    throw new ConfigError(
      'ASSISTANT_SYSTEM_PROMPT_PATH',
      `missing prompts/${DEFAULT_SYSTEM_PROMPT_FILENAME}`
    );
  }
  return found;
}

export function loadSystemPrompt(override?: string): string {
  const path = resolveSystemPromptPath(override);
  const text = readFileSync(path, 'utf8').trim();
  if (!text) {
    throw new ConfigError('ASSISTANT_SYSTEM_PROMPT_PATH', 'file is empty');
  }
  return text;
}

export function currentDateContext(now = new Date(), timeZone = 'Asia/Shanghai'): string {
  const fmt = new Intl.DateTimeFormat('zh-CN', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    weekday: 'long'
  });
  const parts = Object.fromEntries(fmt.formatToParts(now).map((part) => [part.type, part.value]));
  const isoDate = `${parts.year}-${parts.month}-${parts.day}`;
  return [
    '# 运行时上下文',
    '',
    `今天是 ${isoDate}（${parts.weekday}），当前公历年份为 ${parts.year}。`,
    '判断「最近 / 今年 / 现在 / 近期」时必须以这个日期为准，不要假设今天仍是 2024 或 2025。',
    '只有 publishedAt 晚于今天的日期才视为异常未来时间；今年已经发生的日期不是未来。'
  ].join('\n');
}

export function composeSystemPrompt(body: string, now = new Date()): string {
  return `${currentDateContext(now).trim()}\n\n${body.trim()}`;
}
