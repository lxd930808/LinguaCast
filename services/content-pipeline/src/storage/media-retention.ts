import { ObjectStoreError } from './object-store.js';
import type { VideoMediaTaskStore } from '../domain/video-media-task-store.js';
import type { ContentMediaStore } from '../domain/content-media-store.js';
import type { KeyLayout } from '../storage/keys.js';
import type { ObjectStore } from '../storage/object-store.js';
import type { RedactingLogger } from '../observability/logger.js';

export interface MediaRetentionOptions {
  mediaStore: ContentMediaStore;
  objects: ObjectStore;
  keys: KeyLayout;
  logger: RedactingLogger;
  intervalMs: number;
  batchSize: number;
  now?: () => number;
  mediaTasks?: VideoMediaTaskStore;
  cleanupCache?: () => Promise<void>;
  enabled?: () => boolean;
}

/**
 * Single-instance bounded cleanup: expired ready/invalid assets, then temp
 * leftovers. Never deletes objects still inside the sliding retain window.
 */
export class MediaRetentionWorker {
  private timer: NodeJS.Timeout | null = null;
  private running = false;

  constructor(private readonly options: MediaRetentionOptions) {}

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => void this.runOnce(), this.options.intervalMs);
    this.timer.unref?.();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  async runOnce(): Promise<number> {
    if (this.running || this.options.enabled?.() === false) return 0;
    this.running = true;
    const now = this.options.now?.() ?? Date.now();
    let cleaned = 0;
    try {
      const expired = this.options.mediaStore.expiredBatch(now, this.options.batchSize);
      for (const asset of expired) {
        if (this.options.mediaStore.hasActiveJobForContentId(asset.contentId) || this.options.mediaTasks?.active(asset.contentId)) continue;
        cleaned += await this.deleteAsset(asset.mediaId, asset.objectKey);
      }
      for (const asset of this.options.mediaStore.listByState('deleting', this.options.batchSize)) {
        if(this.options.mediaTasks?.active(asset.contentId)) continue;
        cleaned += await this.deleteAsset(asset.mediaId, asset.objectKey);
      }
      for (const asset of this.options.mediaStore.listByState('promoting', this.options.batchSize)) {
        const age = now - asset.updatedAt;
        if (age < 6 * 3_600_000) continue;
        if (this.options.mediaStore.hasActiveJobForContentId(asset.contentId) || this.options.mediaTasks?.active(asset.contentId)) continue;
        if (asset.objectKey) {
          const head = await this.options.objects.head(asset.objectKey);
          if (head) continue;
        }
        this.options.mediaStore.markInvalid(asset.mediaId, 'MEDIA_INTEGRITY_FAILED', now);
      }
      for (const asset of this.options.mediaStore.listByState('ready', this.options.batchSize)) {
        if (!asset.objectKey) {
          this.options.mediaStore.markInvalid(asset.mediaId, 'MEDIA_INTEGRITY_FAILED', now);
          continue;
        }
        const head = await this.options.objects.head(asset.objectKey);
        if (!head) this.options.mediaStore.markInvalid(asset.mediaId, 'MEDIA_INTEGRITY_FAILED', now);
      }
      await this.options.cleanupCache?.();
    } catch (error) {
      this.options.logger.warn('media_cleanup', {
        result: 'error',
        error: error instanceof Error ? error.message : String(error)
      });
    } finally {
      this.running = false;
    }
    if (cleaned > 0) {
      this.options.logger.info('media_cleanup', { result: 'cleaned', count: cleaned });
    }
    return cleaned;
  }

  private async deleteAsset(mediaId: string, objectKey: string | null): Promise<number> {
    this.options.mediaStore.markDeleting(mediaId);
    if (objectKey) {
      try {
        this.options.keys.assertAllowed(objectKey);
        await this.options.objects.delete(objectKey);
      } catch (error) {
        if (!(error instanceof ObjectStoreError && error.code === 'NOT_FOUND')) return 0;
      }
    }
    this.options.mediaStore.deleteRecord(mediaId);
    return 1;
  }
}
