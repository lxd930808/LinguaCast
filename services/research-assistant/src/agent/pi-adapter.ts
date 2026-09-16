import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

import { Agent, type AgentMessage, type AgentTool } from '@earendil-works/pi-agent-core';
import { Type, type Api, type Model, type MutableModels } from '@earendil-works/pi-ai';
import { builtinModels } from '@earendil-works/pi-ai/providers/all';

import type { ServiceConfig } from '../config/index.js';
import { DomainError, describeUnknownError } from '../domain/types.js';
import { JsonFileCredentialStore } from './pi-credentials.js';
import { isV2PiToolName, V2_PARAMETER_SCHEMAS, V2_TOOL_DESCRIPTIONS } from './v2/pi-schemas.js';
import {
  FORBIDDEN_DEFAULT_TOOLS,
  QA_TOOLS,
  RESEARCH_TOOLS_V2,
  assertToolWhitelist,
  researchToolsFor,
  type AgentEvent,
  type AgentRuntime,
  type ConversationMessage,
  type ToolCall,
  type ToolName
} from './runtime.js';

interface PiModelsFile {
  models?: Array<{ alias?: string; provider?: string; model?: string }>;
  fallback?: string[];
  thinkingLevel?: 'off' | 'minimal' | 'low' | 'medium' | 'high' | 'xhigh' | 'max';
}

const QUERY = Type.Object(
  {
    query: Type.String({ minLength: 1, maxLength: 200 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 10 }))
  },
  { additionalProperties: false }
);

const SEARCH_RESULT = Type.Object(
  {
    searchResultId: Type.String({ minLength: 8, maxLength: 40 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 10 }))
  },
  { additionalProperties: false }
);

const SEARCH_RUN = Type.Object(
  { searchRunId: Type.Optional(Type.String({ maxLength: 40 })) },
  { additionalProperties: false }
);

const QUERY_V2 = Type.Object(
  {
    query: Type.String({ minLength: 1, maxLength: 200 }),
    queries: Type.Optional(Type.Array(Type.String({ minLength: 1, maxLength: 200 }), { maxItems: 3 })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 10 })),
    intent: Type.Optional(Type.String({ maxLength: 20 })),
    person: Type.Optional(Type.String({ maxLength: 200 })),
    showOrChannel: Type.Optional(Type.String({ maxLength: 200 })),
    language: Type.Optional(Type.String({ maxLength: 16 })),
    region: Type.Optional(Type.String({ maxLength: 2 })),
    publishedAfter: Type.Optional(Type.String({ maxLength: 40 })),
    duration: Type.Optional(Type.String({ maxLength: 16 })),
    clean: Type.Optional(Type.Boolean())
  },
  { additionalProperties: false }
);

const SEARCH_PODCASTS = Type.Object(
  {
    query: Type.String({ minLength: 1, maxLength: 200 }),
    mode: Type.Optional(Type.String({ maxLength: 16 })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 10 })),
    person: Type.Optional(Type.String({ maxLength: 200 })),
    language: Type.Optional(Type.String({ maxLength: 16 })),
    region: Type.Optional(Type.String({ maxLength: 2 })),
    publishedAfter: Type.Optional(Type.String({ maxLength: 40 }))
  },
  { additionalProperties: false }
);

const SEARCH_RUN_REQUIRED = Type.Object(
  { searchRunId: Type.String({ minLength: 8, maxLength: 40 }) },
  { additionalProperties: false }
);

const VIDEO_DETAILS = Type.Object(
  {
    searchResultIds: Type.Array(Type.String({ minLength: 8, maxLength: 40 }), { minItems: 1, maxItems: 10 })
  },
  { additionalProperties: false }
);

const SAVE_REPORT = Type.Object(
  {
    title: Type.String({ minLength: 1, maxLength: 80 }),
    summary: Type.String({ minLength: 1, maxLength: 8000 }),
    sourceIds: Type.Array(Type.String({ minLength: 8, maxLength: 40 }), { maxItems: 20 }),
    markdown: Type.Optional(Type.String({ maxLength: 8000 })),
    searchRunId: Type.Optional(Type.String({ maxLength: 40 }))
  },
  { additionalProperties: false }
);

