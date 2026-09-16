// Prompt policy (WP6): exact port of Swift TranslationPromptPolicy. The
// strings are wire-relevant — golden tests pin them so server and client
// produce identical prompts for the same inputs.

export type TranslationQualityMode = 'fast' | 'quality';

/** promptName per target locale (Swift TranslationTarget.promptName). */
const TARGET_PROMPT_NAMES: Record<string, string> = {
  'zh-Hans': 'Simplified Chinese',
  'zh-Hant': 'Traditional Chinese',
  es: 'Spanish',
  'pt-BR': 'Brazilian Portuguese',
  ja: 'Japanese',
  ko: 'Korean',
  fr: 'French',
  de: 'German',
  ar: 'Arabic'
};

export interface TranslationTerm {
  source: string;
  target: string;
  note: string;
}

export interface TranslationContext {
  topicSummary: string;
  terms: TranslationTerm[];
}

export const EMPTY_CONTEXT: TranslationContext = { topicSummary: '', terms: [] };

export function promptNameForTarget(target: string): string {
  return TARGET_PROMPT_NAMES[target] ?? target;
}

function termsBlock(terms: TranslationTerm[]): string {
  if (terms.length === 0) return '';
  const lines = terms.map(
    (term) => `- ${term.source} → ${term.target}${term.note.length === 0 ? '' : ` (${term.note})`}`
  );
  return `\n\nGlossary terms to honour:\n${lines.join('\n')}`;
}

/** Numbered-JSON batch translation prompt (reflective or direct). */
export function batchSystemPrompt(input: {
  target: string;
  topicSummary: string;
  terms: TranslationTerm[];
  contextBefore: string[];
  contextAfter: string[];
  qualityMode: TranslationQualityMode;
}): string {
  const name = promptNameForTarget(input.target);
  const beforeBlock =
    input.contextBefore.length === 0
      ? ''
      : `\n\nPrevious lines (context only, do not translate):\n${input.contextBefore.join('\n')}`;
  const afterBlock =
    input.contextAfter.length === 0
      ? ''
      : `\n\nFollowing lines (context only, do not translate):\n${input.contextAfter.join('\n')}`;
  const formatInstructions =
    input.qualityMode === 'quality'
      ? `Return strict JSON only, an object keyed by each line's number:
{"1":{"origin":"<exact source line>","direct":"<literal ${name}>","reflection":"<one short improvement note>","final":"<natural ${name}>"}}
Include every provided number exactly once. \`origin\` must match the source line character-for-character.`
      : `Return strict JSON only, an object keyed by each line's number:
{"1":{"origin":"<exact source line>","direct":"<literal ${name}>"}}
Include every provided number exactly once. \`origin\` must match the source line character-for-character.`;
  return `You are translating English podcast transcript lines into concise ${name} for language learning.
Use the writing system implied by the target locale ${input.target}. Do not add explanations.
${formatInstructions}

Topic summary:
${input.topicSummary.length === 0 ? '(none)' : input.topicSummary}${termsBlock(input.terms)}${beforeBlock}${afterBlock}`;
}

/** Single-line reflective translation used for per-line retry. */
export function singleSystemPrompt(input: {
  target: string;
  topicSummary: string;
  terms: TranslationTerm[];
  qualityMode: TranslationQualityMode;
}): string {
  const name = promptNameForTarget(input.target);
  const formatInstructions =
    input.qualityMode === 'quality'
      ? `Return strict JSON only: {"origin":"<exact source line>","direct":"<literal ${name}>","reflection":"<one short improvement note>","final":"<natural ${name}>"}.
\`origin\` must match the source line character-for-character.`
      : `Return strict JSON only: {"origin":"<exact source line>","direct":"<literal ${name}>"}.
\`origin\` must match the source line character-for-character.`;
  return `You are translating one English podcast transcript line into concise ${name} for language learning.
Use the writing system implied by the target locale ${input.target}. Do not add explanations.
The user input is a JSON object with \`id\` and \`text\`. Translate only the decoded \`text\` value; \`id\` is metadata, never part of the source or translation. Copy \`text\` exactly into \`origin\`, including any numbering that is already inside \`text\`.
${formatInstructions}

Topic summary:
${input.topicSummary.length === 0 ? '(none)' : input.topicSummary}${termsBlock(input.terms)}`;
}

/** Topic summary + glossary extraction for one transcript excerpt. */
export function contextExtractionSystemPrompt(target: string): string {
  const name = promptNameForTarget(target);
  return `You analyze an English podcast transcript excerpt and return strict JSON only:
{"summary":"<two short sentences describing the topic>","terms":[{"source":"<English term>","target":"<${name} rendering>","note":"<optional disambiguation>"}]}
Include at most 15 terms, only proper nouns / domain terms worth consistent translation.`;
}

/** Split a translation into the same number of parts as the source split. */
export function alignedTranslationSplitSystemPrompt(target: string, partCount: number): string {
  const name = promptNameForTarget(target);
  return `You split a ${name} translation into exactly ${partCount} consecutive parts matching a source split.
Return strict JSON only: {"parts":["part1","part2",...]} with exactly ${partCount} non-empty strings in order.
Do not translate again; only split the provided translation. Use the writing system implied by ${target}.`;
}
