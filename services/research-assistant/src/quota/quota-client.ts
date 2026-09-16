/**
 * Account-service quota API client for assistant turns
 * (docs/contracts/account-v1-integration.md §3). Contract codes pass through
 * unchanged; transport failures become ACCOUNT_SERVICE_UNAVAILABLE and the turn
 * is never started unpaid.
 */

export class QuotaError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly retryable = false,
    readonly params?: Record<string, unknown>,
    readonly retryAfterSeconds?: number
  ) {
    super(message);
    this.name = 'QuotaError';
  }
}

export interface ReservationView {
  reservationId: string;
  status: 'reserved' | 'consumed' | 'released';
  amount: number;
  operationKey: string;
}

export type SettleOutcome = 'consumed' | 'released';
export type SettleReason =
  | 'succeeded'
  | 'failed'
  | 'cancelled'
  | 'reused_artifact'
  | 'rejected_before_start'
  | 'account_deleted';

export interface ReserveRequest {
  accountId: string;
  operationKey: string;
  amount: number;
  subjectRef?: string | null;
}

export interface QuotaClient {
  reserve(request: ReserveRequest): Promise<ReservationView>;
  settle(reservationId: string, outcome: SettleOutcome, reason: SettleReason): Promise<'settled' | 'conflict'>;
}

const PASS_THROUGH = new Set([403, 404, 409, 422, 429]);

function unavailable(): QuotaError {
  return new QuotaError(503, 'ACCOUNT_SERVICE_UNAVAILABLE', 'quota could not be verified', true, undefined, 5);
}

export class HttpQuotaClient implements QuotaClient {
  private readonly baseUrl: string;

  constructor(private readonly options: { baseUrl: string; token: string; fetchImpl?: typeof fetch; timeoutMs?: number }) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, '');
  }

  async reserve(request: ReserveRequest): Promise<ReservationView> {
    const response = await this.post('/internal/v1/quota/reservations', {
      accountId: request.accountId,
      kind: 'assistant',
      operationKey: request.operationKey,
      amount: request.amount,
      service: 'research-assistant',
      ...(request.subjectRef ? { subjectRef: request.subjectRef } : {})
    });
    const body = (await response.json().catch(() => null)) as Record<string, any> | null;
    if (response.status === 200 || response.status === 201) {
      if (!body || typeof body.reservationId !== 'string' || typeof body.status !== 'string') throw unavailable();
      return {
        reservationId: body.reservationId,
        status: body.status as ReservationView['status'],
        amount: Number(body.amount),
        operationKey: String(body.operationKey)
      };
    }
    if (PASS_THROUGH.has(response.status) && body?.error?.code) {
      const retryAfter = Number(response.headers.get('retry-after') ?? body.error.retryAfterSeconds);
      throw new QuotaError(
        response.status,
        String(body.error.code),
        String(body.error.message ?? 'quota request rejected'),
        Boolean(body.error.retryable),
        body.error.params,
        Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : undefined
      );
    }
    throw unavailable();
  }

  async settle(reservationId: string, outcome: SettleOutcome, reason: SettleReason): Promise<'settled' | 'conflict'> {
    const response = await this.post(`/internal/v1/quota/reservations/${encodeURIComponent(reservationId)}/settle`, {
      outcome,
      reason
    });
    await response.body?.cancel().catch(() => undefined);
    if (response.status === 200) return 'settled';
    if (response.status === 404 || response.status === 409) return 'conflict';
    throw unavailable();
  }

  private async post(path: string, body: unknown): Promise<Response> {
    try {
      return await (this.options.fetchImpl ?? fetch)(`${this.baseUrl}${path}`, {
        method: 'POST',
        headers: { authorization: `Bearer ${this.options.token}`, 'content-type': 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(this.options.timeoutMs ?? 5000)
      });
    } catch {
      throw unavailable();
    }
  }
}
