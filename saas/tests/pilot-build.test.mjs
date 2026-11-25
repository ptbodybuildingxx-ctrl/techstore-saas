import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,copyFile,readFile,readdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
const root=fileURLToPath(new URL('../..',import.meta.url));
const assets=["saas/admin/index.html","saas/admin/admin.css","saas/admin/admin.mjs","saas/admin/api.mjs","saas/admin/config.mjs","saas/tenant/index.html","saas/tenant/tenant.mjs","saas/tenant/api.mjs","saas/tenant/operations.mjs","saas/storefront/index.html","saas/storefront/api.mjs","saas/storefront/storefront.mjs","saas/design/theme.mjs"];
test('pilot publish build excludes legacy application, SQL and non-allowlisted assets',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'ts-pilot-'));
 try{
  for(const path of [...assets,'saas/deploy/build-pilot.mjs']){const dst=join(dir,path);await mkdir(dirname(dst),{recursive:true});await copyFile(join(root,path),dst)}
  execFileSync(process.execPath,[join(dir,'saas/deploy/build-pilot.mjs')]);
  const out=join(dir,'dist-pilot');
  const files=(await readdir(out,{recursive:true,withFileTypes:true})).filter(x=>x.isFile()).map(x=>join(x.parentPath,x.name).slice(out.length+1)).sort();
  assert.deepEqual(files,[...assets,'index.html','robots.txt'].sort());
  assert.match(await readFile(join(out,'index.html'),'utf8'),/بيئة اختبار غير تجارية/);
  assert.match(await readFile(join(out,'saas/tenant/index.html'),'utf8'),/noindex,nofollow/);
  assert.throws(()=>execFileSync(process.execPath,[join(dir,'saas/deploy/build-pilot.mjs')],{stdio:'pipe'}));
 }finally{await rm(dir,{recursive:true,force:true})}
});
