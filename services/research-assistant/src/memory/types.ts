export interface MemoryEntry {
  memoryEntryId: string;
  scope: 'research' | 'global';
  type: string;
  content: string;
  status: string;
  sourceArtifactId: string | null;
  hypothesis: boolean;
  createdAt: string;
  confirmedAt: string | null;
}

export interface MemoryProposal {
  proposalId: string;
  researchId: string;
  content: string;
  reason: string;
  status: string;
  createdAt: string;
  expiresAt: string;
  confirmedAt: string | null;
  rejectedAt: string | null;
  memoryEntryId: string | null;
}

export interface MemorySnapshot {
  researchId: string;
  entries: MemoryEntry[];
  proposals: MemoryProposal[];
}

export interface MemoryRecallHit {
  memoryEntryId: string;
  scope: 'research' | 'global';
  mode: 'keyword' | 'fts' | 'qmd';
  score: number;
  content: string;
  hypothesis: boolean;
}

export const MEMORY_CONTENT_MAX = 2000;
export const MEMORY_REASON_MAX = 500;
export const GLOBAL_RECALL_CHAR_BUDGET = 800;
export const RESEARCH_RECALL_CHAR_BUDGET = 4000;
export const PROPOSAL_TTL_MS = 7 * 24 * 60 * 60 * 1000;
