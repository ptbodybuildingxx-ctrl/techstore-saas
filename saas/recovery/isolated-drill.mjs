// Synthetic restore only, inside the disposable PostgreSQL CI service container.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomBytes} from 'node:crypto';
import {packRecovery,extractRecovery} from './bundle.mjs';
const id=process.env.RECOVERY_TEST_CONTAINER;
assert(process.env.GITHUB_ACTIONS==='true'&&/^[a-f0-9]{64}$/.test(id??''),'Use only the disposable CI service');
const inspected=JSON.parse(execFileSync('docker',['inspect',id],{encoding:'utf8'}))[0];
assert(inspected.Config.Image==='postgres:17'&&!inspected.HostConfig.Binds?.length,'Unexpected CI service');
const exec=(args,input)=>execFileSync('docker',['exec',...(input?['-i']:[]),id,...args],{input,maxBuffer:8000000});
const psql=(db,sql)=>exec(['psql','-X','-U','postgres','-d',db,'-v','ON_ERROR_STOP=1','-At','-c',sql]).toString().trim();
const dir=await mkdtemp(join(tmpdir(),'ts-pg-restore-')),source=join(dir,'source'),bundle=join(dir,'bundle'),destination=join(dir,'restored'),files=join(dir,'files'),restoredFiles=join(dir,'restored-files'),key=randomBytes(32);
try{
 await mkdir(source);await mkdir(files);await mkdir(restoredFiles);
 psql('postgres','CREATE DATABASE techstore_restore_fixture_source');
 psql('postgres','CREATE DATABASE techstore_restore_fixture_target');
 psql('postgres','CREATE ROLE techstore_restore_fixture_reader NOLOGIN');
 psql('techstore_restore_fixture_source',"CREATE TABLE sample(id int primary key, tenant text not null, amount bigint not null); INSERT INTO sample VALUES (1,'a',1250),(2,'b',750); ALTER TABLE sample ENABLE ROW LEVEL SECURITY; CREATE POLICY tenant_a ON sample FOR SELECT TO techstore_restore_fixture_reader USING(tenant='a'); GRANT SELECT ON sample TO techstore_restore_fixture_reader;");
 await writeFile(join(source,'database.dump'),exec(['pg_dump','-U','postgres','-Fc','techstore_restore_fixture_source']));
 await writeFile(join(files,'fixture.jpg'),randomBytes(4096));execFileSync('tar',['-cf',join(source,'storage.tar'),'-C',files,'fixture.jpg']);
 await writeFile(join(source,'config.json'),JSON.stringify({mode:'synthetic',live_billing:false}));
 await packRecovery({source,out:bundle,key,capturedAt:new Date().toISOString()});
 await extractRecovery({out:bundle,destination,key});
 exec(['pg_restore','-U','postgres','--exit-on-error','-d','techstore_restore_fixture_target'],await readFile(join(destination,'database.dump')));
 const original=psql('techstore_restore_fixture_source','SELECT json_agg(sample ORDER BY id) FROM sample');
 const recovered=psql('techstore_restore_fixture_target','SELECT json_agg(sample ORDER BY id) FROM sample');
 assert.equal(recovered,original);
 assert.equal(psql('techstore_restore_fixture_target',"SELECT relrowsecurity FROM pg_class WHERE oid='sample'::regclass"),'t');
 assert.equal(psql('techstore_restore_fixture_target',"SELECT count(*) FROM pg_policies WHERE tablename='sample' AND policyname='tenant_a'"),'1');
 assert.match(psql('techstore_restore_fixture_target',"SET ROLE techstore_restore_fixture_reader; SELECT count(*) FROM sample; RESET ROLE;"),/\b1\b/);
 execFileSync('tar',['-xf',join(destination,'storage.tar'),'-C',restoredFiles]);
 assert.deepEqual(await readFile(join(restoredFiles,'fixture.jpg')),await readFile(join(files,'fixture.jpg')));
 assert.deepEqual(await readFile(join(destination,'config.json')),await readFile(join(source,'config.json')));
 console.log('Isolated PostgreSQL restore passed: rows, RLS policy, restricted role, Storage archive and config. Synthetic only.');
}finally{await rm(dir,{recursive:true,force:true})}
