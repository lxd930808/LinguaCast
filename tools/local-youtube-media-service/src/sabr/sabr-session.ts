import {
  Constants,
  ClientType,
  Innertube,
  Platform,
  UniversalCache,
  YTNodes,
  type Types
} from 'youtubei.js';
import { SabrStream, type SabrPlaybackOptions } from 'googlevideo/sabr-stream';
import { buildSabrFormat, EnabledTrackTypes } from 'googlevideo/utils';
import type { SabrFormat } from 'googlevideo/shared-types';
import type { ReloadPlaybackContext } from 'googlevideo/protos';

import {
  createResumableRangeStream,
  type DirectMediaResource,
  type DirectRangeDiagnostic
} from './resumable-range-stream.js';
import { generateWebPoToken } from './webpo-helper.js';

Platform.shim.eval = async (
  data: Types.BuildScriptResult,
  env: Record<string, Types.VMPrimative>
) => {
  const properties: string[] = [];
  if (env.n) {
    properties.push(`n: exportedVars.nFunction("${env.n}")`);
  }
  if (env.sig) {
    properties.push(`sig: exportedVars.sigFunction("${env.sig}")`);
  }
  const code = `${data.output}\nreturn { ${properties.join(', ')} }`;
  return new Function(code)();
};

export interface OpenSabrSessionOptions {
  videoId: string;
  preferredHeight: number;
  videoStartOffset?: number;
  audioStartOffset?: number;
  onDirectDiagnostic?: (
    diagnostic: DirectRangeDiagnostic & { track: 'video' | 'audio' }
  ) => void;
}

export interface OpenSabrSessionResult {
  transport: 'direct-range' | 'sabr';
  title: string;
  durationSeconds: number | null;
  videoStream: ReadableStream<Uint8Array>;
  audioStream: ReadableStream<Uint8Array>;
  selectedVideoFormat: SabrFormat;
  selectedAudioFormat: SabrFormat;
  videoMime: string | null;
  audioMime: string | null;
  videoCodec: string | null;
  audioCodec: string | null;
  videoHeight: number | null;
  adaptiveFormatCount: number;
  abort: () => void;
}

async function makePlayerRequest(
  innertube: Innertube,
  videoId: string,
  poToken?: string,
  reloadPlaybackContext?: ReloadPlaybackContext
): Promise<any> {
  const watchEndpoint = new YTNodes.NavigationEndpoint({
    watchEndpoint: { videoId }
  });

  const extraArgs: Record<string, unknown> = {
    playbackContext: {
      adPlaybackContext: { pyv: true },
      contentPlaybackContext: {
        vis: 0,
        splay: false,
        lactMilliseconds: '-1',
        signatureTimestamp: innertube.session.player?.signature_timestamp
      }
    },
    contentCheckOk: true,
    racyCheckOk: true,
  };

  if (poToken) {
    extraArgs.serviceIntegrityDimensions = { poToken };
  }

  if (reloadPlaybackContext) {
    (extraArgs.playbackContext as Record<string, unknown>).reloadPlaybackContext =
      reloadPlaybackContext;
  }

  return await watchEndpoint.call(innertube.actions, { ...extraArgs, parse: true });
}

/**
 * Fetch the player response with the same content-bound PO token that will be
 * sent in the subsequent SABR requests.
 */
export async function getPlayerInfoWithPoToken(
  innertube: Pick<Innertube, 'getBasicInfo'>,
  videoId: string,
  poToken: string
): Promise<Awaited<ReturnType<Innertube['getBasicInfo']>>> {
  return innertube.getBasicInfo(videoId, { po_token: poToken });
}

export interface SabrPoTokenBindings {
  /** Token sent in the /player serviceIntegrityDimensions payload. */
  playerPoToken: string;
  /** Session/visitor-bound token sent in SABR streamerContext. */
  streamPoToken: string;
}

export function resolveSabrClientType(raw?: string): ClientType {
  const normalized = raw?.trim().toUpperCase();
  const match = Object.entries(ClientType).find(
    ([key, value]) => key === normalized || value === raw?.trim()
  );
  return match?.[1] as ClientType | undefined ?? ClientType.ANDROID_VR;
}

function requiresWebPoToken(clientType: ClientType): boolean {
  return new Set<ClientType>([
    ClientType.WEB,
    ClientType.MWEB,
    ClientType.IOS,
    ClientType.ANDROID
  ]).has(clientType);
}

