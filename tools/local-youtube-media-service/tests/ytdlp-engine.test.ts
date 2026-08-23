import assert from 'node:assert/strict';
import test from 'node:test';

import {
  formatSelector,
  parseProgressLine
} from '../src/ytdlp/yt-dlp-engine.js';
import { mediaObjectKey } from '../src/ytdlp/r2-uploader.js';
import { mediaUrl, playbackForCurrentService } from '../src/jobs/job-model.js';

test('formatSelector prefers avc1 under height cap', () => {
  const selector = formatSelector(720);
  assert.match(selector, /height<=720/);
  assert.match(selector, /avc1/);
  assert.match(selector, /mp4a/);
});

test('parseProgressLine reads percent', () => {
  assert.equal(parseProgressLine('download: 12.5%'), 0.125);
  assert.equal(parseProgressLine('  99% of ~10MiB'), 0.99);
  assert.equal(parseProgressLine('no progress'), null);
});

test('mediaUrl can embed access_token for AVPlayer', () => {
  const url = mediaUrl('https://api.example', 'job1', 'output.mp4', 'secret');
  assert.equal(
    url,
    'https://api.example/media/job1/output.mp4?access_token=secret'
  );
});

test('playbackForCurrentService keeps remote R2 URLs', () => {
  const playback = playbackForCurrentService(
    {
      kind: 'mp4',
      url: 'https://account.r2.cloudflarestorage.com/bucket/key?X-Amz-Signature=abc',
      height: 720,
      videoCodec: 'h264',
      audioCodec: 'aac',
      durationSeconds: 10,
      itagVideo: null,
      itagAudio: null
    },
    'https://api.example',
    'job1',
    'secret'
  );
  assert.ok(playback);
  assert.match(playback!.url, /r2\.cloudflarestorage\.com/);
});

test('mediaObjectKey nests under prefix', () => {
  assert.equal(
    mediaObjectKey('yt-media', '01ABC', 'output.mp4'),
    'yt-media/01ABC/output.mp4'
  );
});