const SESSION_ID = Type.Object(
  { sessionId: Type.Optional(Type.String({ maxLength: 40 })) },
  { additionalProperties: false }
);

const BINDING_ID = Type.Object(
  { bindingId: Type.Optional(Type.String({ maxLength: 40 })) },
  { additionalProperties: false }
);

const TRANSCRIPT_SEARCH = Type.Object(
  {
    query: Type.String({ minLength: 1, maxLength: 200 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 8 }))
  },
  { additionalProperties: false }
);

const EVIDENCE = Type.Object(
  { chunkIds: Type.Array(Type.String({ minLength: 1, maxLength: 64 }), { maxItems: 8 }) },
  { additionalProperties: false }
);

const SAVE_ANSWER = Type.Object(
  {
    message: Type.String({ minLength: 1, maxLength: 8000 }),
    citations: Type.Array(Type.Object({}, { additionalProperties: true }), { maxItems: 16 }),
    query: Type.Optional(Type.String({ maxLength: 200 }))
  },
  { additionalProperties: false }
);

const PARAMETER_SCHEMAS: Record<ToolName, ReturnType<typeof Type.Object>> = {
  search_youtube: QUERY_V2,
  search_apple_podcasts: QUERY,
  get_podcast_feed_episodes: SEARCH_RESULT,
  read_search_results: SEARCH_RUN,
  save_research_report: SAVE_REPORT,
  get_youtube_video_details: VIDEO_DETAILS,
  search_podcasts: SEARCH_PODCASTS,
  get_podcast_episodes: SEARCH_RESULT,
  read_search_run: SEARCH_RUN_REQUIRED,
  get_selected_source: SESSION_ID,
  get_content_preparation_status: BINDING_ID,
  search_current_transcript: TRANSCRIPT_SEARCH,
  read_transcript_evidence: EVIDENCE,
  save_grounded_answer: SAVE_ANSWER
};

const DESCRIPTIONS: Record<ToolName, string> = {
  search_youtube: 'Search YouTube. Returns this run\'s structured top candidates. Keep person/show names verbatim.',
  search_apple_podcasts: 'Legacy Apple Podcasts show search alias.',
  get_podcast_feed_episodes: 'Legacy RSS episode list alias.',
  read_search_results: 'Legacy session-wide search result reader.',
  save_research_report: 'Save a metadata-only research report. sourceIds must include every search result actually cited in the report body (max 20).',
  get_youtube_video_details: 'Hydrate details for up to 10 persisted YouTube searchResultIds in this session.',
  search_podcasts: 'Search podcasts (person/term/title/recent). Returns this run\'s structured candidates.',
  get_podcast_episodes: 'List episodes for a persisted podcast show searchResultId.',
  read_search_run: 'Read ranked results for one searchRunId in this session.',
  get_selected_source: 'Read the currently bound source for this session.',
  get_content_preparation_status: 'Read V10 preparation progress for the current binding.',
  search_current_transcript: 'Search the current single-episode transcript index.',
  read_transcript_evidence: 'Read evidence chunks by id from the current transcript.',
  save_grounded_answer: 'Save an answer that cites current-transcript evidence only.'
};

export function registeredPiToolNames(searchV2 = false): string[] {
  return [...researchToolsFor(searchV2), ...QA_TOOLS];
}

export function assertNoDefaultCodingTools(names: readonly string[]): void {
  for (const forbidden of FORBIDDEN_DEFAULT_TOOLS) {
    if (names.includes(forbidden)) {
      throw new Error(`forbidden default tool registered: ${forbidden}`);
    }
  }
}

export function loadPiModelCatalog(piConfigDir: string): PiModelsFile {
  const modelsPath = join(piConfigDir, 'models.json');
  if (existsSync(modelsPath)) {
    return JSON.parse(readFileSync(modelsPath, 'utf8')) as PiModelsFile;
  }
  const settingsPath = join(piConfigDir, 'settings.json');
  if (existsSync(settingsPath)) {
    const settings = JSON.parse(readFileSync(settingsPath, 'utf8')) as {
      defaultProvider?: string;
      defaultModel?: string;
      defaultThinkingLevel?: PiModelsFile['thinkingLevel'];
    };
    if (settings.defaultProvider && settings.defaultModel) {
      return {
        models: [{ alias: 'primary', provider: settings.defaultProvider, model: settings.defaultModel }],
        thinkingLevel: settings.defaultThinkingLevel
      };
    }
  }
  throw new DomainError('MODEL_PROVIDER_UNAVAILABLE', 'Pi models.json or settings.json is missing', true, 503);
}

