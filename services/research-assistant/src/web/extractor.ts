import { createHash } from 'node:crypto';

import { nowIso } from '../domain/ids.js';

export const EXTRACTOR_VERSION = 'html-md-v1';

export interface ExtractedPage {
  title: string;
  site: string;
  markdown: string;
  passages: Array<{ passageId: string; text: string }>;
  sha256: string;
}

export function extractPage(input: {
  html: string;
  originalUrl: string;
  finalUrl: string;
  mime: string;
  fetchedAt?: string;
}): ExtractedPage {
  const stripped = input.html
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, '');
  const title = textOf(stripped.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]) || hostnameOf(input.finalUrl);
  const withBreaks = stripped
    .replace(/<h1[^>]*>([\s\S]*?)<\/h1>/gi, '\n# $1\n')
    .replace(/<h2[^>]*>([\s\S]*?)<\/h2>/gi, '\n## $1\n')
    .replace(/<h3[^>]*>([\s\S]*?)<\/h3>/gi, '\n### $1\n')
    .replace(/<p[^>]*>([\s\S]*?)<\/p>/gi, '\n$1\n')
    .replace(/<li[^>]*>([\s\S]*?)<\/li>/gi, '\n- $1\n')
    .replace(/<a[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi, '[$2]($1)')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<[^>]+>/g, ' ');
  const body = decodeEntities(withBreaks).replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  const passages = body
    .split(/\n{2,}/)
    .map((part) => part.trim())
    .filter(Boolean)
    .map((text, index) => ({ passageId: `p${String(index + 1).padStart(3, '0')}`, text }));
  const yaml = [
    '---',
    `originalUrl: ${JSON.stringify(input.originalUrl)}`,
    `finalUrl: ${JSON.stringify(input.finalUrl)}`,
    `title: ${JSON.stringify(title)}`,
    `site: ${JSON.stringify(hostnameOf(input.finalUrl))}`,
    'publishedAt: null',
    `fetchedAt: ${JSON.stringify(input.fetchedAt ?? nowIso())}`,
    `mime: ${JSON.stringify(input.mime)}`,
    `bytes: ${Buffer.byteLength(body)}`,
    `sha256: ${createHash('sha256').update(body).digest('hex')}`,
    `extractorVersion: ${JSON.stringify(EXTRACTOR_VERSION)}`,
    '---',
    '',
    body
  ].join('\n');
  return {
    title,
    site: hostnameOf(input.finalUrl),
    markdown: yaml,
    passages,
    sha256: createHash('sha256').update(yaml).digest('hex')
  };
}

function hostnameOf(raw: string): string {
  try {
    return new URL(raw).hostname;
  } catch {
    return '';
  }
}

function textOf(value: string | undefined): string {
  return decodeEntities((value ?? '').replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
}

function decodeEntities(value: string): string {
  return value
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}
