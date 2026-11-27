import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {packageWorker,sourcePaths} from './cloudflare-package.mjs';
import {createWorker} from './worker.mjs';
const root=fileURLToPath(new URL('../../',import.meta.url));
// Fail closed: the same command is used by Cloudflare Workers Builds on main.
const gate=JSON.parse(await readFile(join(root,'saas/deploy/release-gate.json'),'utf8'));
if(gate.state!=='approved')throw Error('Production deployment held: '+gate.reason);
const commit=execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim();
const sources=Object.fromEntries(await Promise.all(sourcePaths.map(async p=>[p,await readFile(join(root,p),'utf8')])));
const routing=await readFile(join(root,'saas/deploy/worker.mjs'),'utf8');
const bundle=packageWorker(sources,routing,commit);
if(!process.argv.includes('--skip-route-checks')){
const worker=createWorker(bundle.files,commit);
for(const [path,expected] of [['/',200],['/saas/admin/',200],['/saas/tenant/',200],['/shop/test-shop/',200],['/saas/storefront/',404],['/workspace.html',404],['/docs/preview.mjs',404]]){const res=await worker.fetch(new Request('https://platform.invalid'+path));if(res.status!==expected)throw Error('Route check failed '+path);if(res.headers.get('X-TechStore-Commit')!==commit)throw Error('Commit header missing');}
}
const out=join(root,'dist-cloudflare');await mkdir(out,{recursive:true});
for(const [name,source] of Object.entries(bundle.modules))await writeFile(join(out,name),source);
await writeFile(join(out,'wrangler.json'),JSON.stringify(bundle.config,null,2)+'\n');
console.log('Operational Cloudflare package: '+commit+'; '+Object.keys(bundle.files).length+' assets; '+(process.argv.includes('--skip-route-checks')?'route checks skipped by explicit release option':'7 route checks passed'));
