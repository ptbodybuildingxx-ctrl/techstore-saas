import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createAdminApi} from '../admin/api.mjs';
const url='https://mezsyzdieqmqulddcrtg.supabase.co',key='sb_publishable_fixturefixturefixture';
const overview={total:0,ready:0,suspended:0,active_subscriptions:0,matched:0,rows:[]};
const id='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
function fixture(){let calls=[],now=0,deny=false;const fetcher=async(u,o)=>{calls.push({u,o});if(deny)return {ok:false,status:403};if(u.includes('/auth/v1/token'))return {ok:true,status:200,json:async()=>({access_token:'fixture-token',expires_in:60})};if(u.includes('saas_admin_overview'))return {ok:true,status:200,json:async()=>overview};if(u.includes('saas_admin_register'))return {ok:true,status:200,json:async()=>id};return {ok:true,status:204}};return {api:createAdminApi({url,publishableKey:key,fetcher,clock:()=>now}),calls,expire:()=>{now=60000},deny:()=>{deny=true}}}
test('only the dedicated control project and a publishable key are accepted',()=>{assert.throws(()=>createAdminApi({url:'https://example.com',publishableKey:key}));assert.throws(()=>createAdminApi({url,publishableKey:'sb_secret_fixturefixturefixture'}))});
test('login verifies operator RPC and never sends password to REST RPC',async()=>{const {api,calls}=fixture();await api.signIn('a@example.invalid','pass');assert.equal(api.signedIn(),true);assert.equal(calls[1].o.headers.Authorization,'Bearer fixture-token');assert.equal(JSON.parse(calls[1].o.body).password,undefined)});
test('no session means no management request',async()=>{const {api,calls}=fixture();await assert.rejects(api.overview());assert.equal(calls.length,0)});
test('registration and trial are bounded and server-side',async()=>{const {api,calls}=fixture();await api.signIn('a@example.invalid','pass');await assert.rejects(api.register({name:'A',slug:'bad/path',plan:'basic'}));assert.equal(await api.register({name:'A',slug:'store-a',plan:'basic'}),id);await assert.rejects(api.manage(id,'trial',31));await api.manage(id,'trial',14);assert.deepEqual(JSON.parse(calls.at(-1).o.body),{p_store:id,p_action:'trial',p_days:14})});
test('permission denial and expiry invalidate session',async()=>{let f=fixture();await f.api.signIn('a@example.invalid','pass');f.deny();await assert.rejects(f.api.overview());assert.equal(f.api.signedIn(),false);f=fixture();await f.api.signIn('a@example.invalid','pass');f.expire();await assert.rejects(f.api.overview());assert.equal(f.api.signedIn(),false)});
test('logout clears local session',async()=>{const {api,calls}=fixture();await api.signIn('a@example.invalid','pass');await api.signOut();assert.equal(api.signedIn(),false);assert.match(calls.at(-1).u,/logout/)});

test('provisioning request uses only operator RPC and validates ids',async()=>{
 const calls=[];const fetcher=async(u,o)=>{calls.push({u,o});return {ok:true,status:200,json:async()=>u.includes('/auth/v1/token')?{access_token:'fixture-token',expires_in:60}:u.includes('saas_admin_overview')?overview:u.includes('saas_admin_provisioning_status')?[{id,queue:'queued',license:'unprovisioned_or_blocked'}]:id}};
 const api=createAdminApi({url,publishableKey:key,fetcher,clock:()=>0});await api.signIn('a@example.invalid','pass');
 await assert.rejects(api.provisioning('bad','request'));await assert.rejects(api.provisioning(id,'create-paid'));
 assert.equal(await api.provisioning(id,'request'),id);assert.deepEqual(JSON.parse(calls.at(-1).o.body),{p_store:id,p_action:'request'});
 assert.deepEqual(await api.provisioningStatus([id]),[{id,queue:'queued',license:'unprovisioned_or_blocked'}]);
 const before=calls.length;assert.deepEqual(await api.provisioningStatus([]),[]);assert.equal(calls.length,before);
});
test('provisioning status rejects mismatched or missing records',async()=>{
 const fetcher=async(u)=>({ok:true,status:200,json:async()=>u.includes('/auth/v1/token')?{access_token:'fixture-token',expires_in:60}:u.includes('saas_admin_overview')?overview:[]});
 const api=createAdminApi({url,publishableKey:key,fetcher,clock:()=>0});await api.signIn('a@example.invalid','pass');await assert.rejects(api.provisioningStatus([id]));
});

