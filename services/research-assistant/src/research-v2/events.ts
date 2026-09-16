import type { V2EventRecord, V2Store } from '../db/v2/store.js';
import { nowIso } from '../domain/ids.js';
import { sanitizeToolEvent } from '../agent/v2/guard.js';

export const V2_EVENT_TYPES = [
  'workspace.created',
  'research.title_updated',
  'web.search_started',
  'web.search_completed',
  'web.search_failed',
  'web.page_saved',
  'source.saved',
  'transcript.job_updated',
  'transcript.saved',
  'memory.updated',
  'memory.proposed',
  'thinking.started',
  'thinking.delta',
  'thinking.completed',
  'tool.started',
  'tool.completed',
  'report.delta',
  'report.completed',
  'turn.started',
  'turn.completed',
  'turn.failed',
  'turn.cancelled'
] as const;

export type V2EventType = (typeof V2_EVENT_TYPES)[number];

const TEXT_DELTA_MAX = 512;

export class V2EventLog {
  constructor(
    private readonly store: V2Store,
    private readonly researchId: string,
    private readonly turnId: string
  ) {}

  emit(type: V2EventType, payload: Record<string, unknown> = {}): V2EventRecord {
    let safe = sanitizeToolEvent(payload);
    if ((type === 'report.delta' || type === 'thinking.delta') && typeof safe.text === 'string') {
      safe = { ...safe, text: safe.text.slice(0, TEXT_DELTA_MAX) };
    }
    return this.store.appendEvent({
      researchId: this.researchId,
      turnId: this.turnId,
      type,
      sequence: this.store.nextEventSequence(this.turnId),
      payload: safe,
      occurredAt: nowIso()
    });
  }
}
