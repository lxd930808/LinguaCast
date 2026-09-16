import { ulid } from 'ulid';

import { DomainError } from '../domain/types.js';

export type ResearchStatus = 'creating' | 'ready' | 'deleting' | 'deleted' | 'failed' | 'degraded' | 'corrupt';
export type WorkspaceIntegrity = 'pending' | 'ready' | 'degraded' | 'corrupt' | 'deleting' | 'deleted';
export type TurnMode = 'research' | 'content_qa';
export type V2TurnStatus = 'queued' | 'running' | 'completed' | 'failed' | 'cancelled' | 'interrupted';
export type ArtifactStatus = 'pending' | 'ready' | 'superseded' | 'failed' | 'corrupt';
export type TranscriptJobStatus =
  | 'requested'
  | 'waiting_service'
  | 'running'
  | 'installing'
  | 'ready'
  | 'failed_retryable'
  | 'failed_terminal';
export type MemoryProposalStatus = 'pending' | 'confirmed' | 'rejected' | 'expired';
export type OperationStage = 'pending_file' | 'pending_manifest' | 'completed' | 'failed' | 'rolled_back';

export const RESEARCH_TRANSITIONS: Record<ResearchStatus, ResearchStatus[]> = {
  creating: ['ready', 'failed'],
  ready: ['deleting', 'degraded', 'corrupt'],
  degraded: ['ready', 'corrupt', 'deleting'],
  corrupt: ['ready', 'deleting'],
  failed: ['deleting'],
  deleting: ['deleted'],
  deleted: []
};

export const TURN_TRANSITIONS: Record<V2TurnStatus, V2TurnStatus[]> = {
  queued: ['running', 'cancelled'],
  running: ['completed', 'failed', 'cancelled', 'interrupted'],
  completed: [],
  failed: [],
  cancelled: [],
  interrupted: ['queued']
};

export const ARTIFACT_TRANSITIONS: Record<ArtifactStatus, ArtifactStatus[]> = {
  pending: ['ready', 'failed', 'corrupt'],
  ready: ['superseded', 'corrupt'],
  superseded: [],
  failed: ['pending'],
  corrupt: []
};

export const TRANSCRIPT_JOB_TRANSITIONS: Record<TranscriptJobStatus, TranscriptJobStatus[]> = {
  requested: ['waiting_service', 'running', 'failed_retryable', 'failed_terminal'],
  waiting_service: ['running', 'failed_retryable', 'failed_terminal'],
  running: ['installing', 'failed_retryable', 'failed_terminal'],
  installing: ['ready', 'failed_retryable', 'failed_terminal'],
  ready: [],
  failed_retryable: ['waiting_service', 'running', 'failed_terminal'],
  failed_terminal: []
};

export const MEMORY_PROPOSAL_TRANSITIONS: Record<MemoryProposalStatus, MemoryProposalStatus[]> = {
  pending: ['confirmed', 'rejected', 'expired'],
  confirmed: [],
  rejected: [],
  expired: []
};

export function canResearchTransition(from: ResearchStatus, to: ResearchStatus): boolean {
  return RESEARCH_TRANSITIONS[from]?.includes(to) === true;
}

export function canTurnTransition(from: V2TurnStatus, to: V2TurnStatus): boolean {
  return TURN_TRANSITIONS[from]?.includes(to) === true;
}

export function canArtifactTransition(from: ArtifactStatus, to: ArtifactStatus): boolean {
  return ARTIFACT_TRANSITIONS[from]?.includes(to) === true;
}

export function canTranscriptJobTransition(from: TranscriptJobStatus, to: TranscriptJobStatus): boolean {
  return TRANSCRIPT_JOB_TRANSITIONS[from]?.includes(to) === true;
}

export function canMemoryProposalTransition(from: MemoryProposalStatus, to: MemoryProposalStatus): boolean {
  return MEMORY_PROPOSAL_TRANSITIONS[from]?.includes(to) === true;
}

export function assertResearchTransition(from: ResearchStatus, to: ResearchStatus): void {
  if (!canResearchTransition(from, to)) {
    throw new DomainError('INVALID_RESEARCH_STATUS', `cannot move research from ${from} to ${to}`, false, 409);
  }
}

export function assertTurnTransition(from: V2TurnStatus, to: V2TurnStatus): void {
  if (!canTurnTransition(from, to)) {
    throw new DomainError('INVALID_RESEARCH_STATUS', `cannot move turn from ${from} to ${to}`, false, 409);
  }
}

export function assertArtifactTransition(from: ArtifactStatus, to: ArtifactStatus): void {
  if (!canArtifactTransition(from, to)) {
    throw new DomainError('ARTIFACT_WRITE_FAILED', `cannot move artifact from ${from} to ${to}`, false, 409);
  }
}

export function newResearchId(): string {
  return ulid();
}

export function newTurnId(): string {
  return `vt_${ulid()}`;
}

export function newMessageId(): string {
  return `vm_${ulid()}`;
}

export function newArtifactId(): string {
  return ulid();
}

export function newTranscriptJobId(): string {
  return `tj_${ulid()}`;
}

export function newMemoryProposalId(): string {
  return `mp_${ulid()}`;
}

export function newMemoryEntryId(): string {
  return `me_${ulid()}`;
}

export function newSourceId(): string {
  return `so_${ulid()}`;
}

export function newOperationId(): string {
  return `op_${ulid()}`;
}

export function newLeaseId(): string {
  return `ls_${ulid()}`;
}

export function newCitationId(): string {
  return ulid();
}