export function createPiModels(authPath?: string): MutableModels {
  if (!authPath) return builtinModels();
  return builtinModels({ credentials: new JsonFileCredentialStore(authPath) });
}

export function resolvePiModel(
  catalog: PiModelsFile,
  models: MutableModels = createPiModels()
): { alias: string; provider: string; modelId: string; model: Model<Api> } {
  const entry = catalog.models?.[0];
  if (!entry?.provider || !entry.model) {
    throw new DomainError('MODEL_PROVIDER_UNAVAILABLE', 'Pi models.json has no usable model', true, 503);
  }
  const model = models.getModel(entry.provider, entry.model);
  if (!model) {
    throw new DomainError('MODEL_PROVIDER_UNAVAILABLE', 'Pi model is not in the provider catalog', true, 503, {
      alias: entry.alias ?? 'primary',
      provider: entry.provider
    });
  }
  return { alias: entry.alias ?? 'primary', provider: entry.provider, modelId: entry.model, model };
}

export function resolvePiRunTools(input: {
  kind: 'research' | 'qa';
  tools?: readonly string[];
  searchV2: boolean;
}): string[] {
  const requested = (input.tools ?? []).map((name) => name.trim()).filter(Boolean);
  const fallback = input.kind === 'research' ? researchToolsFor(input.searchV2) : QA_TOOLS;
  const allowed = requested.length > 0 ? requested : [...fallback];
  assertNoDefaultCodingTools(allowed);
  const unknown = allowed.filter((name) => !isPiToolName(name));
  if (unknown.length) {
    throw new Error(`pi adapter registered extra tools: ${unknown.join(',')}`);
  }
  return allowed;
}

function isPiToolName(name: string): boolean {
  return name in PARAMETER_SCHEMAS || isV2PiToolName(name);
}

function usesV2ToolSet(names: readonly string[]): boolean {
  return names.some((name) => isV2PiToolName(name) && !(name in PARAMETER_SCHEMAS));
}

function schemaFor(name: string, v2: boolean): ReturnType<typeof Type.Object> {
  if (v2 && isV2PiToolName(name)) return V2_PARAMETER_SCHEMAS[name];
  return PARAMETER_SCHEMAS[name as ToolName];
}

function descriptionFor(name: string, v2: boolean): string {
  if (v2 && isV2PiToolName(name)) return V2_TOOL_DESCRIPTIONS[name];
  return DESCRIPTIONS[name as ToolName];
}

function buildTools(
  names: readonly string[],
  executeTool: (call: ToolCall) => Promise<unknown>
): AgentTool[] {
  const v2 = usesV2ToolSet(names);
  return names.map((name) => ({
    name,
    label: name,
    description: descriptionFor(name, v2),
    parameters: schemaFor(name, v2),
    executionMode: 'sequential' as const,
    execute: async (toolCallId, params) => {
      const result = await executeTool({
        name,
        args: { ...(params as Record<string, unknown>), callId: toolCallId }
      });
      const text = JSON.stringify(result).slice(0, 8000);
      return {
        content: [{ type: 'text' as const, text }],
        details: result
      };
    }
  }));
}

/**
 * Production AgentRuntime. Pi types stay inside this module.
 * Tests continue to inject FakeAgentRuntime.
 */
export class PiAgentRuntime implements AgentRuntime {
  constructor(private readonly config: ServiceConfig) {
    const names = registeredPiToolNames(config.searchV2);
    if (config.searchV2) {
      assertNoDefaultCodingTools(names);
      const extra = names.filter((name) => ![...RESEARCH_TOOLS_V2, ...QA_TOOLS].includes(name as never));
      if (extra.length) throw new Error(`pi adapter registered extra tools: ${extra.join(',')}`);
    } else {
      assertToolWhitelist(names);
      assertNoDefaultCodingTools(names);
    }
  }

