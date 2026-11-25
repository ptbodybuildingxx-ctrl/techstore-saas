import { readFile, readdir, mkdir, writeFile, lstat } from 'node:fs/promises';
import { resolve, dirname, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const originalProject = 'jtjnbeywpfdtgohffanl';
const sourceRoot = fileURLToPath(new URL('../', import.meta.url));
const placeholder = 'https://unconfigured.invalid';
const keyMarker = 'UNCONFIGURED_PUBLISHABLE_KEY';
export function validateConfig(config) {
  if (!config || typeof config !== 'object' || Array.isArray(config)) throw Error('Invalid config');
  if (Object.keys(config).some(k => !['slug','supabaseUrl','publishableKey','storeOrigin'].includes(k))) throw Error('Unexpected config field');
  const {slug,supabaseUrl,publishableKey,storeOrigin}=config;
  if (typeof slug !== 'string' || !/^[a-z][a-z0-9-]{2,39}$/.test(slug)) throw Error('Invalid store slug');
  if (typeof supabaseUrl !== 'string' || !/^https:\/\/[a-z0-9]{20}\.supabase\.co$/.test(supabaseUrl)) throw Error('Use a separate hosted Supabase project URL');
  const project = new URL(supabaseUrl).hostname.split('.')[0];
  if (project === originalProject) throw Error('Original shop project is forbidden');
  if (typeof publishableKey !== 'string' || !/^sb_publishable_[A-Za-z0-9_-]{20,200}$/.test(publishableKey)) throw Error('Only a publishable key is accepted');
  let origin; try { origin=new URL(storeOrigin); } catch { throw Error('Invalid store origin'); }
  if (origin.protocol !== 'https:' || origin.origin !== storeOrigin || !origin.hostname.includes('.') || origin.hostname.endsWith('.supabase.co') || origin.hostname.endsWith('.github.io') || origin.hostname==='localhost') throw Error('Use a dedicated HTTPS origin, not shared GitHub Pages');
  return {slug,supabaseUrl,publishableKey,storeOrigin,project};
}
export function configureAsset(path, content, config) {
  const {supabaseUrl,publishableKey,project}=validateConfig(config);
  if (path==='supabase-client.js') {
    if (!content.includes(placeholder) || !content.includes(keyMarker)) throw Error('Unconfigured client marker missing');
    content=content.replaceAll(placeholder,supabaseUrl).replaceAll(keyMarker,publishableKey).replaceAll('techstore-auth-v42','techstore-auth-'+project);
  } else if (path==='workspace.html') {
    if (!content.includes(placeholder)) throw Error('Unconfigured CSP marker missing');
    content=content.replaceAll(placeholder,supabaseUrl);
    // No local-demo entry in an isolated deployment.
    content=content.replace(/<title>.*?<\/title>/, '<title>TechStore | Cloud workspace</title>');
  } else if (path==='sw.js') {
    if (!content.includes('techstore-v638-saas-unconfigured')) throw Error('Unconfigured cache marker missing');
    content=content.replaceAll('techstore-v638-saas-unconfigured','techstore-v638-saas-'+project);
  } else if (path==='workspace.js') {
    content=content.replaceAll('href="./index.html?demo=1"','href="./workspace.html"');
  }
  if (content.includes(originalProject) || content.includes(keyMarker) || content.includes(placeholder)) throw Error('Unsafe source or unconfigured marker in '+path);
  return content;
}
export async function buildStore(config, output, root=sourceRoot) {
  const valid=validateConfig(config);
  const target=resolve(output), source=resolve(root);
  if (target===source || !relative(source,target).startsWith('..')) throw Error('Output must be outside the repository');
  const modules=await readdir(resolve(source,'modules'),{withFileTypes:true});
  const files=['workspace.html','workspace.css','workspace.js','supabase-client.js','sw.js','manifest.webmanifest','icon-192.png','icon-512.png',...modules.filter(x=>x.isFile()&&x.name.endsWith('.js')).map(x=>'modules/'+x.name)];
  const assets=new Map();
  for (const path of files) {
    const src=resolve(source,path);
    if (!(await lstat(src)).isFile()) throw Error('Non-regular asset '+path);
    assets.set(path,path.endsWith('.png')?await readFile(src):configureAsset(path,await readFile(src,'utf8'),config));
  }
  const html=assets.get('workspace.html'), sw=assets.get('sw.js');
  for (const path of [...html.matchAll(/<(?:script|link)\b[^>]*\b(?:src|href)="([^"]+)"/gi)].map(m=>m[1].replace(/^\.\//,'').split('?')[0])) {
    if (!assets.has(path)) throw Error('Missing workspace asset: '+path);
  }
  for (const match of (sw.match(/\bconst\s+FILES\s*=\s*\[([\s\S]*?)\]/)?.[1]||'').matchAll(/['"]([^'"]+)['"]/g)) {
    if (!assets.has(match[1].replace(/^\.\//,'').split('?')[0])) throw Error('Missing precache asset '+match[1]);
  }
  await mkdir(target); // Never overwrite an existing deployment.
  for (const [path,data] of assets) {
    await mkdir(dirname(resolve(target,path)),{recursive:true});
    await writeFile(resolve(target,path),data,{flag:'wx'});
  }
  await writeFile(resolve(target,'index.html'),'<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=workspace.html"><a href="workspace.html">TechStore</a>',{flag:'wx'});
  return {store:valid.slug,origin:valid.storeOrigin,assets:assets.size+1};
}
if (process.argv[1] && import.meta.url===pathToFileURL(resolve(process.argv[1])).href) {
  const [configPath,output]=process.argv.slice(2);
  if (!configPath||!output) throw Error('Usage: node saas/build-store.mjs /private/config.json /private/new-output');
  const result=await buildStore(JSON.parse(await readFile(configPath,'utf8')),output);
  console.log(JSON.stringify(result)); // Never print keys or config contents.
}
