import type { V2MemoryProposalRecord, V2Store } from '../db/v2/store.js';
import { nowIso } from '../domain/ids.js';
import { DomainError } from '../domain/types.js';
import { newMemoryProposalId } from '../research-v2/state.js';
import type { GlobalMemory } from './global-memory.js';
import {
  MEMORY_CONTENT_MAX,
  MEMORY_REASON_MAX,
  PROPOSAL_TTL_MS,
  type MemoryEntry,
  type MemoryProposal
} from './types.js';

export class MemoryProposals {
  constructor(
    private readonly store: V2Store,
    private readonly global: GlobalMemory
  ) {}

  propose(input: { researchId: string; content: string; reason: string; expiresAt?: string }): MemoryProposal {
    if (!this.store.getResearch(input.researchId)) {
      throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    }
    const now = nowIso();
    const record = this.store.insertMemoryProposal({
      proposalId: newMemoryProposalId(),
      researchId: input.researchId,
      content: clip(input.content, MEMORY_CONTENT_MAX),
      reason: clip(input.reason, MEMORY_REASON_MAX),
      status: 'pending',
      createdAt: now,
      expiresAt: input.expiresAt ?? new Date(Date.now() + PROPOSAL_TTL_MS).toISOString().replace(/\.\d{3}Z$/, 'Z'),
      confirmedAt: null,
      rejectedAt: null,
      memoryEntryId: null
    });
    return toProposal(record);
  }

  confirm(proposalId: string): MemoryEntry {
    const proposal = this.require(proposalId);
    this.expireIfDue(proposal);
    const current = this.store.getMemoryProposal(proposalId)!;
    if (current.status === 'confirmed') {
      const existing = current.memoryEntryId ? this.store.getMemoryEntry(current.memoryEntryId) : null;
      if (existing) {
        return {
          memoryEntryId: existing.memoryEntryId,
          scope: 'global',
          type: existing.type,
          content: existing.content,
          status: existing.status,
          sourceArtifactId: existing.sourceArtifactId,
          hypothesis: existing.hypothesis,
          createdAt: existing.createdAt,
          confirmedAt: existing.confirmedAt
        };
      }
    }
    if (current.status === 'expired') {
      throw new DomainError('MEMORY_PROPOSAL_EXPIRED', 'proposal has expired', false, 409);
    }
    if (current.status !== 'pending') {
      throw new DomainError('MEMORY_PROPOSAL_ALREADY_RESOLVED', 'proposal is already resolved', false, 409);
    }
    const owner = this.store.getResearch(current.researchId, true)?.ownerScope;
    if (!owner) throw new DomainError('RESEARCH_NOT_FOUND', 'research is unknown or deleted', false, 404);
    const entry = this.global.writeConfirmed({
      content: current.content,
      sourceResearchId: current.researchId,
      ownerScope: owner
    });
    this.store.setMemoryProposalStatus(proposalId, 'pending', 'confirmed', entry.memoryEntryId);
    return entry;
  }

  reject(proposalId: string): MemoryProposal {
    const proposal = this.require(proposalId);
    this.expireIfDue(proposal);
    const current = this.store.getMemoryProposal(proposalId)!;
    if (current.status === 'rejected') return toProposal(current);
    if (current.status === 'expired') {
      throw new DomainError('MEMORY_PROPOSAL_EXPIRED', 'proposal has expired', false, 409);
    }
    if (current.status !== 'pending') {
      throw new DomainError('MEMORY_PROPOSAL_ALREADY_RESOLVED', 'proposal is already resolved', false, 409);
    }
    this.store.setMemoryProposalStatus(proposalId, 'pending', 'rejected');
    return toProposal(this.store.getMemoryProposal(proposalId)!);
  }

  private require(proposalId: string): V2MemoryProposalRecord {
    const proposal = this.store.getMemoryProposal(proposalId);
    if (!proposal) {
      throw new DomainError('INVALID_REQUEST', 'memory proposal is unknown', false, 404);
    }
    return proposal;
  }

  private expireIfDue(proposal: V2MemoryProposalRecord): void {
    expireDueProposal(this.store, proposal);
  }
}

export function expireDueProposals(store: V2Store, researchId: string): void {
  for (const proposal of store.listMemoryProposals(researchId)) {
    expireDueProposal(store, proposal);
  }
}

export function toProposal(record: V2MemoryProposalRecord): MemoryProposal {
  return {
    proposalId: record.proposalId,
    researchId: record.researchId,
    content: record.content,
    reason: record.reason,
    status: record.status,
    createdAt: record.createdAt,
    expiresAt: record.expiresAt,
    confirmedAt: record.confirmedAt,
    rejectedAt: record.rejectedAt,
    memoryEntryId: record.memoryEntryId
  };
}

function expireDueProposal(store: V2Store, proposal: V2MemoryProposalRecord): void {
  if (proposal.status === 'pending' && proposal.expiresAt <= nowIso()) {
    store.setMemoryProposalStatus(proposal.proposalId, 'pending', 'expired');
  }
}

function clip(value: string, max: number): string {
  const text = value.normalize('NFC').trim();
  if (!text) {
    throw new DomainError('INVALID_REQUEST', 'memory text is required', false, 400);
  }
  return text.slice(0, max);
}