  async *run(input: Parameters<AgentRuntime['run']>[0]): AsyncIterable<AgentEvent> {
    const allowed = resolvePiRunTools({
      kind: input.kind,
      tools: input.tools,
      searchV2: this.config.searchV2
    });
    const tools = buildTools(allowed, input.executeTool);
    const extra = tools.map((tool) => tool.name).filter((name) => !allowed.includes(name));
    if (extra.length) {
      throw new Error(`pi adapter registered extra tools: ${extra.join(',')}`);
    }

    const catalog = loadPiModelCatalog(this.config.piConfigDir);
    const models = createPiModels(this.config.piAuthPath);
    const resolved = resolvePiModel(catalog, models);
    const queue: AgentEvent[] = [];
    let notify: (() => void) | null = null;
    let ended = false;
    let sawTextDelta = false;
    const thinkingStartedAt = new Map<number, number>();
    const redactedThinkingBlocks = new Set<number>();

    const agent = new Agent({
      initialState: {
        systemPrompt: input.systemPrompt,
        model: resolved.model,
        thinkingLevel: catalog.thinkingLevel ?? 'medium',
        tools,
        messages: toPiHistoryMessages(input.history ?? [])
      },
      streamFn: models.streamSimple.bind(models),
      convertToLlm: (messages) =>
        messages.filter(
          (message) =>
            message &&
            typeof message === 'object' &&
            'role' in message &&
            (message.role === 'user' || message.role === 'assistant' || message.role === 'toolResult')
        ),
      beforeToolCall: async ({ toolCall }) => {
        if (FORBIDDEN_DEFAULT_TOOLS.includes(toolCall.name) || !allowed.includes(toolCall.name)) {
          return { block: true, reason: 'tool is not in the business whitelist', terminate: true };
        }
        return undefined;
      },
      toolExecution: 'sequential'
    });

    agent.subscribe((event) => {
      if (event.type === 'message_update') {
        const update = event.assistantMessageEvent;
        if (update.type === 'text_delta') {
          sawTextDelta = true;
          queue.push({ type: 'text_delta', text: update.delta });
        } else if (update.type === 'thinking_start') {
          thinkingStartedAt.set(update.contentIndex, Date.now());
          queue.push(mapPiThinkingUpdate({ type: 'thinking_start', contentIndex: update.contentIndex }));
        } else if (update.type === 'thinking_delta') {
          if (!redactedThinkingBlocks.has(update.contentIndex)) {
            const mapped = mapPiThinkingUpdate({
              type: 'thinking_delta',
              contentIndex: update.contentIndex,
              delta: update.delta,
              partial: update.partial as PiPartialLike | undefined
            });
            if (mapped.thinking?.stage === 'redacted') {
              redactedThinkingBlocks.add(update.contentIndex);
            }
            queue.push(mapped);
          }
        } else if (update.type === 'thinking_end') {
          queue.push(
            mapPiThinkingUpdate(
              {
                type: 'thinking_end',
                contentIndex: update.contentIndex
              },
              thinkingStartedAt.get(update.contentIndex),
              redactedThinkingBlocks.has(update.contentIndex)
            )
          );
        }
      } else if (event.type === 'message_end') {
        const mapped = mapPiAssistantMessageEnd(event.message);
        if (mapped) {
          queue.push(mapped);
        } else if (!sawTextDelta && event.message.role === 'assistant') {
          const text = extractPiAssistantText(event.message);
          if (text) queue.push({ type: 'text_delta', text });
        }
      } else if (event.type === 'tool_execution_start') {
        queue.push({
          type: 'tool_call',
          tool: event.toolName,
          callId: event.toolCallId,
          args: event.args as Record<string, unknown>
        });
      } else if (event.type === 'tool_execution_end') {
        queue.push(mapPiToolExecutionEnd(event));
      } else if (event.type === 'agent_end') {
        queue.push({ type: 'done' });
        ended = true;
      }
      notify?.();
    });

    const prompt = agent.prompt(input.userText).catch((error: unknown) => {
      queue.push({
        type: 'error',
        error: error instanceof Error ? error.message : String(error)
      });
      ended = true;
      notify?.();
    });

    const onAbort = () => agent.abort();
    if (input.signal.aborted) agent.abort();
    else input.signal.addEventListener('abort', onAbort, { once: true });

    try {
      while (!ended || queue.length > 0) {
        if (queue.length === 0) {
          await new Promise<void>((resolve) => {
            notify = resolve;
          });
          notify = null;
        }
        const next = queue.shift();
        if (next) yield next;
      }
      await prompt;
    } finally {
      input.signal.removeEventListener('abort', onAbort);
      if (!ended) {
        agent.abort();
      }
    }
  }
}

