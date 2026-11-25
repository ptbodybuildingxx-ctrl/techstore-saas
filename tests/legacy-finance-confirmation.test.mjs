import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source=readFileSync(new URL('../modules/sync.js',import.meta.url),'utf8');
const start=source.indexOf('const tsPendingScopes=');
const stop=source.indexOf('const tsPendingLabels=',start);
assert.ok(start>=0&&stop>start);

test('standalone debt retries preserve the durable request ID after an uncertain response',async()=>{
 const rows=new Map(), calls=[];
 const harness=new Function('user','navigator','crypto','t',source.slice(start,stop)+'\nreturn {call:tsPendingCall,setMocks:(m)=>{tsPendingHash=m.hash;tsPendingClaim=m.claim;tsPendingClear=m.clear;tsPendingLock=m.lock}}');
 const mocks={hash:async args=>JSON.stringify(Object.fromEntries(Object.entries(args).filter(([k])=>k!=='request_id'))),
 claim:async(owner,scope,hash,id)=>{const key=owner+'|'+scope;const old=rows.get(key);if(old){if(old.hash!==hash)throw Error('different pending data');return {...old,fresh:false}}const row={key,hash,id};rows.set(key,row);return {...row,fresh:true}},
 clear:async row=>rows.delete(row.key),lock:async(_key,fn)=>fn()};
 let n=0;
 const create=()=>{const h=harness({id:'fixture-owner'},{onLine:true},{randomUUID:()=>String(++n)},(a,b)=>b);h.setMocks(mocks);return h};
 const payload={kind:'debts',id:'fixture-debt',amount:20};
 await assert.rejects(create().call('operation',payload,async(_p,b)=>{calls.push(b.request_id);throw Error('connection lost')}),/connection lost/);
 assert.equal(rows.size,1);
 await assert.rejects(create().call('operation',{...payload,amount:30},async()=>{throw Error('should not send')}),/different pending data/);
 const result=await create().call('operation',payload,async(_p,b)=>{calls.push(b.request_id);return {id:'fixture-debt',paid:20}});
 assert.equal(result.paid,20);assert.equal(calls[0],calls[1]);assert.equal(rows.size,0);
});
