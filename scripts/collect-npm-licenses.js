#!/usr/bin/env node
// Regenerates the npm dependency table in THIRD_PARTY_LICENSES.md.
// Usage: node scripts/collect-npm-licenses.js [repoRoot]
// Requires `npm install` to have been run in each project below.
const fs = require('fs');
const path = require('path');

const projects = [
  'services/account-service',
  'services/content-pipeline',
  'services/research-assistant',
  'tools/local-youtube-media-service',
];

const repoRoot = process.argv[2] || process.cwd();
const results = new Map();

function readLicense(pkgJsonPath) {
  try {
    const data = JSON.parse(fs.readFileSync(pkgJsonPath, 'utf8'));
    let license = data.license;
    if (!license && Array.isArray(data.licenses)) {
      license = data.licenses.map((l) => l.type).join(' OR ');
    }
    if (license && typeof license === 'object' && license.type) license = license.type;
    return { name: data.name, version: data.version, license: license || 'UNKNOWN' };
  } catch {
    return null;
  }
}

function walk(nodeModulesDir, projectName) {
  if (!fs.existsSync(nodeModulesDir)) return;
  for (const entry of fs.readdirSync(nodeModulesDir)) {
    if (entry === '.bin' || entry === '.package-lock.json') continue;
    const full = path.join(nodeModulesDir, entry);
    if (!fs.statSync(full).isDirectory()) continue;
    if (entry.startsWith('@')) {
      for (const scoped of fs.readdirSync(full)) {
        record(path.join(full, scoped, 'package.json'), projectName);
      }
    } else {
      record(path.join(full, 'package.json'), projectName);
    }
  }
}

function record(pkgJson, projectName) {
  if (!fs.existsSync(pkgJson)) return;
  const info = readLicense(pkgJson);
  if (!info) return;
  const key = `${info.name}@${info.version}`;
  if (!results.has(key)) results.set(key, { ...info, projects: new Set() });
  results.get(key).projects.add(projectName);
}

for (const proj of projects) walk(path.join(repoRoot, proj, 'node_modules'), proj);

const sorted = [...results.values()].sort((a, b) => a.name.localeCompare(b.name));
const byLicense = new Map();
for (const item of sorted) {
  if (!byLicense.has(item.license)) byLicense.set(item.license, []);
  byLicense.get(item.license).push(item);
}

for (const lic of [...byLicense.keys()].sort()) {
  console.log(`\n### ${lic} (${byLicense.get(lic).length})`);
  for (const item of byLicense.get(lic)) console.log(`- ${item.name}@${item.version}`);
}
console.log(`\nTOTAL: ${sorted.length}`);