export async function generateSabrPoTokenBindings(
  videoId: string,
  visitorData: string,
  generateToken: (binding: string) => Promise<{ poToken: string }> =
    generateWebPoToken
): Promise<SabrPoTokenBindings> {
  if (!visitorData) {
    throw new Error('Could not get visitor data for SABR PO token');
  }

  // Keep these sequential because the BotGuard helper uses a shared DOM/VM
  // shim on Node.js.
  const playerToken = await generateToken(videoId);
  const streamToken = await generateToken(visitorData);

  return {
    playerPoToken: playerToken.poToken,
    streamPoToken: streamToken.poToken
  };
}

export function heightFromQualityLabel(label?: string | null): number | null {
  if (!label) return null;
  const match = label.match(/(\d{3,4})p/i);
  if (!match) return null;
  return Number.parseInt(match[1]!, 10);
}

export function codecFromMime(mimeType?: string | null): string | null {
  if (!mimeType) return null;
  const codecs = mimeType.match(/codecs="([^"]+)"/i)?.[1];
  return codecs ?? mimeType.split(';')[0]?.trim() ?? null;
}

function withoutXtags<T extends { xtags?: string }>(formats: T[]): T[] {
  const plain = formats.filter((format) => !format.xtags);
  return plain.length > 0 ? plain : formats;
}

function pickBestAvcVideo(
  formats: SabrFormat[],
  preferredHeight: number
): SabrFormat | undefined {
  const avc = withoutXtags(
    formats.filter(
      (format) =>
        !!format.mimeType?.includes('video') &&
        !!format.mimeType.includes('mp4') &&
        /avc1|avc3/.test(format.mimeType) &&
        !format.isDrc
    )
  );
  if (avc.length === 0) return undefined;

  const atOrBelow = avc.filter(
    (format) => (format.height ?? 0) > 0 && (format.height ?? 0) <= preferredHeight
  );
  const pool = atOrBelow.length > 0 ? atOrBelow : avc;
  return pool.sort((a, b) => {
    const heightDelta = (b.height ?? 0) - (a.height ?? 0);
    if (heightDelta !== 0) return heightDelta;
    return (b.bitrate || 0) - (a.bitrate || 0);
  })[0];
}

function pickBestAacAudio(formats: SabrFormat[]): SabrFormat | undefined {
  const aac = withoutXtags(
    formats.filter(
      (format) =>
        !!format.mimeType?.includes('audio') &&
        !!format.mimeType.includes('mp4') &&
        /mp4a|aac/.test(format.mimeType) &&
        !format.isDrc
    )
  );
  if (aac.length === 0) return undefined;
  return aac.sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0))[0];
}

type DirectFormat = Parameters<typeof buildSabrFormat>[0] & {
  url?: string;
};

function directMimeType(format: DirectFormat): string | null {
  return format.mime_type ?? format.mimeType ?? null;
}

/**
 * Selects an adaptive format whose URL can be fetched without SABR. Some
 * clients (notably ANDROID_VR at the time of writing) expose these URLs even
 * when the same video is SABR-only for TV/Web clients.
 */
export function pickDirectAvcVideo(
  formats: DirectFormat[],
  preferredHeight: number
): DirectFormat | undefined {
  const avc = withoutXtags(
    formats.filter((format) => {
      const mimeType = directMimeType(format);
      return (
        !!format.url &&
        !!mimeType?.includes('video') &&
        !!mimeType.includes('mp4') &&
        /avc1|avc3/.test(mimeType) &&
        !format.is_drc &&
        !format.isDrc
      );
    })
  );
  if (avc.length === 0) return undefined;

  const atOrBelow = avc.filter(
    (format) => (format.height ?? 0) > 0 && (format.height ?? 0) <= preferredHeight
  );
  const pool = atOrBelow.length > 0 ? atOrBelow : avc;
  return pool.sort((a, b) => {
    const heightDelta = (b.height ?? 0) - (a.height ?? 0);
    if (heightDelta !== 0) return heightDelta;
    return (b.bitrate || 0) - (a.bitrate || 0);
  })[0];
}

