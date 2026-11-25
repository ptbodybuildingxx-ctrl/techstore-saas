import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runInNewContext } from 'node:vm';
import { mkdtemp, readFile, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStore, validateConfig, configureAsset } from '../build-store.mjs';

const config={slug:'fixture-shop',supabaseUrl:'https://aaaaaaaaaaaaaaaaaaaa.supabase.co',publishableKey:'sb_publishable_fixturefixturefixture',storeOrigin:'https://fixture.example.com'};
test('requires an isolated project, dedicated HTTPS origin and publishable key',()=>{
 assert.equal(validateConfig(config).project,'aaaaaaaaaaaaaaaaaaaa');
 for(const patch of [
   {supabaseUrl:'https://jtjnbeywpfdtgohffanl.supabase.co'},
   {supabaseUrl:'https://aaaaaaaaaaaaaaaaaaaa.supabase.co/path'},
   {publishableKey:'sb_secret_fixturefixturefixture'},
   {storeOrigin:'https://owner.github.io'},
   {storeOrigin:'https://fixture.example.com/path'},
   {storeOrigin:'http://fixture.example.com'},
   {secret:'not allowed'}
 ]) assert.throws(()=>validateConfig({...config,...patch}));
});
test('rewrites client and rejects leaked source configuration',()=>{
 const output=configureAsset('supabase-client.js',"const base='https://unconfigured.invalid',key='UNCONFIGURED_PUBLISHABLE_KEY',storage='techstore-auth-v42';",config);
 assert.ok(output.includes(config.supabaseUrl));
 assert.ok(output.includes(config.publishableKey));
 assert.ok(output.includes('techstore-auth-aaaaaaaaaaaaaaaaaaaa'));
 assert.throws(()=>configureAsset('modules/example.js','jtjnbeywpfdtgohffanl',config));
});
test('creates a clean isolated web bundle and never overwrites a deployment',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'techstore-saas-'));
 try {
   const out=join(dir,'store');
   const result=await buildStore(config,out);
   assert.equal(result.origin,config.storeOrigin);
   const paths=await readdir(out);
   assert.ok(paths.includes('workspace.html'));
   assert.ok(!paths.includes('saas')&&!paths.includes('supabase')&&!paths.includes('server.mjs')&&!paths.includes('docs'));
   const client=await readFile(join(out,'supabase-client.js'),'utf8');
   const html=await readFile(join(out,'workspace.html'),'utf8');
   const worker=await readFile(join(out,'sw.js'),'utf8');
   const store=await readFile(join(out,'modules/store.js'),'utf8');
   const context={window:{},location:{hash:''},URLSearchParams,sessionStorage:{getItem:()=>null}};
   runInNewContext(client,context);
   assert.equal(context.window.tsCloud.projectOrigin,config.supabaseUrl);
   runInNewContext(store,context);
   const photo='catalog/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jpg';
   const expected=config.supabaseUrl+'/storage/v1/object/public/techstore-products/'+photo;
   assert.equal(context.tsStorePhotoUrl(photo),expected);
   assert.equal(context.tsStoreIsPhoto(expected),true);
   assert.equal(context.tsStoreIsPhoto('https://other.example.com/'+photo),false);
   assert.equal(context.tsStorePhotoUrl('../private.jpg'),'');
   assert.ok(client.includes(config.supabaseUrl)&&html.includes(config.supabaseUrl));
   assert.ok(worker.includes('techstore-v638-saas-aaaaaaaaaaaaaaaaaaaa'));
   assert.ok(!client.includes('jtjnbeywpfdtgohffanl'));
   await assert.rejects(buildStore(config,out),/EEXIST/);
 } finally { await rm(dir,{recursive:true,force:true}); }
});
