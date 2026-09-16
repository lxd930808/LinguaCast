import type { ArtifactWriter } from '../artifacts/writer.js';
import type { V2ArtifactRecord, V2Store } from '../db/v2/store.js';
import { nowIso } from '../domain/ids.js';
import { DomainError } from '../domain/types.js';
import {
  toCitationRecords,
  validateCitations,
  type ProposedCitation,
  type ValidatedCitation
} from '../evidence/citations.js';
import type { EvidencePack } from '../evidence/pack.js';
import { newMessageId } from './state.js';

export interface ReportSaveInput {
  title?: string;
  markdown: string;
  citations?: ProposedCitation[];
  evidencePack?: EvidencePack | null;
}

export interface ReportSaveResult {
  artifact: V2ArtifactRecord;
  citations: ValidatedCitation[];
  messageId: string;
  repaired: boolean;
  evidenceGap: boolean;
}

const GAP_PREFIX = 'Evidence gap:';

export function parseProposedCitations(value: unknown): ProposedCitation[] {
  if (!Array.isArray(value)) return [];
  const out: ProposedCitation[] = [];
  for (const item of value) {
    if (!item || typeof item !== 'object') continue;
    const row = item as Record<string, unknown>;
    if (typeof row.artifactId !== 'string' || typeof row.quote !== 'string') continue;
    out.push({
      artifactId: row.artifactId,
      evidenceLevel: typeof row.evidenceLevel === 'string' ? row.evidenceLevel : undefined,
      label: typeof row.label === 'string' ? row.label : undefined,
      passageId: typeof row.passageId === 'string' ? row.passageId : null,
      startMilliseconds: typeof row.startMilliseconds === 'number' ? row.startMilliseconds : null,
      endMilliseconds: typeof row.endMilliseconds === 'number' ? row.endMilliseconds : null,
      sourceURL: typeof row.sourceURL === 'string' ? row.sourceURL : null,
      contentKey: typeof row.contentKey === 'string' ? row.contentKey : null,
      quote: row.quote,
      sha256: typeof row.sha256 === 'string' ? row.sha256 : undefined
    });
  }
  return out;
}

export function factualParagraphs(markdown: string): string[] {
  return markdown
    .split(/\n{2,}/)
    .map((block) => block.trim())
    .filter((block) => {
      if (!block) return false;
      if (block.startsWith('#') || block.startsWith('>')) return false;
      if (block.startsWith(GAP_PREFIX)) return false;
      if (block.startsWith('- ') || block.startsWith('* ')) return false;
      return [...block].length >= 24;
    });
}

export function gapMarkdown(query: string, pack: EvidencePack | null, original?: string): string {
  const reasons = pack?.gaps.map((gap) => gap.reason).join(' ') || `no locatable artifacts matched ${JSON.stringify(query)}`;
  const body = original?.trim()
    ? `${original.trim()}\n\n${GAP_PREFIX} ${reasons}`
    : `${GAP_PREFIX} ${reasons}`;
  return body;
}

export function saveValidatedReport(
  store: V2Store,
  writer: ArtifactWriter,
  input: {
    researchId: string;
    turnId: string;
    title: string;
    markdown: string;
    citations: ProposedCitation[];
    allowEmptyCitations: boolean;
  }
): ReportSaveResult {
  const validated = validateCitations(store, input.researchId, input.citations);
  if (!validated.ok) {
    if (!input.allowEmptyCitations || input.citations.length > 0) {
      throw new DomainError(validated.code, validated.reason, false, 400);
    }
  }
  const citations = validated.ok ? validated.citations : [];
  const artifact = writer.save({
    kind: 'report',
    contents: input.markdown,
    producer: 'save_research_report',
    evidenceLevel: 'research_note',
    passages: [{ text: input.markdown.slice(0, 4000) }]
  });
  const messageId = newMessageId();
  store.insertMessage({
    messageId,
    researchId: input.researchId,
    turnId: input.turnId,
    role: 'assistant',
    markdown: input.markdown,
    createdAt: nowIso()
  });
  const records = toCitationRecords(input.researchId, messageId, citations);
  for (const record of records) {
    store.insertCitation(record);
  }
  return {
    artifact,
    citations,
    messageId,
    repaired: false,
    evidenceGap: citations.length === 0
  };
}
