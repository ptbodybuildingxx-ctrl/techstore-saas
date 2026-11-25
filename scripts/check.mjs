import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = (file) => readFileSync(resolve(root, file), 'utf8');
const errors = [];
const check = (condition, message) => { if (!condition) errors.push(message); };
const isScript = (file) => /\.(?:js|mjs|cjs)$/.test(file);

function scriptsIn(dir, recursive = false) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = resolve(dir, entry.name);
    if (entry.isDirectory() && recursive) return scriptsIn(path, true);
    return entry.isFile() && isScript(entry.name) ? [path] : [];
  });
}

const scripts = [
  ...scriptsIn(root),
  ...['modules', 'scripts', 'tests'].flatMap((dir) => scriptsIn(resolve(root, dir), true)),
].sort();
for (const file of scripts) {
  const result = spawnSync(process.execPath, ['--check', file], { encoding: 'utf8' });
  if (result.status !== 0) errors.push(relative(root, file) + ': ' + (result.stderr || result.error || 'syntax check failed'));
}

const { version } = JSON.parse(read('package.json'));
const tag = version.replaceAll('.', '');
const html = read('workspace.html');
const worker = read('sw.js');
const assets = [...html.matchAll(/<(?:script|link)\b[^>]*\b(?:src|href)="([^"#]+)"[^>]*>/gi)]
  .map((match) => match[1]).filter((url) => !/^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(url));
const cached = [...(worker.match(/\bconst\s+FILES\s*=\s*\[([\s\S]*?)\]/)?.[1] || '').matchAll(/['"]([^'"]+)['"]/g)]
  .map((match) => match[1]);
const normalize = (url) => url.replace(/^\.\//, '');
const cacheSet = new Set(cached.map(normalize));
const jsAssets = assets.filter((url) => /\.js(?:\?|$)/.test(url));
check(html.includes('TechStore ' + version), 'Workspace version does not match package.json');
check(new RegExp('\\bconst\\s+CACHE\\s*=\\s*[\'"]techstore-v' + tag + '(?:-|[\'"])').test(worker), 'Service worker cache version is stale');
check(cached.length > 0 && cacheSet.size === cached.length, 'Missing or duplicate service worker cache entries');
check(jsAssets.length > 0 && new Set(jsAssets.map(normalize)).size === jsAssets.length, 'Missing or duplicate workspace scripts');
check(normalize(jsAssets[0] || '').split('?')[0] === 'supabase-client.js', 'Supabase client must load before workspace modules');
check(normalize(jsAssets.at(-1) || '').split('?')[0] === 'workspace.js', 'Workspace entry point must load last');
for (const asset of assets) {
  const file = normalize(asset).split('?')[0];
  check(existsSync(resolve(root, file)), 'Missing workspace asset: ' + file);
  check(cacheSet.has(normalize(asset)), 'Workspace asset is not precached: ' + asset);
  if (/\.(?:js|css)$/.test(file)) check(new URLSearchParams(asset.split('?')[1] || '').get('v') === tag, 'Stale version: ' + asset);
}
for (const asset of cached) check(existsSync(resolve(root, normalize(asset).split('?')[0])), 'Missing precache file: ' + asset);

if (errors.length) {
  console.error(errors.join('\n'));
  process.exitCode = 1;
} else {
  console.log('Checked ' + scripts.length + ' JavaScript files and ' + assets.length + ' workspace assets (v' + version + ').');
}
