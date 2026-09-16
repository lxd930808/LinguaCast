import type { V2Store } from './store.js';

export interface V2RecoveryScan {
  pendingOperations: number;
  expiredLeases: number;
  deletingResearches: number;
  creatingResearches: number;
}

export function scanV2Recovery(store: V2Store): V2RecoveryScan {
  const db = store.getDb();
  const pending = db.prepare(
    `SELECT COUNT(*) AS n FROM v2_workspace_operations WHERE stage IN ('pending_file', 'pending_manifest')`
  ).get() as { n: number };
  const deleting = db.prepare(`SELECT COUNT(*) AS n FROM v2_researches WHERE status = 'deleting'`).get() as { n: number };
  const creating = db.prepare(`SELECT COUNT(*) AS n FROM v2_researches WHERE status = 'creating'`).get() as { n: number };
  return {
    pendingOperations: Number(pending.n),
    expiredLeases: store.listExpiredLeases().length,
    deletingResearches: Number(deleting.n),
    creatingResearches: Number(creating.n)
  };
}

export function reclaimExpiredTurnLeases(store: V2Store): string[] {
  const expired = store.listExpiredLeases();
  const interrupted: string[] = [];
  for (const lease of expired) {
    const turn = store.getTurn(lease.turnId);
    store.releaseTurnLease(lease.turnId, lease.workerId);
    if (turn?.status === 'running') {
      store.setTurnStatus(turn.turnId, 'running', 'interrupted');
      interrupted.push(turn.turnId);
    }
  }
  return interrupted;
}