export function pickDirectAacAudio(formats: DirectFormat[]): DirectFormat | undefined {
  const aac = withoutXtags(
    formats.filter((format) => {
      const mimeType = directMimeType(format);
      return (
        !!format.url &&
        !!mimeType?.includes('audio') &&
        !!mimeType.includes('mp4') &&
        /mp4a|aac/.test(mimeType) &&
        !format.is_drc &&
        !format.isDrc
      );
    })
  );
  if (aac.length === 0) return undefined;
  return aac.sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0))[0];
}

function directMediaResource(
  format: DirectFormat,
  label: 'video' | 'audio'
): DirectMediaResource {
  if (!format.url) {
    throw Object.assign(new Error(`Direct ${label} URL is missing`), {
      code: 'SABR_REQUEST_FAILED'
    });
  }
  const built = buildSabrFormat(format);
  const contentLength = Number(built.contentLength || 0);
  if (!Number.isSafeInteger(contentLength) || contentLength <= 0) {
    throw Object.assign(
      new Error(`Direct ${label} content length is unavailable`),
      { code: 'SABR_REQUEST_FAILED' }
    );
  }
  return {
    url: format.url,
    identity: {
      itag: built.itag,
      mimeType: built.mimeType ?? null,
      contentLength,
      lastModified: built.lastModified === '0' ? null : built.lastModified
    }
  };
}

async function refreshDirectMediaResource(
  innertube: Innertube,
  videoId: string,
  itag: number,
  label: 'video' | 'audio'
): Promise<DirectMediaResource> {
  const refreshed = await innertube.getBasicInfo(videoId);
  const playability = refreshed.playability_status?.status;
  if (playability && playability !== 'OK') {
    throw Object.assign(
      new Error(
        `Video unavailable while refreshing media URL: ${refreshed.playability_status?.reason ?? playability}`
      ),
      { code: 'VIDEO_UNAVAILABLE' }
    );
  }
  const candidate = (
    refreshed.streaming_data?.adaptive_formats ?? []
  ).find((format) => format.itag === itag) as DirectFormat | undefined;
  if (!candidate?.url) {
    throw Object.assign(
      new Error(`Direct ${label} itag ${itag} is unavailable after URL refresh`),
      { code: 'MEDIA_EXPIRED' }
    );
  }
  return directMediaResource(candidate, label);
}

function selectPlaybackOptions(preferredHeight: number): SabrPlaybackOptions {
  return {
    videoFormat: (formats) => pickBestAvcVideo(formats, preferredHeight),
    audioFormat: (formats) => pickBestAacAudio(formats),
    enabledTrackTypes: EnabledTrackTypes.VIDEO_AND_AUDIO,
    maxRetries: 12,
    stallDetectionMs: 45_000
  };
}

export function assertAvcAacOrThrow(
  videoCodec: string | null,
  audioCodec: string | null
): void {
  const videoOk = !!videoCodec && /avc1|avc3|h264/i.test(videoCodec);
  const audioOk = !!audioCodec && /mp4a|aac/i.test(audioCodec);
  if (!videoOk || !audioOk) {
    throw Object.assign(
      new Error(
        `UNSUPPORTED_CODEC: need H.264+AAC, got video=${videoCodec ?? 'none'} audio=${audioCodec ?? 'none'}`
      ),
      { code: 'UNSUPPORTED_CODEC' }
    );
  }
}

/**
 * Opens a SABR session and returns live audio/video ReadableStreams.
 * Caller owns draining both streams to completion (or aborting).
 */
