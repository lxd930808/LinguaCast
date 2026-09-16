import type { SkillRecord } from '../skills/registry.js';
import type { TurnMode } from './state.js';

export const RESEARCH_SKILLS = [
  'topic-research',
  'web-research',
  'podcast-search',
  'youtube-search',
  'transcribe-source',
  'evidence-synthesis',
  'report-writing'
] as const;

export const CONTENT_QA_SKILLS = ['evidence-synthesis', 'report-writing'] as const;

export function skillsForMode(registry: SkillRecord[], mode: TurnMode): SkillRecord[] {
  const names = mode === 'content_qa' ? CONTENT_QA_SKILLS : RESEARCH_SKILLS;
  return names
    .map((name) => registry.find((skill) => skill.name === name))
    .filter((skill): skill is SkillRecord => Boolean(skill));
}

export function primarySkill(skills: SkillRecord[], mode: TurnMode): SkillRecord | null {
  const name = mode === 'content_qa' ? 'evidence-synthesis' : 'topic-research';
  return skills.find((skill) => skill.name === name) ?? skills[0] ?? null;
}

export function composeV2SystemPrompt(skills: SkillRecord[], mode: TurnMode): string {
  const lines = [
    '# V2 workspace research assistant',
    '',
    `Turn mode: ${mode}.`,
    'You are a content research assistant for a podcast & YouTube English-study app. Your primary value is discovering relevant YouTube videos and Apple Podcasts / podcast episodes for the user, not summarizing the open web.',
    'Use only the provided V2 tools. Never call bash, read, write, edit, grep, find, ls, web, or powershell.',
    'File access uses list_files/read_file/write_file/search_files/grep_files with research:// or granted shared:// URIs.',
    'Do not invent confirmation tokens. request_transcription requires a user-issued token from the turn context.',
    'Factual paragraphs need locatable artifact citations. If evidence is missing, state the gap instead of asserting.',
    'Each save_research_report call creates a new report artifact; never overwrite an older report.'
  ];
  if (mode === 'research') {
    lines.push('', ...composeSourceSelectionGuidance());
  }
  lines.push('', '## Skills');
  for (const skill of skills) {
    lines.push(
      `- ${skill.name}@${skill.version} sha256=${skill.sha256}`,
      `  ${skill.description}`,
      `  trigger: ${skill.trigger}`,
      `  allowedTools: ${skill.allowedTools.join(', ')}`
    );
  }
  return lines.join('\n');
}

/**
 * Source-selection guidance for research turns. Without this, the agent sees web_search,
 * search_youtube and search_podcasts as three peer tools and tends to only search the web.
 * This app is about YouTube/podcast content, so media sources are the default, not the web.
 * Adapted from prompts/systemprompt.txt (the V1 source-selection rules).
 */
function composeSourceSelectionGuidance(): string[] {
  return [
    '## Source selection (research turns)',
    'For any topic/discovery question, search the media sources first and treat them as the point of the turn:',
    '- search_youtube — tutorials, talks, demos, keynotes, interviews, courses, product/tech walkthroughs, or when the user asks for videos.',
    '- search_podcasts — long-form interviews, deep discussions, shows, person-to-person conversations, or when the user asks for podcasts.',
    'When the user names a topic rather than a specific medium, and both platforms plausibly have high-value content, search BOTH YouTube and podcasts. Do not ask the user to pick a platform first.',
    'Unless the user explicitly restricts the medium (e.g. "只找播客" / "only videos"), a normal research turn should call search_youtube AND search_podcasts before writing the report. Skip a media source only when the user restricted it or the topic is clearly unrelated to any video/audio content.',
    'Use web_search only as a supplement — to disambiguate an entity, confirm a fact, or fill a gap the media sources could not — never as the sole source for a discovery request.',
    'Turn Chinese topics about international/technical subjects into English search queries, but keep person names, show names and channel handles in their original form. Use 1–3 high-quality queries per platform; do not loop endlessly.',
    'If a platform search fails or returns nothing, continue with the other source and say which one came up empty. Never fabricate results.'
  ];
}
