import path from 'node:path';

import type { SabrFormat } from 'googlevideo/shared-types';

import {
  prepareResumeOffset,
  readDirectResumeManifest,
  resetDirectResume,
  resumeManifestMatches,
  writeDirectResumeManifest,
  type DirectResumeManifest,
  type DirectResumeTrack
} from './direct-resume.js';
import {
  DIRECT_RANGE_CHUNK_SIZE,
  type DirectRangeDiagnostic
} from './resumable-range-stream.js';
import {
  openSabrSession,
  type OpenSabrSessionResult
} from './sabr-session.js';
import {
  trackFilePath,
  writeTrackStream,
  type TrackWriteResult
} from './track-writer.js';

export interface SabrFetchOptions {
  videoId: string;
  preferredHeight: number;
  workDir: string;
  onProgress?: (info: {
    videoBytes: number;
    audioBytes: number;
    videoTarget?: number;
    audioTarget?: number;
  }) => void;
  onResolved?: (info: {
    transport: 'direct-range' | 'sabr';
    videoItag: number | null;
    audioItag: number | null;
    videoCodec: string | null;
    audioCodec: string | null;
    videoHeight: number | null;
    videoTarget?: number;
    audioTarget?: number;
    resumedVideoBytes: number;
    resumedAudioBytes: number;
  }) => void;
  onDiagnostic?: (
    diagnostic: DirectRangeDiagnostic & { track: 'video' | 'audio' }
  ) => void;
}

export interface SabrFetchResult {
  title: string;
  durationSeconds: number | null;
  video: TrackWriteResult;
  audio: TrackWriteResult;
  selectedVideoFormat: SabrFormat;
  selectedAudioFormat: SabrFormat;
  diagnostics: Record<string, unknown>;
}

function resumeTrack(
  kind: 'video' | 'audio',
  format: SabrFormat,
  mimeType: string | null,
  workDir: string
): DirectResumeTrack {
  const contentLength = Number(format.contentLength || 0);
  if (!Number.isSafeInteger(contentLength) || contentLength <= 0) {
    throw Object.assign(
      new Error(`Direct ${kind} content length is unavailable`),
      { code: 'MEDIA_DOWNLOAD_FAILED' }
    );
  }
  return {
    fileName: path.basename(trackFilePath(workDir, kind, mimeType)),
    itag: format.itag,
    mimeType,
    contentLength,
    lastModified: format.lastModified === '0' ? null : format.lastModified
  };
}

function resumeManifestForSession(
  videoId: string,
  workDir: string,
  session: OpenSabrSessionResult
): DirectResumeManifest {
  return {
    version: 1,
    videoId,
    video: resumeTrack(
      'video',
      session.selectedVideoFormat,
      session.videoMime,
      workDir
    ),
    audio: resumeTrack(
      'audio',
      session.selectedAudioFormat,
      session.audioMime,
      workDir
    )
  };
}

async function resumeOffsets(
  workDir: string,
  manifest: DirectResumeManifest | null
): Promise<{ video: number; audio: number }> {
  if (!manifest) return { video: 0, audio: 0 };
  const [video, audio] = await Promise.all([
    prepareResumeOffset({
      filePath: path.join(workDir, manifest.video.fileName),
      totalLength: manifest.video.contentLength,
      chunkSize: DIRECT_RANGE_CHUNK_SIZE
    }),
    prepareResumeOffset({
      filePath: path.join(workDir, manifest.audio.fileName),
      totalLength: manifest.audio.contentLength,
      chunkSize: DIRECT_RANGE_CHUNK_SIZE
    })
  ]);
  return { video, audio };
}

export function fetchSabrTracks(
  options: SabrFetchOptions
): Promise<SabrFetchResult> {
  return fetchSabrTracksAttempt(options, true);
}

