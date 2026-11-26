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
