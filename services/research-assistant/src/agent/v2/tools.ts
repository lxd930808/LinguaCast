export const V2_FILE_TOOLS = [
  'list_files',
  'read_file',
  'write_file',
  'search_files',
  'grep_files',
  'get_artifact',
  'save_artifact'
] as const;

export const V2_WEB_TOOLS = ['web_search', 'fetch_web_page'] as const;

export const V2_SEARCH_TOOLS = [
  'search_youtube',
  'get_youtube_video_details',
  'search_podcasts',
  'get_podcast_episodes',
  'read_search_run'
] as const;

export const V2_MEMORY_TOOLS = ['write_research_memory', 'propose_global_memory'] as const;

export const V2_EVIDENCE_TOOLS = ['retrieve_evidence'] as const;

export const V2_TRANSCRIPT_TOOLS = ['request_transcription', 'get_transcript_job', 'get_selected_source'] as const;

export const V2_REPORT_TOOLS = ['save_research_report'] as const;

export const V2_ALL_TOOLS = [
  ...V2_FILE_TOOLS,
  ...V2_WEB_TOOLS,
  ...V2_SEARCH_TOOLS,
  ...V2_MEMORY_TOOLS,
  ...V2_EVIDENCE_TOOLS,
  ...V2_TRANSCRIPT_TOOLS,
  ...V2_REPORT_TOOLS
] as const;

export type V2ToolName = (typeof V2_ALL_TOOLS)[number];
export type V2TurnKind = 'research' | 'content_qa';
export type V2ResearchPhase = 'planning' | 'gathering' | 'synthesizing' | 'reporting';

const RESEARCH_PHASES: V2ResearchPhase[] = ['planning', 'gathering', 'synthesizing', 'reporting'];

/** Union of every phase the model may need during a turn. Phase enforcement stays in the dispatcher. */
export function toolsVisibleToAgent(kind: V2TurnKind): readonly V2ToolName[] {
  if (kind === 'content_qa') return toolsForTurn('content_qa');
  const seen = new Set<V2ToolName>();
  const out: V2ToolName[] = [];
  for (const phase of RESEARCH_PHASES) {
    for (const tool of toolsForTurn('research', phase)) {
      if (seen.has(tool)) continue;
      seen.add(tool);
      out.push(tool);
    }
  }
  return out;
}

export function toolsForTurn(kind: V2TurnKind, phase: V2ResearchPhase = 'gathering'): readonly V2ToolName[] {
  if (kind === 'content_qa') {
    return [
      'get_artifact',
      'retrieve_evidence',
      'get_transcript_job',
      'get_selected_source',
      'grep_files',
      'search_files',
      'list_files',
      'read_file',
      'save_research_report',
      'write_research_memory'
    ];
  }
  switch (phase) {
    case 'planning':
      return ['list_files', 'read_file', 'search_files', 'grep_files', 'get_artifact', 'save_artifact', ...V2_SEARCH_TOOLS, 'web_search'];
    case 'gathering':
      return [
        ...V2_FILE_TOOLS,
        ...V2_WEB_TOOLS,
        ...V2_SEARCH_TOOLS,
        ...V2_TRANSCRIPT_TOOLS,
        ...V2_MEMORY_TOOLS,
        'retrieve_evidence'
      ];
    case 'synthesizing':
      return ['retrieve_evidence', 'get_artifact', 'grep_files', 'search_files', 'list_files', 'read_file'];
    case 'reporting':
      return ['retrieve_evidence', 'get_artifact', 'save_artifact', 'save_research_report', ...V2_MEMORY_TOOLS];
    default:
      return [];
  }
}
