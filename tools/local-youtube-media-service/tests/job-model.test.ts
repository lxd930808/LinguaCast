import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import {
  isValidVideoId,
  jobDedupeKey,
  isTerminalStatus,
  playbackForCurrentService
} from '../src/jobs/job-model.js';

describe('job-model', () => {
  it('accepts standard 11-char video ids', () => {
    assert.equal(isValidVideoId('jNQXAC9IVRw'), true);
    assert.equal(isValidVideoId('dQw4w9WgXcQ'), true);
  });

  it('rejects invalid video ids', () => {
    assert.equal(isValidVideoId(''), false);
    assert.equal(isValidVideoId('short'), false);
    assert.equal(isValidVideoId('too-long-id!!'), false);
    assert.equal(isValidVideoId('bad id!!!!'), false);
  });

  it('builds stable dedupe keys', () => {
    assert.equal(jobDedupeKey('abc', 'mp4', 1080), 'abc:mp4:1080');
  });

  it('recognizes terminal statuses', () => {
    assert.equal(isTerminalStatus('ready'), true);
    assert.equal(isTerminalStatus('failed'), true);
    assert.equal(isTerminalStatus('fetching'), false);
  });

  it('rebases legacy ready MP4 playback onto the current service URL', () => {
    const playback = playbackForCurrentService(
      {
        kind: 'mp4',
        url: 'http://192.168.1.20:3210/media/01ABC/output.mp4',
        audioUrl: 'http://192.168.1.20:3210/media/01ABC/audio.m4a',
        height: 1080,
        videoCodec: 'h264',
        audioCodec: 'aac',
        durationSeconds: 120,
        itagVideo: 137,
        itagAudio: 140
      },
      'http://192.0.2.10:3210/',
      '01ABC'
    );

    assert.equal(
      playback?.url,
      'http://192.0.2.10:3210/media/01ABC/output.mp4'
    );
    assert.equal(
      playback?.audioUrl,
      'http://192.0.2.10:3210/media/01ABC/audio.m4a'
    );
  });
});
