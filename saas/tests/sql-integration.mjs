// Disposable PostgreSQL-only integration fixture. No Supabase project, real Auth account, or cloud credentials.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync,readdirSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
const id=process.env.SQL_TEST_CONTAINER;
assert(process.env.GITHUB_ACTIONS==='true'&&/^[a-f0-9]{64}$/.test(id??''),'Disposable CI service required');
const inspected=JSON.parse(execFileSync('docker',['inspect',id],{encoding:'utf8'}))[0];
assert(inspected.Config.Image==='postgres:17'&&!inspected.HostConfig.Binds?.length,'Unexpected CI service');
const root=fileURLToPath(new URL('../..',import.meta.url));
const run=(sql)=>execFileSync('docker',['exec','-i',id,'psql','-X','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-q'],{input:sql,stdio:['pipe','inherit','inherit']});
const apply=(path)=>{console.log('Applying '+path);run(readFileSync(root+path,'utf8'))};
apply('saas/tests/sql/ci-platform-fixture.sql');
for(const name of ['schema','admin-development','admin-setup','admin-contact','provisioning-entitlement','provisioning-revocation','release-planning','backup-coordination','billing-sandbox'])apply('saas/control-plane/'+name+'.sql');
const migrations=readdirSync(root+'saas/multi-tenant').filter(n=>/^\d{3}-[a-z0-9-]+\.sql$/.test(n)).sort();
assert(migrations.length>=42);
for(const [i,name] of migrations.entries()){assert.equal(Number(name.slice(0,3)),i+1);apply('saas/multi-tenant/'+name)}
apply('saas/tests/sql/free-grid-placement.sql');
apply('saas/tests/sql/integrated-commerce.sql');
run("DO $$ BEGIN IF EXISTS(SELECT 1 FROM tenant_private.workspaces) OR EXISTS(SELECT 1 FROM public.mt_sales) OR EXISTS(SELECT 1 FROM public.mt_indirect_tax_entries) OR EXISTS(SELECT 1 FROM auth.users) OR EXISTS(SELECT 1 FROM tenant_private.shared_recovery_requests) THEN RAISE EXCEPTION 'Fixture data not rolled back'; END IF; END $$;");
console.log('Fresh schema, integrated commerce, taxes, monitoring, design and rollback passed (synthetic Auth/Storage fixtures).');

