import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const V15_BASELINE_COMMIT = '75ab9725fac556bbc4be202f7c5d2a96ad927008';

export const V1_CONTRACT_SHA256 = {
  'assistant-v1.openapi.yaml': '42d64a4a5d5fcb78492dc28d42e660ba6f7df267e5d8b56894e3d7f75546ecbc',
  'assistant-v1.wire.schema.json': 'fe4fe7bff4985b2c37ea9b8f24aca596c59f9ab85721b0875a7db7243662f307',
  'assistant-sse-v1.md': '5f0cc5ec9e734381d30fba17d3a0935172a80f7d5c5a13d64fdb3211a2b580de',
  'assistant-error-codes.md': '9272ea3494fbcb7bc9d5286e6e7d122999028437516ea717c98fdd3a76ea78fb'
} as const;

const SNAPSHOT_DEF: Record<string, string> = {
  'session-snapshot-research-happy.json': 'SessionSnapshot',
  'session-snapshot-source-groups.json': 'SessionSnapshot',
  'turn-create-research.json': 'TurnCreateRequest',
  'turn-accepted-research.json': 'TurnAcceptedResponse',
  'search-run-success.json': 'SearchRun',
  'search-run-partial.json': 'SearchRun',
  'qa-answer-with-citations.json': 'AssistantMessage',
  'error-envelope-unauthorized.json': 'ErrorEnvelope',
  'error-envelope-transcript-not-ready.json': 'ErrorEnvelope'
};

export interface BaselineInventory {
  schemaVersion: number;
  capturedAt: string;
  gitCommit: string;
  networkRequired: boolean;
  files: Array<{ file: string; bytes: number; sha256: string }>;
}

export function evaluationDir(): string {
  return dirname(fileURLToPath(import.meta.url));
}

export function baselineDir(): string {
  return join(evaluationDir(), 'v15-baseline');
}

export function loadInventory(): BaselineInventory {
  return JSON.parse(readFileSync(join(baselineDir(), 'inventory.json'), 'utf8')) as BaselineInventory;
}

export function sha256File(path: string): string {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

export function snapshotFiles(): string[] {
  return readdirSync(join(baselineDir(), 'snapshots')).filter((name) => name.endsWith('.json')).sort();
}

export function loadSnapshot(name: string): unknown {
  return JSON.parse(readFileSync(join(baselineDir(), 'snapshots', name), 'utf8'));
}

export function wireDefinitionForSnapshot(name: string): string | null {
  return SNAPSHOT_DEF[name] ?? null;
}

export function sseSnapshotNames(): string[] {
  return ['sse-replay-events.json', 'sse-search-events.json', 'sse-title-updated.json'];
}
