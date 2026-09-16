import type { V2EventRecord, V2TurnRecord } from '../../db/v2/store.js';

/** Folded thinking block projected into snapshot.turnWork. */
export interface TurnWorkThinking {
  status: 'streaming' | 'done' | 'redacted';
  durationMs: number | null;
  text: string;
  truncated: boolean;
  redacted: boolean;
}

/** Folded tool row projected into snapshot.turnWork. `labelKey` is the stable tool name. */
export interface TurnWorkTool {
  callId: string;
  tool: string;
  labelKey: string;
  status: 'running' | 'completed' | 'failed';
  query?: string;
}

export interface TurnWork {
  turnId: string;
  durationMs: number | null;
  thinking: TurnWorkThinking | null;
  tools: TurnWorkTool[];
}

const THINKING_TEXT_MAX = 4096;

interface TurnWorkFold {
  turnId: string;
  thinking: TurnWorkThinking | null;
  tools: Map<string, TurnWorkTool>;
}

function payloadOf(event: V2EventRecord): Record<string, unknown> {
  return event.payload && typeof event.payload === 'object' && !Array.isArray(event.payload)
    ? (event.payload as Record<string, unknown>)
    : {};
}

function appendString(current: string, chunk: string): { text: string; truncated: boolean } {
  if (current.length >= THINKING_TEXT_MAX) return { text: current, truncated: true };
  const combined = current + chunk;
  if (combined.length <= THINKING_TEXT_MAX) return { text: combined, truncated: false };
  return { text: combined.slice(0, THINKING_TEXT_MAX), truncated: true };
}

function turnDurationMs(turn: V2TurnRecord | undefined): number | null {
  if (!turn?.startedAt || !turn.finishedAt) return null;
  const duration = Date.parse(turn.finishedAt) - Date.parse(turn.startedAt);
  return Number.isFinite(duration) && duration >= 0 ? duration : null;
}

/**
 * Project per-turn work cards (thinking + tool rows) from durable v2_events.
 * Turns without thinking or tool events are omitted. Thinking text is folded
 * from `thinking.delta` payloads and truncated; the placeholder sentence for
 * redacted reasoning is never stored as text.
 */
export function projectTurnWork(events: V2EventRecord[], turns: V2TurnRecord[]): TurnWork[] {
  const turnsById = new Map(turns.map((turn) => [turn.turnId, turn]));
  const folds = new Map<string, TurnWorkFold>();

  const foldFor = (turnId: string): TurnWorkFold => {
    const existing = folds.get(turnId);
    if (existing) return existing;
    const created: TurnWorkFold = { turnId, thinking: null, tools: new Map() };
    folds.set(turnId, created);
    return created;
  };

  for (const event of events) {
    const payload = payloadOf(event);
    if (event.type === 'thinking.started') {
      const fold = foldFor(event.turnId);
      if (!fold.thinking) {
        fold.thinking = { status: 'streaming', durationMs: null, text: '', truncated: false, redacted: false };
      }
    } else if (event.type === 'thinking.delta') {
      const fold = foldFor(event.turnId);
      if (!fold.thinking) {
        fold.thinking = { status: 'streaming', durationMs: null, text: '', truncated: false, redacted: false };
      }
      const chunk = typeof payload.text === 'string' ? payload.text : '';
      const appended = appendString(fold.thinking.text, chunk);
      fold.thinking.text = appended.text;
      fold.thinking.truncated = fold.thinking.truncated || appended.truncated;
    } else if (event.type === 'thinking.completed') {
      const fold = foldFor(event.turnId);
      const redacted = payload.redacted === true;
      if (!fold.thinking) {
        fold.thinking = { status: 'done', durationMs: null, text: '', truncated: false, redacted };
      } else {
        fold.thinking.status = redacted ? 'redacted' : 'done';
        fold.thinking.redacted = redacted;
      }
      if (typeof payload.durationMs === 'number' && Number.isFinite(payload.durationMs)) {
        fold.thinking.durationMs = Math.max(0, payload.durationMs);
      }
      if (redacted) {
        fold.thinking.text = '';
        fold.thinking.truncated = false;
      }
    } else if (event.type === 'tool.started') {
      const fold = foldFor(event.turnId);
      const callId = typeof payload.callId === 'string' ? payload.callId : '';
      const tool = typeof payload.tool === 'string' ? payload.tool : '';
      const query = typeof payload.query === 'string' && payload.query.trim() ? payload.query.slice(0, 200) : undefined;
      fold.tools.set(callId, {
        callId,
        tool,
        labelKey: tool,
        status: 'running',
        ...(query ? { query } : {})
      });
    } else if (event.type === 'tool.completed') {
      const fold = foldFor(event.turnId);
      const callId = typeof payload.callId === 'string' ? payload.callId : '';
      const existing = fold.tools.get(callId);
      if (existing) {
        existing.status = payload.ok === true ? 'completed' : 'failed';
      } else {
        fold.tools.set(callId, {
          callId,
          tool: typeof payload.tool === 'string' ? payload.tool : '',
          labelKey: typeof payload.tool === 'string' ? payload.tool : '',
          status: payload.ok === true ? 'completed' : 'failed'
        });
      }
    }
  }

  return [...folds.values()].map((fold) => ({
    turnId: fold.turnId,
    durationMs: turnDurationMs(turnsById.get(fold.turnId)),
    thinking: fold.thinking,
    tools: [...fold.tools.values()]
  }));
}
