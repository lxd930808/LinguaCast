import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { Innertube } from 'youtubei.js';

import {
  assertAvcAacOrThrow,
  generateSabrPoTokenBindings,
  getPlayerInfoWithPoToken,
  pickDirectAacAudio,
  pickDirectAvcVideo,
  resolveSabrClientType
} from '../src/sabr/sabr-session.js';

describe('assertAvcAacOrThrow', () => {
  it('accepts H.264 + AAC', () => {
    assert.doesNotThrow(() => assertAvcAacOrThrow('avc1.640028', 'mp4a.40.2'));
  });

  it('rejects VP9 / Opus for the first-round AVPlayer path', () => {
    assert.throws(
      () => assertAvcAacOrThrow('vp9', 'opus'),
      (error: any) => error?.code === 'UNSUPPORTED_CODEC'
    );
  });

  it('passes the content-bound PO token to the player request', async () => {
    const calls: Array<{ videoId: string; options: unknown }> = [];
    const fakeInnertube = {
      getBasicInfo: async (videoId: string, options?: unknown) => {
        calls.push({ videoId, options });
        return undefined as never;
      }
    } as Pick<Innertube, 'getBasicInfo'>;

    await getPlayerInfoWithPoToken(fakeInnertube, 'QN9IaiOoxY8', 'po-token');

    assert.deepEqual(calls, [
      { videoId: 'QN9IaiOoxY8', options: { po_token: 'po-token' } }
    ]);
  });

  it('uses separate video-bound and session-bound PO tokens', async () => {
    const bindings: string[] = [];

    const result = await generateSabrPoTokenBindings(
      'QN9IaiOoxY8',
      'visitor-data',
      async (binding) => {
        bindings.push(binding);
        return { poToken: `${binding}-po-token` };
      }
    );

    assert.deepEqual(bindings, ['QN9IaiOoxY8', 'visitor-data']);
    assert.deepEqual(result, {
      playerPoToken: 'QN9IaiOoxY8-po-token',
      streamPoToken: 'visitor-data-po-token'
    });
  });

  it('selects direct H.264/AAC adaptive formats for the Android VR path', () => {
    const formats: any[] = [
      {
        itag: 137,
        url: 'https://example/video-1080',
        mime_type: 'video/mp4; codecs="avc1.640028"',
        height: 1080,
        bitrate: 4_000_000,
        last_modified_ms: '1',
        approx_duration_ms: 1
      },
      {
        itag: 248,
        url: 'https://example/video-vp9',
        mime_type: 'video/webm; codecs="vp9"',
        height: 1080,
        bitrate: 5_000_000,
        last_modified_ms: '1',
        approx_duration_ms: 1
      },
      {
        itag: 140,
        url: 'https://example/audio-128',
        mime_type: 'audio/mp4; codecs="mp4a.40.2"',
        bitrate: 128_000,
        last_modified_ms: '1',
        approx_duration_ms: 1
      }
    ];

    assert.equal(pickDirectAvcVideo(formats, 1080)?.itag, 137);
    assert.equal(pickDirectAacAudio(formats)?.itag, 140);
  });

  it('defaults to Android VR and accepts TV override', () => {
    assert.equal(resolveSabrClientType(undefined), 'ANDROID_VR');
    assert.equal(resolveSabrClientType('TV'), 'TVHTML5');
    assert.equal(resolveSabrClientType('ANDROID_VR'), 'ANDROID_VR');
    assert.equal(resolveSabrClientType('not-a-client'), 'ANDROID_VR');
  });
});
