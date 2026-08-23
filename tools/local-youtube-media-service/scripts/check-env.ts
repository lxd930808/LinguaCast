import { networkInterfaces } from 'node:os';
import { spawnSync } from 'node:child_process';

import { SERVICE_VERSION } from '../src/config.js';

function commandVersion(command: string): string | null {
  const result = spawnSync(command, ['-version'], { encoding: 'utf8' });
  if (result.error || result.status !== 0) return null;
  return (result.stdout || result.stderr).split('\n')[0]?.trim() ?? null;
}

function lanAddresses(): string[] {
  const nets = networkInterfaces();
  const out: string[] = [];
  for (const entries of Object.values(nets)) {
    for (const entry of entries ?? []) {
      if (entry.family === 'IPv4' && !entry.internal) out.push(entry.address);
    }
  }
  return out;
}

const nodeVersion = process.version;
const ffmpeg = commandVersion('ffmpeg');
const ffprobe = commandVersion('ffprobe');

console.log('local-youtube-media-service environment check');
console.log(`serviceVersion: ${SERVICE_VERSION}`);
console.log(`node: ${nodeVersion}`);
console.log(`ffmpeg: ${ffmpeg ?? 'MISSING'}`);
console.log(`ffprobe: ${ffprobe ?? 'MISSING'}`);
console.log(`cwd: ${process.cwd()}`);
console.log('lanIPv4:');
for (const ip of lanAddresses()) {
  console.log(`  - ${ip}`);
}

const locked = {
  'youtubei.js': '17.2.0',
  googlevideo: '4.1.1',
  'bgutils-js': '^3.2.0'
};
console.log('locked packages:');
for (const [name, version] of Object.entries(locked)) {
  console.log(`  - ${name}@${version}`);
}

if (!ffmpeg || !ffprobe) {
  console.error('FAIL: ffmpeg/ffprobe must be installed and on PATH');
  process.exit(1);
}

const major = Number(nodeVersion.slice(1).split('.')[0]);
if (!Number.isFinite(major) || major < 24) {
  console.error('FAIL: Node.js >= 24 required');
  process.exit(1);
}

console.log('OK');
