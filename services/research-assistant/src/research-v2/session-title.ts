import { createPiModels, loadPiModelCatalog, resolvePiModel } from '../agent/pi-adapter.js';
import type { ServiceConfig } from '../config/index.js';

export const DEFAULT_SESSION_TITLE = 'New research';
export const SESSION_TITLE_MAX_CHARS = 40;
export const TITLE_GENERATION_TIMEOUT_MS = 8_000;

export type SessionTitleGenerator = (input: {
  userText: string;
  outputLanguage: string;
}) => Promise<string | null>;

export function provisionalTitle(text: string): string {
  const compact = collapseWhitespace(text);
  return truncateChars(compact, SESSION_TITLE_MAX_CHARS) || DEFAULT_SESSION_TITLE;
}

export function sanitizeLlmTitle(raw: string): string | null {
  let text = collapseWhitespace(raw);
  text = text.replace(/^[#*_`>~-]+\s*/, '');
  text = text.replace(/^["'“”‘’「」『』]+/, '').replace(/["'“”‘’「」『』]+$/, '');
  text = text.replace(/[.。!！?？]+$/u, '');
  text = collapseWhitespace(text);
  const truncated = truncateChars(text, SESSION_TITLE_MAX_CHARS);
  return truncated || null;
}

export function canAutoTitle(currentTitle: string, userText: string): boolean {
  return currentTitle === DEFAULT_SESSION_TITLE || currentTitle === provisionalTitle(userText);
}

export function createPiSessionTitleGenerator(
  config: Pick<ServiceConfig, 'piConfigDir' | 'piAuthPath'>
): SessionTitleGenerator {
  return (input) => generateSessionTitle({ ...input, ...config });
}

export async function generateSessionTitle(input: {
  userText: string;
  outputLanguage: string;
  piConfigDir: string;
  piAuthPath: string;
}): Promise<string | null> {
  try {
    const catalog = loadPiModelCatalog(input.piConfigDir);
    const models = createPiModels(input.piAuthPath);
    const resolved = resolvePiModel(catalog, models);
    const language = input.outputLanguage.trim() || 'zh-Hans';
    const result = await models.completeSimple(
      resolved.model,
      {
        systemPrompt:
          `You write a short research-session title. Reply with the title only. ` +
          `At most ${SESSION_TITLE_MAX_CHARS} characters. Language: ${language}. ` +
          `No quotes, no markdown, no trailing punctuation.`,
        messages: [
          {
            role: 'user',
            content: truncateChars(collapseWhitespace(input.userText), 500),
            timestamp: Date.now()
          }
        ]
      },
      {
        reasoning: 'minimal',
        temperature: 0.2,
        maxTokens: 64,
        timeoutMs: TITLE_GENERATION_TIMEOUT_MS
      }
    );
    if (result.stopReason === 'error' || result.stopReason === 'aborted') return null;
    const text = result.content
      .filter((part): part is { type: 'text'; text: string } => part.type === 'text')
      .map((part) => part.text)
      .join('');
    return sanitizeLlmTitle(text);
  } catch {
    return null;
  }
}

function collapseWhitespace(text: string): string {
  return text.replace(/\s+/g, ' ').trim();
}

function truncateChars(text: string, max: number): string {
  return [...text].slice(0, max).join('');
}
