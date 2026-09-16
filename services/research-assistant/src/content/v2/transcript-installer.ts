import { createHash } from 'node:crypto';

import type { ArtifactWriter } from '../../artifacts/writer.js';
import type { V10ContentClient, V10Job } from '../v10-client.js';
import type { V2ArtifactRecord, V2Store } from '../../db/v2/store.js';
import { DomainError } from '../../domain/types.js';
import {
  buildSourceOnlyTranscript,
  containsTranslationLeak,
  decodeAndStripSourceOnly,
  encodeSourceOnlyJson,
  encodeSourceOnlyMarkdown,
  passageIdForSequence,
  type SourceOnlyTranscript
} from './source-only.js';

export interface TranscriptSource {
  sourceId: string;
  platform: 'youtube' | 'podcast';
  nativeSourceId: string;
  canonicalURL: string;
  title?: string;
  feedURL?: string | null;
  enclosureUrl?: string | null;
}

export function transcriptRelativeDir(platform: 'youtube' | 'podcast', contentKey: string): string {
  const folder = platform === 'youtube' ? 'youtube' : 'podcasts';
  const id = createHash('sha256').update(contentKey, 'utf8').digest('hex').slice(0, 16);
  return `transcripts/${folder}/${id}`;
}

export class TranscriptInstaller {
  constructor(
    private readonly store: V2Store,
    private readonly v10: V10ContentClient
  ) {}

  findInstalled(
    researchId: string,
    writer: ArtifactWriter,
    contentKey: string,
    v10ArtifactSha256: string
  ): V2ArtifactRecord | null {
    const artifacts = this.store.listArtifacts(researchId, 'transcript', 'ready');
    for (const artifact of artifacts) {
      if (artifact.mediaType !== 'application/json') continue;
      try {
        const body = JSON.parse(writer.get(artifact.artifactId).text) as {
          contentKey?: string;
          v10ArtifactSha256?: string;
        };
        if (body.contentKey === contentKey && body.v10ArtifactSha256 === v10ArtifactSha256) {
          return artifact;
        }
      } catch {
        continue;
      }
    }
    return null;
  }

  async install(input: {
    researchId: string;
    writer: ArtifactWriter;
    job: V10Job;
    contentKey: string;
    source: TranscriptSource;
    sourceLanguage?: string | null;
  }): Promise<{ artifact: V2ArtifactRecord; markdownArtifact: V2ArtifactRecord; reused: boolean }> {
    const file = input.job.artifacts?.files.find((item) => item.role === 'segments' && item.status === 'ready');
    if (!file) {
      throw new DomainError('ARTIFACT_INVALID', 'V10 job is missing a ready segments artifact', false, 422);
    }
    const owner = this.store.getResearch(input.researchId, true)?.ownerScope;
    const downloaded = await this.v10.downloadSegments(input.job.jobId, owner ? { ownerScope: owner } : undefined);
    if (downloaded.sha256 !== file.sha256) {
      throw new DomainError('ARTIFACT_INTEGRITY_FAILED', 'downloaded V10 artifact checksum mismatch', false, 422);
    }
    if (file.bytes > 0 && downloaded.body.length !== file.bytes) {
      throw new DomainError('ARTIFACT_INVALID', 'segments.json byte size mismatch', false, 422);
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(downloaded.body.toString('utf8'));
    } catch {
      throw new DomainError('ARTIFACT_INVALID', 'segments.json is not valid JSON', false, 422);
    }
    const segments = decodeAndStripSourceOnly(parsed);
    const sourceLanguage =
      input.sourceLanguage ??
      (typeof (parsed as { sourceLanguage?: unknown }).sourceLanguage === 'string'
        ? String((parsed as { sourceLanguage: string }).sourceLanguage)
        : null);
    const doc = buildSourceOnlyTranscript({
      contentKey: input.contentKey,
      v10JobId: input.job.jobId,
      v10ArtifactSha256: downloaded.sha256,
      sourceLanguage,
      source: {
        platform: input.source.platform,
        sourceId: input.source.nativeSourceId,
        canonicalURL: input.source.canonicalURL,
        title: input.source.title
      },
      segments
    });
    if (containsTranslationLeak(doc)) {
      throw new DomainError('ARTIFACT_INVALID', 'source-only transcript still contains translation fields', false, 422);
    }
    const existing = this.findInstalled(input.researchId, input.writer, input.contentKey, downloaded.sha256);
    if (existing) {
      const markdown = this.companionMarkdown(input.researchId, existing);
      return { artifact: existing, markdownArtifact: markdown ?? existing, reused: true };
    }
    return {
      artifact: this.writeJson(input.writer, input.source.platform, doc),
      markdownArtifact: this.writeMarkdown(input.writer, input.source.platform, doc),
      reused: false
    };
  }

  private companionMarkdown(researchId: string, jsonArtifact: V2ArtifactRecord): V2ArtifactRecord | null {
    const dir = jsonArtifact.relativePath.replace(/\/transcript\.json$/, '');
    return (
      this.store
        .listArtifacts(researchId, 'transcript', 'ready')
        .find((item) => item.relativePath === `${dir}/transcript.md`) ?? null
    );
  }

  private writeJson(writer: ArtifactWriter, platform: 'youtube' | 'podcast', doc: SourceOnlyTranscript): V2ArtifactRecord {
    const dir = transcriptRelativeDir(platform, doc.contentKey);
    return writer.save({
      kind: 'transcript',
      contents: encodeSourceOnlyJson(doc),
      producer: 'transcript-installer',
      evidenceLevel: 'transcript',
      mediaType: 'application/json',
      relativePath: `${dir}/transcript.json`,
      contentKey: doc.contentKey,
      sourceURL: doc.source.canonicalURL,
      passages: doc.segments.map((segment) => ({
        passageId: passageIdForSequence(segment.sequence),
        text: segment.text,
        startMs: segment.startMS,
        endMs: segment.endMS
      }))
    });
  }

  private writeMarkdown(writer: ArtifactWriter, platform: 'youtube' | 'podcast', doc: SourceOnlyTranscript): V2ArtifactRecord {
    const dir = transcriptRelativeDir(platform, doc.contentKey);
    return writer.save({
      kind: 'transcript',
      contents: encodeSourceOnlyMarkdown(doc),
      producer: 'transcript-installer',
      evidenceLevel: 'transcript',
      mediaType: 'text/markdown',
      relativePath: `${dir}/transcript.md`,
      contentKey: doc.contentKey,
      sourceURL: doc.source.canonicalURL
    });
  }
}
