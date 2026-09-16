export const RESEARCH_TOOLS = [
  'search_youtube',
  'search_apple_podcasts',
  'get_podcast_feed_episodes',
  'read_search_results',
  'save_research_report'
] as const;

export const RESEARCH_TOOLS_V2 = [
  'search_youtube',
  'get_youtube_video_details',
  'search_podcasts',
  'get_podcast_episodes',
  'read_search_run',
  'save_research_report'
] as const;

export const LEGACY_SEARCH_ALIASES = [
  'search_apple_podcasts',
  'get_podcast_feed_episodes',
  'read_search_results'
] as const;

export const QA_TOOLS = [
  'get_selected_source',
  'get_content_preparation_status',
  'search_current_transcript',
  'read_transcript_evidence',
  'save_grounded_answer'
] as const;

export const ALL_BUSINESS_TOOLS = [...RESEARCH_TOOLS, ...QA_TOOLS] as const;

export const ALL_KNOWN_TOOLS = [
  ...new Set([...RESEARCH_TOOLS, ...RESEARCH_TOOLS_V2, ...QA_TOOLS, ...LEGACY_SEARCH_ALIASES])
] as const;

export type ToolName = (typeof ALL_KNOWN_TOOLS)[number];

export function researchToolsFor(searchV2: boolean): readonly string[] {
  return searchV2 ? RESEARCH_TOOLS_V2 : RESEARCH_TOOLS;
}

export const FORBIDDEN_DEFAULT_TOOLS = [
  'bash',
  'read',
  'write',
  'edit',
  'grep',
  'find',
  'ls',
  'web',
  'powershell'
];

export interface ToolCall {
  name: ToolName | string;
  args: Record<string, unknown>;
}

/** One reasoning block streamed by the model. `stage: 'redacted'` carries no text. */
export interface AgentThinking {
  stage: 'start' | 'delta' | 'end' | 'redacted';
  blockId: string;
  text?: string;
  durationMs?: number;
  redacted?: boolean;
}

export interface AgentEvent {
  type: 'text_delta' | 'thinking' | 'tool_call' | 'tool_result' | 'done' | 'error';
  text?: string;
  thinking?: AgentThinking;
  tool?: string;
  callId?: string;
  args?: Record<string, unknown>;
  result?: unknown;
  error?: string;
}

export interface ConversationMessage {
  role: 'user' | 'assistant';
  markdown: string;
  createdAt: string;
}

export interface AgentRuntime {
  run(input: {
    kind: 'research' | 'qa';
    systemPrompt: string;
    userText: string;
    history?: ConversationMessage[];
    tools: readonly string[];
    signal: AbortSignal;
    executeTool: (call: ToolCall) => Promise<unknown>;
  }): AsyncIterable<AgentEvent>;
}

/** Recoverable tool failures surface as `{ ok: false, ... }` results, not thrown errors. */
export function isToolResultFailure(result: unknown): boolean {
  return (
    typeof result === 'object' &&
    result !== null &&
    (result as { ok?: unknown }).ok === false
  );
}

export async function* scriptedRuntime(
  events: AgentEvent[],
  executeTool: (call: ToolCall) => Promise<unknown>
): AsyncIterable<AgentEvent> {
  for (const event of events) {
    if (event.type === 'tool_call') {
      yield event;
      const result = await executeTool({ name: event.tool ?? '', args: event.args ?? {} });
      yield { type: 'tool_result', tool: event.tool, callId: event.callId, result };
    } else {
      yield event;
    }
  }
}

export class FakeAgentRuntime implements AgentRuntime {
  constructor(private readonly script: AgentEvent[] = [{ type: 'done' }]) {}

  async *run(input: Parameters<AgentRuntime['run']>[0]): AsyncIterable<AgentEvent> {
    yield* scriptedRuntime(this.script, input.executeTool);
  }
}

export function assertToolWhitelist(tools: readonly string[]): void {
  const extra = tools.filter((name) => !ALL_BUSINESS_TOOLS.includes(name as (typeof ALL_BUSINESS_TOOLS)[number]));
  const missing = ALL_BUSINESS_TOOLS.filter((name) => !tools.includes(name));
  if (extra.length || missing.length) {
    throw new Error(`tool whitelist mismatch extra=${extra.join(',')} missing=${missing.join(',')}`);
  }
  for (const forbidden of FORBIDDEN_DEFAULT_TOOLS) {
    if (tools.includes(forbidden)) {
      throw new Error(`forbidden default tool registered: ${forbidden}`);
    }
  }
}
