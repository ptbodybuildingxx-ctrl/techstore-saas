import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const read=p=>readFileSync(new URL('../'+p,import.meta.url),'utf8');
test('workspace reads use protected RPC; legacy writes retain existing route',async()=>{
 const calls=[],ctx={window:{},location:{hash:'',pathname:'/workspace.html',search:''},history:{replaceState(){}},sessionStorage:{getItem:k=>k==='techstore-auth-v42'?JSON.stringify({access_token:'fixture-only',refresh_token:'fixture-only',expires_at:9999999999}):null,setItem(){},removeItem(){}},fetch:async(url,o)=>{calls.push({url,method:o.method,body:o.body});return {ok:true,status:200,json:async()=>url.includes('ts_mfa_settings')?{required:false,elevated:false}:url.includes('ts_read_workspace')?{fixture:true}:[]}},URLSearchParams,Date};
 const api=new Function(...Object.keys(ctx),read('supabase-client.js')+'\nreturn window.tsCloud.api')(...Object.values(ctx));
 for(const p of ['me','stock','customers','account','records/orders']){await api(p);assert.ok(calls.at(-1).url.endsWith('/rest/v1/rpc/ts_read_workspace'));assert.equal(JSON.parse(calls.at(-1).body).p_path,p)}
 await api('records',{kind:'suppliers',name:'Fixture'});assert.ok(calls.at(-1).url.includes('techstore-api'));
 assert.ok(read('modules/staff.js').includes('orders_read'));
});