export async function openSabrSession(
  options: OpenSabrSessionOptions
): Promise<OpenSabrSessionResult> {
  const clientType = resolveSabrClientType(process.env.YT_SABR_CLIENT);
  const innertube = await Innertube.create({
    cache: new UniversalCache(true),
    client_type: clientType
  });
  const poTokenBindings = requiresWebPoToken(clientType)
    ? await (async () => {
        const visitorData = innertube.session.context.client.visitorData;
        if (!visitorData) {
          throw Object.assign(new Error('SABR visitor data is unavailable'), {
            code: 'SABR_REQUEST_FAILED'
          });
        }
        return generateSabrPoTokenBindings(options.videoId, visitorData);
      })()
    : undefined;
  const playerResponse = poTokenBindings
    ? await getPlayerInfoWithPoToken(
        innertube,
        options.videoId,
        poTokenBindings.playerPoToken
    )
    : await innertube.getBasicInfo(options.videoId);
  console.info(`[sabr] client videoId=${options.videoId} client=${clientType}`);
  const playability = playerResponse.playability_status?.status;
  if (playability && playability !== 'OK') {
    throw Object.assign(
      new Error(
        `Video unavailable: ${playerResponse.playability_status?.reason ?? playability}`
      ),
      { code: 'VIDEO_UNAVAILABLE' }
    );
  }

  const title =
    playerResponse.basic_info?.title ||
    playerResponse.primary_info?.title?.toString?.() ||
    'Unknown Video';
  const durationSeconds = playerResponse.basic_info?.duration
    ? Number(playerResponse.basic_info.duration)
    : null;

  const adaptiveFormats = playerResponse.streaming_data?.adaptive_formats ?? [];
  const directFormats = adaptiveFormats as DirectFormat[];

  // Android VR currently exposes ordinary adaptive videoplayback URLs for
  // H.264/AAC. Downloading those tracks directly avoids the SABR attestation
  // challenge that blocks TV/Web clients after the first few segments.
  const directVideo = clientType === ClientType.ANDROID_VR
    ? pickDirectAvcVideo(directFormats, options.preferredHeight)
    : undefined;
  const directAudio = clientType === ClientType.ANDROID_VR
    ? pickDirectAacAudio(directFormats)
    : undefined;

  if (directVideo && directAudio) {
    const selectedVideoFormat = buildSabrFormat(directVideo);
    const selectedAudioFormat = buildSabrFormat(directAudio);
    const videoMime = selectedVideoFormat.mimeType ?? null;
    const audioMime = selectedAudioFormat.mimeType ?? null;
    const videoCodec = codecFromMime(videoMime);
    const audioCodec = codecFromMime(audioMime);
    assertAvcAacOrThrow(videoCodec, audioCodec);

    const abortController = new AbortController();
    const videoResource = directMediaResource(directVideo, 'video');
    const audioResource = directMediaResource(directAudio, 'audio');
    const directDiagnostic =
      (track: 'video' | 'audio') => (diagnostic: DirectRangeDiagnostic) => {
        if (diagnostic.kind !== 'chunk-complete') {
          console.warn(
            `[direct] ${diagnostic.kind} videoId=${options.videoId} track=${track} itag=${diagnostic.itag} range=${diagnostic.rangeStart}-${diagnostic.rangeEnd} attempt=${diagnostic.attempt} cause=${diagnostic.causeCode ?? diagnostic.httpStatus ?? 'unknown'}`
          );
        }
        options.onDirectDiagnostic?.({ ...diagnostic, track });
      };
    const videoStream = createResumableRangeStream({
      ...videoResource,
      startOffset: options.videoStartOffset,
      signal: abortController.signal,
      refreshResource: () =>
        refreshDirectMediaResource(
          innertube,
          options.videoId,
          videoResource.identity.itag,
          'video'
        ),
      onDiagnostic: directDiagnostic('video')
    });
    const audioStream = createResumableRangeStream({
      ...audioResource,
      startOffset: options.audioStartOffset,
      signal: abortController.signal,
      refreshResource: () =>
        refreshDirectMediaResource(
          innertube,
          options.videoId,
          audioResource.identity.itag,
          'audio'
        ),
      onDiagnostic: directDiagnostic('audio')
    });
    console.info(
      `[sabr] direct-range client videoId=${options.videoId} videoItag=${selectedVideoFormat.itag} audioItag=${selectedAudioFormat.itag} chunkMiB=10`
    );
    return {
      transport: 'direct-range',
      title,
      durationSeconds: Number.isFinite(durationSeconds) ? durationSeconds : null,
      videoStream,
      audioStream,
      selectedVideoFormat,
      selectedAudioFormat,
      videoMime,
      audioMime,
      videoCodec,
      audioCodec,
      videoHeight:
        selectedVideoFormat.height ??
        heightFromQualityLabel(selectedVideoFormat.qualityLabel),
      adaptiveFormatCount: adaptiveFormats.length,
      abort: () => abortController.abort()
    };
  }

  const serverAbrStreamingUrl = await innertube.session.player?.decipher(
    playerResponse.streaming_data?.server_abr_streaming_url
  );
  const videoPlaybackUstreamerConfig =
    playerResponse.player_config?.media_common_config
      ?.media_ustreamer_request_config?.video_playback_ustreamer_config;

  if (!serverAbrStreamingUrl) {
    throw Object.assign(new Error('serverAbrStreamingUrl not found'), {
      code: 'SABR_REQUEST_FAILED'
    });
  }
  if (!videoPlaybackUstreamerConfig) {
    throw Object.assign(new Error('ustreamerConfig not found'), {
      code: 'SABR_REQUEST_FAILED'
    });
  }

  const sabrFormats = adaptiveFormats.map(buildSabrFormat);
  const clientName =
    Constants.CLIENT_NAME_IDS[
      innertube.session.context.client.clientName as keyof typeof Constants.CLIENT_NAME_IDS
    ];

  const serverAbrStream = new SabrStream({
    formats: sabrFormats,
    serverAbrStreamingUrl,
    videoPlaybackUstreamerConfig,
    poToken: poTokenBindings?.streamPoToken,
    clientInfo: {
      clientName: clientName ? Number.parseInt(String(clientName), 10) : undefined,
      clientVersion: innertube.session.context.client.clientVersion
    }
  });

  serverAbrStream.on('streamProtectionStatusUpdate', (status) => {
    console.info(
      `[sabr] stream protection videoId=${options.videoId} status=${status.status}`
    );
  });

  serverAbrStream.on('reloadPlayerResponse', (reloadPlaybackContext) => {
    void (async () => {
      const refreshed = await makePlayerRequest(
        innertube,
        options.videoId,
        poTokenBindings?.playerPoToken,
        reloadPlaybackContext
      );
      const nextUrl = await innertube.session.player?.decipher(
        refreshed.streaming_data?.server_abr_streaming_url
      );
      const nextConfig =
        refreshed.player_config?.media_common_config?.media_ustreamer_request_config
          ?.video_playback_ustreamer_config;
      if (nextUrl && nextConfig) {
        serverAbrStream.setStreamingURL(nextUrl);
        serverAbrStream.setUstreamerConfig(nextConfig);
      }
    })().catch((error) => {
      const message = error instanceof Error ? error.message : String(error);
      console.warn(
        `[sabr] player reload failed videoId=${options.videoId} message=${message}`
      );
    });
  });

  let selectedFormats: { videoFormat: SabrFormat; audioFormat: SabrFormat };
  let videoStream: ReadableStream<Uint8Array>;
  let audioStream: ReadableStream<Uint8Array>;

  try {
    const started = await serverAbrStream.start(
      selectPlaybackOptions(options.preferredHeight)
    );
    selectedFormats = started.selectedFormats;
    videoStream = started.videoStream;
    audioStream = started.audioStream;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (/no suitable formats/i.test(message)) {
      throw Object.assign(new Error(`UNSUPPORTED_CODEC: ${message}`), {
        code: 'UNSUPPORTED_CODEC'
      });
    }
    if (/attestation required/i.test(message)) {
      throw Object.assign(
        new Error(`SABR_ATTESTATION_REQUIRED: ${message}`),
        { code: 'SABR_ATTESTATION_REQUIRED' }
      );
    }
    throw Object.assign(
      error instanceof Error ? error : new Error(String(error)),
      { code: 'SABR_REQUEST_FAILED' }
    );
  }

  const videoMime = selectedFormats.videoFormat.mimeType ?? null;
  const audioMime = selectedFormats.audioFormat.mimeType ?? null;
  const videoCodec = codecFromMime(videoMime);
  const audioCodec = codecFromMime(audioMime);
  assertAvcAacOrThrow(videoCodec, audioCodec);

  return {
    transport: 'sabr',
    title,
    durationSeconds: Number.isFinite(durationSeconds) ? durationSeconds : null,
    videoStream,
    audioStream,
    selectedVideoFormat: selectedFormats.videoFormat,
    selectedAudioFormat: selectedFormats.audioFormat,
    videoMime,
    audioMime,
    videoCodec,
    audioCodec,
    videoHeight:
      selectedFormats.videoFormat.height ??
      heightFromQualityLabel(selectedFormats.videoFormat.qualityLabel),
    adaptiveFormatCount: sabrFormats.length,
    abort: () => {
      try {
        serverAbrStream.abort();
      } catch {
        // ignore
      }
    }
  };
}
