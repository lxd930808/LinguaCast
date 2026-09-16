import { createHash } from 'node:crypto';

import { ACCOUNT_CONTEXT_HEADER, signAccountContext } from '../auth/account-context.js';

export { podcastContentKey, videoContentKey } from './content-key.js';

export interface V10Job {
  jobId: string;
  status: string;
  stage?: string;
  progress?: number;
  retryAfterSeconds?: number;
  error?: { code: string; message: string; retryable: boolean } | null;
  artifacts?: {
    files: Array<{ name: string; role: string; status: string; bytes: number; sha256: string }>;
  } | null;
}

/** Account on whose behalf a content-pipeline call is made (V18 signed account context). */
export interface V10CallContext {
  ownerScope: string;
  operationKey?: string | null;
  reservationId?: string | null;
}

export interface V10ContentClient {
  lookup(input: {
    contentType: string;
    contentKey: string;
    targetLanguage: string;
    translationQuality: string;
  }, context?: V10CallContext): Promise<V10Job | null>;
  create(input: {
    contentType: string;
    contentKey: string;
    source: Record<string, unknown>;
    sourceLanguage: string;
    targetLanguage: string;
    translationQuality: string;
    idempotencyKey: string;
  }, context?: V10CallContext): Promise<V10Job>;
  get(jobId: string, context?: V10CallContext): Promise<V10Job>;
  downloadSegments(jobId: string, context?: V10CallContext): Promise<{ body: Buffer; sha256: string }>;
}

export class HttpV10ContentClient implements V10ContentClient {
  constructor(
    private readonly baseUrl: string,
    private readonly token: string,
    private readonly fetchImpl: typeof fetch = fetch,
    /** When set, every call carries the owner's signed account context (account mode). */
    private readonly contextSigningKey: string | null = null
  ) {}

  private contextHeaders(context: V10CallContext | undefined): Record<string, string> {
    if (!this.contextSigningKey) return {};
    if (!context) throw Object.assign(new Error('V10 call is missing its account context'), { code: 'V10_UNAUTHORIZED', status: 401 });
    return {
      [ACCOUNT_CONTEXT_HEADER]: signAccountContext(
        {
          accountId: context.ownerScope,
          authMode: context.ownerScope === 'selfhost' ? 'selfhost' : 'apple',
          sessionId: null,
          operationKey: context.operationKey ?? null,
          reservationId: context.reservationId ?? null,
          issuer: 'research-assistant'
        },
        this.contextSigningKey
      )
    };
  }

  async lookup(input: {
    contentType: string;
    contentKey: string;
    targetLanguage: string;
    translationQuality: string;
  }, context?: V10CallContext): Promise<V10Job | null> {
    const url = new URL(`${this.baseUrl}/v1/content-jobs:lookup`);
    url.searchParams.set('contentType', input.contentType);
    url.searchParams.set('contentKey', input.contentKey);
    url.searchParams.set('targetLanguage', input.targetLanguage);
    url.searchParams.set('translationQuality', input.translationQuality);
    const json = (await this.request('GET', url, undefined, {}, context)) as { job: V10Job | null };
    return json.job;
  }

  async create(input: {
    contentType: string;
    contentKey: string;
    source: Record<string, unknown>;
    sourceLanguage: string;
    targetLanguage: string;
    translationQuality: string;
    idempotencyKey: string;
  }, context?: V10CallContext): Promise<V10Job> {
    return this.request('POST', new URL(`${this.baseUrl}/v1/content-jobs`), {
      contentType: input.contentType,
      contentKey: input.contentKey,
      source: input.source,
      sourceLanguage: input.sourceLanguage,
      targetLanguage: input.targetLanguage,
      translationQuality: input.translationQuality,
      clientArtifactSchemaVersion: 1
    }, { 'idempotency-key': input.idempotencyKey }, context) as Promise<V10Job>;
  }

  async get(jobId: string, context?: V10CallContext): Promise<V10Job> {
    return this.request('GET', new URL(`${this.baseUrl}/v1/content-jobs/${jobId}`), undefined, {}, context) as Promise<V10Job>;
  }

  async downloadSegments(jobId: string, context?: V10CallContext): Promise<{ body: Buffer; sha256: string }> {
    const url = new URL(`${this.baseUrl}/v1/content-artifacts/${encodeURIComponent(jobId)}/segments.json`);
    const response = await this.fetchImpl(url, {
      signal: AbortSignal.timeout(30_000),
      headers: { authorization: `Bearer ${this.token}`, ...this.contextHeaders(context) }
    });
    if (!response.ok) {
      throw new Error(`V10 artifact HTTP ${response.status}`);
    }
    const body = Buffer.from(await response.arrayBuffer());
    const sha256 = createHash('sha256').update(body).digest('hex');
    return { body, sha256 };
  }

  private async request(
    method: string,
    url: URL,
    body?: unknown,
    headers: Record<string, string> = {},
    context?: V10CallContext
  ): Promise<unknown> {
    const response = await this.fetchImpl(url, {
      method,
      signal: AbortSignal.timeout(30_000),
      headers: {
        authorization: `Bearer ${this.token}`,
        ...this.contextHeaders(context),
        ...(body ? { 'content-type': 'application/json' } : {}),
        ...headers
      },
      body: body ? JSON.stringify(body) : undefined
    });
    const json = await response.json().catch(() => ({}));
    if (!response.ok) {
      const error = json as { error?: { code?: string; message?: string; retryable?: boolean } };
      throw Object.assign(new Error(error.error?.message ?? `V10 HTTP ${response.status}`), {
        code: error.error?.code ?? (response.status === 401 ? 'V10_UNAUTHORIZED' : response.status >= 500 || response.status === 408 || response.status === 429 ? 'V10_UNAVAILABLE' : 'V10_REQUEST_REJECTED'),
        status: response.status,
        retryable: error.error?.retryable
      });
    }
    return json;
  }
}
