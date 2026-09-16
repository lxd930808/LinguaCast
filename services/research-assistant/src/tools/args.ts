import { DomainError } from '../domain/types.js';
import { ALL_KNOWN_TOOLS, type ToolName } from '../agent/runtime.js';

const QUERY_MAX = 200;
const TEXT_MAX = 8_000;

export function requireToolName(name: string): ToolName {
  if (!ALL_KNOWN_TOOLS.includes(name as ToolName)) {
    throw new DomainError('TOOL_LIMIT_EXCEEDED', `unknown tool ${name}`, false, 400);
  }
  return name as ToolName;
}

export function toolQuery(args: Record<string, unknown>, field = 'query'): string {
  const value = typeof args[field] === 'string' ? args[field].normalize('NFC').trim() : '';
  if (value.length < 1 || value.length > QUERY_MAX) {
    throw new DomainError('INVALID_REQUEST', `${field} must be 1-${QUERY_MAX} characters`, false, 400, { field });
  }
  return value;
}

export function toolLimit(args: Record<string, unknown>, fallback = 10): number {
  const raw = args.limit;
  if (raw === undefined || raw === null) return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1 || value > 10) {
    throw new DomainError('INVALID_REQUEST', 'limit must be an integer between 1 and 10', false, 400, {
      field: 'limit'
    });
  }
  return value;
}

export function toolString(args: Record<string, unknown>, field: string, max = TEXT_MAX): string {
  const value = typeof args[field] === 'string' ? args[field] : '';
  return value.slice(0, max);
}

export function toolIdList(args: Record<string, unknown>, field: string): string[] {
  if (!Array.isArray(args[field])) return [];
  return args[field].map(String).slice(0, 20);
}

/** Models may send owner/session fields; application context always wins. */
export function stripUntrustedOwner(args: Record<string, unknown>): Record<string, unknown> {
  const copy = { ...args };
  delete copy.sessionId;
  delete copy.ownerId;
  delete copy.owner;
  return copy;
}
