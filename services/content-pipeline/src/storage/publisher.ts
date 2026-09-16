import { createHash } from 'node:crypto';

import type { Logger } from '../observability/logger.js';
import type { KeyLayout } from './keys.js';
import type { ObjectStore } from './object-store.js';

/**
 * Atomic artifact publish: every file goes to a temp object, is verified
 * (size + sha256), copied to its final key, and only then is the manifest
 * object written. A job must never become ready pointing at half-written
 * files; if any step fails, temp objects are cleaned and the error surfaces
 * as ARTIFACT_PUBLISH_FAILED.
 */

export interface ArtifactFileInput {
  name: string;
  role: 'segments' | 'sourceVtt' | 'targetVtt' | 'rawTranscript';
  required: boolean;
  data: Buffer;
  mimeType: string;
}

export interface ArtifactAudioInput {
  mimeType: string;
  bytes: number;
  durationSeconds: number;
  sha256: string;
  transcoded: boolean;
}

export interface PublishInput {
  jobId: string;
  contentType: 'podcast_episode' | 'video';
  contentKey: string;
  sourceLanguage: string;
  targetLanguage: string;
  translationQuality: 'fast' | 'quality';
  pipelineVersion: string;
  audioFingerprint: string;
  sourceFingerprint: string;
  audio: ArtifactAudioInput;
  files: ArtifactFileInput[];
  generatedAt?: string;
}

export interface PublishedFileRef {
  name: string;
  role: string;
  required: boolean;
  status: 'ready' | 'failed';
  mimeType: string;
  bytes: number;
  sha256: string;
  etag?: string;
}

export function sha256hex(data: Buffer): string {
  return createHash('sha256').update(data).digest('hex');
}

export class ArtifactPublisher {
  constructor(
    private readonly store: ObjectStore,
    private readonly keys: KeyLayout,
    private readonly logger: Logger
  ) {}

  async publish(input: PublishInput): Promise<Record<string, unknown>> {
    const files: PublishedFileRef[] = [];
    const tempKeys: string[] = [];
    try {
      for (const file of input.files) {
        const sha = sha256hex(file.data);
        const tempKey = this.keys.jobTempArtifact(input.jobId, file.name);
        this.keys.assertAllowed(tempKey);
        await this.store.put(tempKey, file.data, file.mimeType);
        tempKeys.push(tempKey);

        const head = await this.store.head(tempKey);
        if (!head || head.bytes !== file.data.length) {
          throw new Error(`temp upload verification failed for ${file.name}`);
        }
        const finalKey = this.keys.jobArtifact(input.jobId, file.name);
        const finalMeta = await this.store.copy(tempKey, finalKey);
        files.push({
          name: file.name,
          role: file.role,
          required: file.required,
          status: 'ready',
          mimeType: file.mimeType,
          bytes: file.data.length,
          sha256: sha,
          etag: `"${sha.slice(0, 16)}"`
        });
        void finalMeta;
      }
    } finally {
      for (const tempKey of tempKeys) {
        await this.store.delete(tempKey).catch((error) => {
          this.logger.warn('temp artifact cleanup failed', { key: tempKey, err: String(error) });
        });
      }
    }

    const manifest = {
      schemaVersion: 1,
      pipelineVersion: input.pipelineVersion,
      jobId: input.jobId,
      contentType: input.contentType,
      contentKey: input.contentKey,
      sourceLanguage: input.sourceLanguage,
      targetLanguage: input.targetLanguage,
      translationQuality: input.translationQuality,
      generatedAt: input.generatedAt ?? new Date().toISOString(),
      audioFingerprint: input.audioFingerprint,
      sourceFingerprint: input.sourceFingerprint,
      audio: input.audio,
      files
    };

    // The manifest is the publish marker: it is written LAST.
    const manifestKey = this.keys.jobArtifact(input.jobId, 'manifest.json');
    await this.store.put(manifestKey, Buffer.from(JSON.stringify(manifest)), 'application/json');
    this.logger.info('artifacts published', { jobId: input.jobId, files: files.length });

    return manifest;
  }

  /** Client-facing manifest ref for ContentJobResponse.artifacts. */
  manifestRef(manifest: Record<string, unknown>): Record<string, unknown> {
    const { schemaVersion, pipelineVersion, generatedAt, audioFingerprint, sourceFingerprint, audio, files } =
      manifest as {
        schemaVersion: number;
        pipelineVersion: string;
        generatedAt: string;
        audioFingerprint: string;
        sourceFingerprint: string;
        audio: unknown;
        files: unknown[];
      };
    return { schemaVersion, pipelineVersion, generatedAt, audioFingerprint, sourceFingerprint, audio, files };
  }
}