type PiAssistantLike = {
  role?: string;
  stopReason?: string;
  errorMessage?: string;
  content?: string | Array<{ type?: string; text?: string; thinking?: string; redacted?: boolean }>;
};

type PiPartialLike = PiAssistantLike;

/** Structural shape of the pi-ai thinking_* message updates the adapter subscribes to. */
export type PiThinkingUpdate =
  | { type: 'thinking_start'; contentIndex: number }
  | { type: 'thinking_delta'; contentIndex: number; delta: string; partial?: PiPartialLike }
  | { type: 'thinking_end'; contentIndex: number };

export function piThinkingBlockId(contentIndex: number): string {
  return `th_${contentIndex}`;
}

export function isRedactedPiThinking(update: {
  contentIndex: number;
  delta: string;
  partial?: PiPartialLike;
}): boolean {
  if (update.delta.trim() === '[Reasoning redacted]') return true;
  const content = update.partial?.content;
  if (!Array.isArray(content)) return false;
  const block = content[update.contentIndex];
  return Boolean(block && typeof block === 'object' && block.redacted === true);
}

/** Map a pi thinking_* update to an AgentEvent. Redacted blocks never carry text. */
export function mapPiThinkingUpdate(
  update: PiThinkingUpdate,
  startedAt?: number,
  redactedBlock = false,
  now: () => number = Date.now
): AgentEvent {
  const blockId = piThinkingBlockId(update.contentIndex);
  switch (update.type) {
    case 'thinking_start':
      return { type: 'thinking', thinking: { stage: 'start', blockId } };
    case 'thinking_delta':
      if (isRedactedPiThinking(update)) {
        return { type: 'thinking', thinking: { stage: 'redacted', blockId, redacted: true } };
      }
      return { type: 'thinking', thinking: { stage: 'delta', blockId, text: update.delta } };
    case 'thinking_end':
      return {
        type: 'thinking',
        thinking: {
          stage: 'end',
          blockId,
          durationMs: startedAt == null ? undefined : Math.max(0, now() - startedAt),
          ...(redactedBlock ? { redacted: true } : {})
        }
      };
  }
}

/** Map a finished assistant message. Errors must not look like an empty search. */
export function mapPiAssistantMessageEnd(message: PiAssistantLike): AgentEvent | null {
  if (message.role !== 'assistant') return null;
  if (message.stopReason !== 'error' && message.stopReason !== 'aborted') return null;
  const detail = message.errorMessage?.trim();
  return {
    type: 'error',
    error: detail && detail.length > 0 ? detail : `assistant stopReason=${message.stopReason}`
  };
}

export function extractPiAssistantText(message: PiAssistantLike): string {
  if (typeof message.content === 'string') return message.content;
  if (!Array.isArray(message.content)) return '';
  return message.content
    .filter((part) => part.type === 'text' && typeof part.text === 'string' && part.text.length > 0)
    .map((part) => part.text as string)
    .join('');
}

export function mapPiToolExecutionEnd(event: {
  toolName: string;
  toolCallId: string;
  isError: boolean;
  result: unknown;
}): AgentEvent {
  return {
    type: 'tool_result',
    tool: event.toolName,
    callId: event.toolCallId,
    result: event.result,
    error: event.isError ? describeUnknownError(event.result) : undefined
  };
}

export function toPiHistoryMessages(history: ConversationMessage[]): AgentMessage[] {
  return history
    .filter((message) => message.markdown.trim())
    .map((message) => {
      const timestamp = Date.parse(message.createdAt) || Date.now();
      if (message.role === 'user') {
        return { role: 'user' as const, content: message.markdown, timestamp };
      }
      return {
        role: 'assistant' as const,
        content: [{ type: 'text' as const, text: message.markdown }],
        api: 'openai-completions',
        provider: 'session-history',
        model: 'session-history',
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
        },
        stopReason: 'stop' as const,
        timestamp
      };
    });
}