async function fetchSabrTracksAttempt(
  options: SabrFetchOptions,
  allowIdentityRestart: boolean
): Promise<SabrFetchResult> {
  let savedManifest = await readDirectResumeManifest(options.workDir);
  let activeManifest: DirectResumeManifest | null = null;
  if (savedManifest && savedManifest.videoId !== options.videoId) {
    await resetDirectResume(options.workDir, [savedManifest]);
    savedManifest = null;
  }
  let offsets = await resumeOffsets(options.workDir, savedManifest);
  let lastDirectDiagnostic:
    | (DirectRangeDiagnostic & { track: 'video' | 'audio' })
    | undefined;
  const openSession = (start: { video: number; audio: number }) =>
    openSabrSession({
      videoId: options.videoId,
      preferredHeight: options.preferredHeight,
      videoStartOffset: start.video,
      audioStartOffset: start.audio,
      onDirectDiagnostic: (diagnostic) => {
        lastDirectDiagnostic = diagnostic;
        options.onDiagnostic?.(diagnostic);
      }
    });
  let session = await openSession(offsets);

  if (session.transport === 'direct-range') {
    let currentManifest = resumeManifestForSession(
      options.videoId,
      options.workDir,
      session
    );
    activeManifest = currentManifest;
    if (savedManifest && !resumeManifestMatches(savedManifest, currentManifest)) {
      session.abort();
      await resetDirectResume(options.workDir, [
        savedManifest,
        currentManifest
      ]);
      offsets = { video: 0, audio: 0 };
      savedManifest = null;
      session = await openSession(offsets);
      if (session.transport !== 'direct-range') {
        session.abort();
        throw Object.assign(
          new Error('Direct media transport changed while resuming'),
          { code: 'MEDIA_DOWNLOAD_FAILED' }
        );
      }
      currentManifest = resumeManifestForSession(
        options.videoId,
        options.workDir,
        session
      );
      activeManifest = currentManifest;
    }
    await writeDirectResumeManifest(options.workDir, currentManifest);
  } else if (savedManifest) {
    await resetDirectResume(options.workDir, [savedManifest]);
    offsets = { video: 0, audio: 0 };
  }

  let videoBytes = offsets.video;
  let audioBytes = offsets.audio;
  const videoTarget =
    Number(session.selectedVideoFormat.contentLength || 0) || undefined;
  const audioTarget =
    Number(session.selectedAudioFormat.contentLength || 0) || undefined;
  options.onResolved?.({
    transport: session.transport,
    videoItag: session.selectedVideoFormat.itag ?? null,
    audioItag: session.selectedAudioFormat.itag ?? null,
    videoCodec: session.videoCodec,
    audioCodec: session.audioCodec,
    videoHeight: session.videoHeight,
    videoTarget,
    audioTarget,
    resumedVideoBytes: offsets.video,
    resumedAudioBytes: offsets.audio
  });

  const report = () => {
    options.onProgress?.({
      videoBytes,
      audioBytes,
      videoTarget,
      audioTarget
    });
  };

  const tagTrackFailure =
    (track: 'video' | 'audio') =>
    async (error: unknown): Promise<never> => {
      const existingDiagnostics =
        error &&
        typeof error === 'object' &&
        'diagnostics' in error &&
        error.diagnostics &&
        typeof error.diagnostics === 'object'
          ? (error.diagnostics as Record<string, unknown>)
          : {};
      throw Object.assign(
        error instanceof Error ? error : new Error(String(error)),
        { diagnostics: { ...existingDiagnostics, track } }
      );
    };

  const videoWrite = writeTrackStream({
    workDir: options.workDir,
    kind: 'video',
    stream: session.videoStream,
    mimeType: session.videoMime,
    itag: session.selectedVideoFormat.itag ?? null,
    height: session.videoHeight,
    codec: session.videoCodec,
    startOffset: offsets.video,
    onBytes: (bytes) => {
      videoBytes = bytes;
      report();
    }
  }).catch(tagTrackFailure('video'));
  const audioWrite = writeTrackStream({
    workDir: options.workDir,
    kind: 'audio',
    stream: session.audioStream,
    mimeType: session.audioMime,
    itag: session.selectedAudioFormat.itag ?? null,
    height: null,
    codec: session.audioCodec,
    startOffset: offsets.audio,
    onBytes: (bytes) => {
      audioBytes = bytes;
      report();
    }
  }).catch(tagTrackFailure('audio'));
  let video: TrackWriteResult;
  let audio: TrackWriteResult;
  try {
    [video, audio] = await Promise.all([videoWrite, audioWrite]);
  } catch (error) {
    session.abort();
    await Promise.allSettled([videoWrite, audioWrite]);
    const message = error instanceof Error ? error.message : String(error);
    const existingCode =
      error && typeof error === 'object' && 'code' in error
        ? String(error.code)
        : undefined;
    const sourceDiagnostics =
      error &&
      typeof error === 'object' &&
      'diagnostics' in error &&
      error.diagnostics &&
      typeof error.diagnostics === 'object'
        ? (error.diagnostics as Record<string, unknown>)
        : {};
    const rangeNeedsRestart =
      existingCode === 'MEDIA_IDENTITY_CHANGED' ||
      sourceDiagnostics.httpStatus === 416;
    if (
      rangeNeedsRestart &&
      allowIdentityRestart &&
      session.transport === 'direct-range'
    ) {
      await resetDirectResume(options.workDir, [
        savedManifest,
        activeManifest
      ]);
      return fetchSabrTracksAttempt(options, false);
    }
    const code = /attestation required/i.test(message)
      ? 'SABR_ATTESTATION_REQUIRED'
      : existingCode === 'MEDIA_DOWNLOAD_FAILED' ||
          existingCode === 'MEDIA_IDENTITY_CHANGED' ||
          existingCode === 'MEDIA_EXPIRED'
        ? 'MEDIA_DOWNLOAD_FAILED'
        : session.transport === 'direct-range'
          ? 'MEDIA_DOWNLOAD_FAILED'
          : 'SABR_PARSE_FAILED';
    throw Object.assign(
      error instanceof Error ? error : new Error(String(error)),
      {
        code,
        diagnostics: {
          ...sourceDiagnostics,
          title: session.title,
          durationSeconds: session.durationSeconds,
          videoItag: session.selectedVideoFormat.itag ?? null,
          audioItag: session.selectedAudioFormat.itag ?? null,
          videoMime: session.videoMime,
          audioMime: session.audioMime,
          videoCodec: session.videoCodec,
          audioCodec: session.audioCodec,
          videoHeight: session.videoHeight,
          videoBytes,
          audioBytes,
          videoTarget,
          audioTarget,
          transport: session.transport,
          directFailure:
            sourceDiagnostics.rangeStart !== undefined
              ? sourceDiagnostics
              : lastDirectDiagnostic
        }
      }
    );
  }

  return {
    title: session.title,
    durationSeconds: session.durationSeconds,
    video,
    audio,
    selectedVideoFormat: session.selectedVideoFormat,
    selectedAudioFormat: session.selectedAudioFormat,
    diagnostics: {
      title: session.title,
      durationSeconds: session.durationSeconds,
      videoItag: session.selectedVideoFormat.itag ?? null,
      audioItag: session.selectedAudioFormat.itag ?? null,
      videoMime: session.videoMime,
      audioMime: session.audioMime,
      videoCodec: session.videoCodec,
      audioCodec: session.audioCodec,
      videoHeight: session.videoHeight,
      videoBytes: video.bytesWritten,
      audioBytes: audio.bytesWritten,
      adaptiveFormatCount: session.adaptiveFormatCount,
      transport: session.transport,
      resumedVideoBytes: offsets.video,
      resumedAudioBytes: offsets.audio
    }
  };
}
