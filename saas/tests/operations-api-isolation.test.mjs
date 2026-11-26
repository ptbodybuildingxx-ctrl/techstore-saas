import {test} from 'node:test';import assert from 'node:assert/strict';import {createTenantApi} from './auth-fixture.mjs';
const a='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',b='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',id='cccccccc-cccc-cccc-cccc-cccccccccccc';
test('operational API rejects out-of-scope procurement, staff and repair requests',async()=>{
 let result=id;const calls=[];const api=createTenantApi({url:'https://mezsyzdieqmqulddcrtg.supabase.co',publishableKey:'sb_publishable_fixturefixturefixture',clock:()=>0,fetcher:async(url,opts)=>{calls.push(url);return {ok:true,status:200,json:async()=>url.includes('/auth/v1/token')?{access_token:'fixture',expires_in:60}:url.endsWith('mt_my_stores')?[{id:a,name:'A',slug:'shop-a',role:'owner',can_write:true}]:result}}});
 await api.signIn('fixture@example.invalid','pass');await api.stores();
 const purchase={kind:'purchase',requestId:id,supplier:id,product:id,currency:'USD',units:3,cost:2000,paid:1000,note:'Fixture'};
 const before=calls.length;await assert.rejects(api.operation(b,purchase));assert.equal(calls.length,before);
 await assert.rejects(api.operation(a,{kind:'staff',requestId:id,user:id,role:'owner',active:true}));
 result=[{store_id:b,id}];await assert.rejects(api.operationsList(a,'repairs'));
});