test('king username maps to the development alias and retains server authorization',async()=>{const {api,calls}=fixture();await assert.rejects(api.signInUsername('someone','pass'));assert.equal(calls.length,0);await api.signInUsername('king','pass');assert.equal(JSON.parse(calls[0].o.body).email,'king@techstore-admin.invalid');assert.equal(api.signedIn(),true)});
test('contact is optional, private and explicitly unverified',async()=>{const calls=[];const fetcher=async(u,o)=>{calls.push({u,o});return {ok:true,status:200,json:async()=>u.includes('/auth/v1/token')?{access_token:'fixture-token',expires_in:60}:u.includes('saas_admin_overview')?overview:{username:'king',contact_email:'user@example.com',verified:false}}};const api=createAdminApi({url,publishableKey:key,fetcher,clock:()=>0});await assert.rejects(api.contact());await api.signInUsername('king','pass');await assert.rejects(api.contact('x@a.invalid'));const r=await api.contact('user@example.com');assert.equal(r.verified,false);assert.equal(calls.at(-1).o.headers.Authorization,'Bearer fixture-token');assert.deepEqual(JSON.parse(calls.at(-1).o.body),{p_email:'user@example.com',p_write:true})});

test('central releases use validated immutable manifests and planning RPC only',async()=>{
 const calls=[];const manifest={version:'6.4.0',commit:'a'.repeat(40),bundle:'b'.repeat(64),migrations:'c'.repeat(64),rollback:'Restore verified backup'};
 const fetcher=async(u,o)=>{calls.push({u,o});return {ok:true,status:200,json:async()=>u.includes('/auth/v1/token')?{access_token:'fixture-token',expires_in:60}:u.includes('saas_admin_overview')?overview:u.includes('saas_admin_release_overview')?{releases:[],targets:[],eligible_stores:[]}:id}};
 const api=createAdminApi({url,publishableKey:key,fetcher,clock:()=>0});await assert.rejects(api.releases());await api.signIn('a@example.invalid','pass');
 await assert.rejects(api.registerRelease({...manifest,bundle:'bad'}));await assert.rejects(api.registerRelease({...manifest,rollback:''}));
 assert.equal(await api.registerRelease(manifest),id);assert.equal(JSON.parse(calls.at(-1).o.body).p_bundle,manifest.bundle);
 await assert.rejects(api.planRelease(id,id,'deploy'));assert.equal(await api.planRelease(id,id,'plan'),id);assert.deepEqual(JSON.parse(calls.at(-1).o.body),{p_release:id,p_store:id,p_action:'plan'});
 assert.deepEqual(await api.releases(),{releases:[],targets:[],eligible_stores:[]});
});
test('release overview rejects malformed server payload',async()=>{const fetcher=async(u)=>({ok:true,status:200,json:async()=>u.includes('/auth/v1/token')?{access_token:'fixture-token',expires_in:60}:u.includes('saas_admin_overview')?overview:{releases:[{version:'bad'}],targets:[],eligible_stores:[]}});const api=createAdminApi({url,publishableKey:key,fetcher,clock:()=>0});await api.signIn('a@example.invalid','pass');await assert.rejects(api.releases())});