// This file is called only after the rollback assertions, on the same disposable service.
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,mkdir,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomBytes} from 'node:crypto';
import {packRecovery,extractRecovery} from '../recovery/bundle.mjs';
const fixture=readFileSync(root+'saas/tests/sql/integrated-commerce.sql','utf8');
const rollbackMarker="reset role;raise exception using errcode='ZX001',message='rollback';";
assert.equal(fixture.split(rollbackMarker).length,2);
run(fixture.replace(rollbackMarker,"reset role;raise notice 'Disposable restore fixture retained';"));
const docker=(args,input)=>execFileSync('docker',['exec',...(input?['-i']:[]),id,...args],{input,maxBuffer:32000000});
const query=(db,sql)=>docker(['psql','-X','-U','postgres','-d',db,'-v','ON_ERROR_STOP=1','-Atq','-c',sql]).toString().trim();
const tables=JSON.parse(query('postgres',`select json_agg(format('%I.%I',schemaname,tablename) order by schemaname,tablename) from pg_tables where schemaname in ('public','tenant_private','saas_private','auth','storage')`));
assert(tables.length>40);
const snapshot=db=>Object.fromEntries(tables.map(t=>[t,query(db,`select count(*)||':'||md5(coalesce(string_agg(to_jsonb(x)::text,E'\\n' order by to_jsonb(x)::text),'')) from ${t} x`)]));
const before=snapshot('postgres');assert(!before['public.mt_sales'].startsWith('0:'));assert(!before['public.mt_indirect_tax_entries'].startsWith('0:'));assert(!before['auth.users'].startsWith('0:'));
const policies=db=>query(db,`select coalesce(json_agg(row_to_json(p) order by schemaname,tablename,policyname)::text,'[]') from pg_policies p where schemaname in ('public','tenant_private','saas_private','storage')`);
const op=JSON.parse(query('postgres',`select json_build_object('sub',u.id,'session_id',s.id,'aal','aal1','role','authenticated') from saas_private.operators o join auth.users u on u.id=o.user_id join auth.sessions s on s.user_id=u.id limit 1`));
const buyer=JSON.parse(query('postgres',`select json_build_object('sub',u.id,'session_id',s.id,'aal','aal1','role','authenticated') from auth.users u join auth.sessions s on s.user_id=u.id where u.email like '%-buyer@example.invalid' limit 1`));
const claims=x=>JSON.stringify(x).replaceAll("'","''");
const overview=x=>`set role authenticated; select set_config('request.jwt.claims','${claims(x)}',false); select public.mt_admin_operations_overview(array[]::uuid[])->'summary';`;
const dir=await mkdtemp(join(tmpdir(),'ts-full-restore-')),source=join(dir,'source'),bundle=join(dir,'bundle'),target=join(dir,'target'),key=randomBytes(32);
try{
 await mkdir(source);
 await writeFile(join(source,'database.dump'),docker(['pg_dump','-U','postgres','-Fc','postgres']));
 // Storage bytes are intentionally synthetic; metadata and policies are restored from the full fixture database.
 await writeFile(join(source,'config.json'),JSON.stringify({mode:'synthetic_full_schema',live_billing:false}));
 await writeFile(join(dir,'fixture-object'),randomBytes(4096));execFileSync('tar',['-cf',join(source,'storage.tar'),'-C',dir,'fixture-object']);
 await packRecovery({source,out:bundle,key,capturedAt:new Date().toISOString()});
 await extractRecovery({out:bundle,destination:target,key});
 query('postgres','CREATE DATABASE techstore_full_restore');
 docker(['pg_restore','-U','postgres','--exit-on-error','-d','techstore_full_restore'],await readFile(join(target,'database.dump')));
 assert.deepEqual(snapshot('techstore_full_restore'),before);assert.equal(policies('techstore_full_restore'),policies('postgres'));
 const restored=JSON.parse(query('techstore_full_restore',overview(op)).split('\n').at(-1));assert.equal(restored.shared,2);assert.equal(restored.paid,0);
 const deny=`set role authenticated; select set_config('request.jwt.claims','${claims(buyer)}',false); do $$begin begin perform public.mt_admin_operations_overview(array[]::uuid[]);raise exception 'Unauthorized monitoring access';exception when insufficient_privilege then null;end;end$$;`;
 query('techstore_full_restore',deny);
 await mkdir(join(dir,'restored-storage'));execFileSync('tar',['-xf',join(target,'storage.tar'),'-C',join(dir,'restored-storage')]);assert.deepEqual(await readFile(join(dir,'restored-storage','fixture-object')),await readFile(join(dir,'fixture-object')));
 assert.deepEqual(await readFile(join(target,'config.json')),await readFile(join(source,'config.json')));
 console.log('Full synthetic SaaS recovery verified: '+tables.length+' tables, row digests, policies, central access and archive bytes.');
 const execAsync=promisify(execFile),start=performance.now(),clients=8,iterations=10;
 const sql=`set role authenticated; select set_config('request.jwt.claims','${claims(op)}',false); do $$begin for i in 1..${iterations} loop if (public.mt_admin_operations_overview(array[]::uuid[])->'summary'->>'shared')::int <> 2 then raise exception 'Concurrent overview mismatch';end if;end loop;end$$;`;
 const results=await Promise.all(Array.from({length:clients},()=>execAsync('docker',['exec',id,'psql','-X','-U','postgres','-d','techstore_full_restore','-v','ON_ERROR_STOP=1','-Atq','-c',sql],{timeout:60000,maxBuffer:100000})));
 assert.equal(results.length,clients);
 assert.deepEqual(snapshot('techstore_full_restore'),before);
 console.log('Synthetic central load: '+clients+' concurrent connections, '+(clients*iterations)+' verified overview calls, '+Math.round(performance.now()-start)+' ms including connection and post-load digest verification. Not production capacity.');
}finally{await rm(dir,{recursive:true,force:true})}
