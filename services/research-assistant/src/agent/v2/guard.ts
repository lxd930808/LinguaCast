import { DomainError } from '../../domain/types.js';
import { FORBIDDEN_DEFAULT_TOOLS } from '../runtime.js';
import { toolsForTurn, V2_ALL_TOOLS, type V2ResearchPhase, type V2TurnKind } from './tools.js';

export interface ToolGuardInput {
  tool: string;
  kind: V2TurnKind;
  phase?: V2ResearchPhase;
  researchId: string;
  turnId: string;
  expectedResearchId: string;
  expectedTurnId: string;
  confirmationToken?: string;
  uri?: string;
  grantAliases?: string[];
}

export function assertV2ToolAllowed(input: ToolGuardInput): void {
  if (FORBIDDEN_DEFAULT_TOOLS.includes(input.tool)) {
    throw new DomainError('TOOL_NOT_ALLOWED', 'default coding or unconstrained web tools are forbidden', false, 403);
  }
  if (!V2_ALL_TOOLS.includes(input.tool as (typeof V2_ALL_TOOLS)[number])) {
    throw new DomainError('TOOL_NOT_ALLOWED', 'tool is not in the V2 whitelist', false, 403);
  }
  const allowed = toolsForTurn(input.kind, input.phase ?? (input.kind === 'content_qa' ? 'gathering' : 'gathering'));
  if (!allowed.includes(input.tool as (typeof allowed)[number])) {
    throw new DomainError('TOOL_NOT_ALLOWED', 'tool is not enabled for this turn phase', false, 403);
  }
  if (!input.researchId || input.researchId !== input.expectedResearchId) {
    throw new DomainError('FORBIDDEN', 'research id does not match the active turn', false, 403);
  }
  if (!input.turnId || input.turnId !== input.expectedTurnId) {
    throw new DomainError('FORBIDDEN', 'turn id does not match the active turn', false, 403);
  }
  if (input.tool === 'request_transcription' && !input.confirmationToken) {
    throw new DomainError('TRANSCRIPT_CONFIRMATION_REQUIRED', 'missing user confirmation token', false, 400);
  }
  if (typeof input.uri === 'string' && input.uri.startsWith('shared://')) {
    const alias = input.uri.slice('shared://'.length).split('/')[0];
    if (!alias || !(input.grantAliases ?? []).includes(alias)) {
      throw new DomainError('WORKSPACE_GRANT_DENIED', 'alias is not granted to this research', false, 403);
    }
  }
}

export function clipToolResult(value: unknown, maxChars = 4000): unknown {
  const json = JSON.stringify(value);
  if (json.length <= maxChars) return value;
  return { truncated: true, preview: json.slice(0, maxChars) };
}

export function sanitizeToolEvent(payload: Record<string, unknown>): Record<string, unknown> {
  const blocked = ['path', 'relativePath', 'argv', 'cwd', 'headers', 'authorization', 'cookie'];
  const out: Record<string, unknown> = {};
  for (const [key, val] of Object.entries(payload)) {
    if (blocked.includes(key)) continue;
    if (typeof val === 'string' && (val.startsWith('/') || val.includes('\\'))) continue;
    out[key] = val;
  }
  return out;
}