test('backup requests and isolated restore drills validate inputs and use only operator RPC',async()=>{
 const calls=[];const data={stores:[{id,name:'Fixture',slug:'fixture',recent_backup_id:null}],backups:[],requests:[]};
 const fetcher=async(u,o)=>{calls.push({u,o});return {ok:true,status:200,json:async()=>u.includes('/auth/v1/token')?{access_token:'fixture-token',expires_in:60}:u.includes('saas_admin_overview')?overview:u.includes('saas_admin_backup_overview')?data:id}};
 const api=createAdminApi({url,publishableKey:key,fetcher,clock:()=>0});await assert.rejects(api.backups());await api.signIn('a@example.invalid','pass');assert.deepEqual(await api.backups(),data);
 await assert.rejects(api.backupRequest(id,'restore_drill','request'));await assert.rejects(api.backupRequest(id,'backup','request',id));await assert.rejects(api.backupRequest(id,'restore','request',id));
 assert.equal(await api.backupRequest(id,'restore_drill','request',id),id);assert.deepEqual(JSON.parse(calls.at(-1).o.body),{p_store:id,p_kind:'restore_drill',p_action:'request',p_backup:id});
});
test('backup overview rejects fabricated status payloads',async()=>{const fetcher=async(u)=>({ok:true,status:200,json:async()=>u.includes('/auth/v1/token')?{access_token:'fixture-token',expires_in:60}:u.includes('saas_admin_overview')?overview:{stores:[],backups:[{id,store_id:id,store_name:'Fixture',captured_at:'2026-01-01T00:00:00Z',status:'complete'}],requests:[]}});const api=createAdminApi({url,publishableKey:key,fetcher,clock:()=>0});await api.signIn('a@example.invalid','pass');await assert.rejects(api.backups())});

test('billing uses sandbox-only RPC and validates event identity',async()=>{
 const calls=[];const data={mode:'sandbox',month:'2026-11-01',stores:[],invoices:[]};
 const fetcher=async(u,o)=>{calls.push({u,o});return {ok:true,status:200,json:async()=>u.includes('/auth/v1/token')?{access_token:'fixture-token',expires_in:60}:u.includes('saas_admin_overview')?overview:u.includes('saas_admin_billing_overview')?data:id}};
 const api=createAdminApi({url,publishableKey:key,fetcher,clock:()=>0});await assert.rejects(api.billing());await api.signIn('a@example.invalid','pass');assert.deepEqual(await api.billing(),data);
 await assert.rejects(api.billingDraft(id,'2026-11-02'));await assert.rejects(api.billingSimulate(id,'charge',id));await assert.rejects(api.billingSimulate(id,'paid','bad'));
 assert.equal(await api.billingDraft(id,'2026-11-01'),id);assert.equal(await api.billingSimulate(id,'paid',id),id);assert.deepEqual(JSON.parse(calls.at(-1).o.body),{p_invoice:id,p_action:'paid',p_request:id});
});
test('reject live billing payloads in sandbox console',async()=>{const fetcher=async(u)=>({ok:true,status:200,json:async()=>u.includes('/auth/v1/token')?{access_token:'fixture-token',expires_in:60}:u.includes('saas_admin_overview')?overview:{mode:'live',month:'2026-11-01',stores:[],invoices:[]}});const api=createAdminApi({url,publishableKey:key,fetcher,clock:()=>0});await api.signIn('a@example.invalid','pass');await assert.rejects(api.billing())});

test('shared store registration binds a verified owner ID and uses shared RPC',async()=>{
 const calls=[];const fetcher=async(u,o)=>{calls.push({u,o});return {ok:true,status:200,json:async()=>u.includes('/auth/v1/token')?{access_token:'fixture-token',expires_in:60}:u.includes('saas_admin_overview')?overview:id}};
 const api=createAdminApi({url,publishableKey:key,fetcher,clock:()=>0});await api.signIn('a@example.invalid','pass');await assert.rejects(api.registerShared({name:'Shop',slug:'shop-a',plan:'basic',owner:'king'}));assert.equal(await api.registerShared({name:'Shop',slug:'shop-a',plan:'basic',owner:id}),id);assert.match(calls.at(-1).u,/mt_admin_create_store$/);assert.equal(JSON.parse(calls.at(-1).o.body).p_owner,id);
});
