import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,copyFile,readFile,readdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
const root=fileURLToPath(new URL('../..',import.meta.url));
const assets=['saas/admin/admin.css','saas/admin/config.mjs','saas/storefront/api.mjs','saas/storefront/storefront.mjs','saas/storefront/push.mjs','saas/design/theme.mjs','saas/design/build-suggestions.mjs','saas/design/site.mjs'];
test('dedicated custom-domain build includes only storefront assets and requires verified host routing',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'ts-domain-build-'));
 try{
  for(const path of [...assets,'saas/storefront/index.html','saas/deploy/build-storefront.mjs']){const dest=join(dir,path);await mkdir(dirname(dest),{recursive:true});await copyFile(join(root,path),dest)}
  execFileSync(process.execPath,[join(dir,'saas/deploy/build-storefront.mjs')]);
  const out=join(dir,'dist-storefront');
  const files=(await readdir(out,{recursive:true,withFileTypes:true})).filter(x=>x.isFile()).map(x=>join(x.parentPath,x.name).slice(out.length+1)).sort();
  assert.deepEqual(files,[...assets,'index.html','robots.txt'].sort());
  const html=await readFile(join(out,'index.html'),'utf8');assert.match(html,/src="\/saas\/storefront\/storefront\.mjs"/);assert.match(html,/href="\/saas\/admin\/admin\.css"/);
  const cfg=await import(new URL('file://'+join(out,'saas/admin/config.mjs')).href);assert.equal(cfg.configuration.customDomainRouting,true);assert.equal(cfg.configuration.customerAuthEnabled,false);assert.equal(cfg.configuration.publicMediaEnabled,false);
  assert.throws(()=>execFileSync(process.execPath,[join(dir,'saas/deploy/build-storefront.mjs')],{stdio:'pipe'}));
 }finally{await rm(dir,{recursive:true,force:true})}
});
