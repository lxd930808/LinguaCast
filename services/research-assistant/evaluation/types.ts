export type EvalIntent = 'topic' | 'person' | 'show' | 'channel' | 'recent';
export type EvalLanguage = 'en' | 'zh';
export type EvalMedia = 'youtube' | 'podcast';

export type EvalMatchRule =
  | { kind: 'title_contains'; terms: string[] }
  | { kind: 'identity'; stableId?: string; sourceId?: string }
  | { kind: 'source_type'; sourceType: 'video' | 'podcast_show' | 'podcast_episode' }
  | { kind: 'publisher_contains'; terms: string[] };

export interface EvalQuery {
  id: string;
  query: string;
  language: EvalLanguage;
  intent: EvalIntent;
  media: EvalMedia[];
  publishedAfter: string | null;
  duration: 'short' | 'medium' | 'long' | null;
  relevant: EvalMatchRule[];
  preferred: EvalMatchRule[];
  unacceptable: EvalMatchRule[];
  ambiguous: boolean;
  expectQualifiedHit: boolean;
  expectZero: boolean;
  notes: string;
}

export interface EvalResult {
  rank: number;
  platform: 'youtube' | 'podcast' | 'apple_podcasts';
  sourceType: 'video' | 'podcast_show' | 'podcast_episode';
  sourceId: string;
  stableId?: string;
  title: string;
  publisher?: string | null;
  publishedAt?: string | null;
  qualified?: boolean;
  selectedForReport?: boolean;
}

export interface EvalRun {
  queryId: string;
  retrievedAt: string;
  provider: string;
  results: EvalResult[];
}

export interface EvalMetrics {
  youtubeTop5Precision: number | null;
  podcastTop5Precision: number | null;
  personEpisodeTop5Precision: number | null;
  qualifiedHitCoverage: number;
  dateCompliance: number | null;
  reportOffTopicRate: number;
  queryCount: number;
}

export interface EvalReport {
  mode: 'baseline' | 'candidate';
  generatedAt: string;
  commit: string;
  fixtureVersion: string;
  providerConfig: Record<string, string | boolean>;
  metrics: EvalMetrics;
  perQuery: Array<{
    queryId: string;
    precisionAt5: number | null;
    qualifiedHit: boolean;
    dateCompliant: boolean | null;
    offTopicReportSources: number;
    reportSourceCount: number;
  }>;
}
