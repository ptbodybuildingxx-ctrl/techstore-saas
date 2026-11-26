import {test} from 'node:test';
import assert from 'node:assert/strict';
import {verifyDomain} from '../recovery/domain-verifier.mjs';
const c={storeId:'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',id:'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',proof:'cccccccc-cccc-cccc-cccc-cccccccccccc',hostname:'shop.example.com',state:'pending'};
const record='techstore-verification='+c.proof;
const good=async x=>({...x,mappingVerified:true,tlsVerified:true,challengeVerified:true});
test('verifier requires exact DNS TXT, trusted hosting mapping, valid TLS, fresh challenge and successful activation',async()=>{
 let payload;const result=await verifyDomain(c,{resolveTxt:async name=>{assert.equal(name,'_techstore.shop.example.com');return [[record.slice(0,25),record.slice(25)]]},verifyHosting:good,activate:async x=>{payload=x;return true}});
 assert.equal(payload.p_store,c.storeId);assert.equal(payload.p_id,c.id);assert.equal(payload.p_host,c.hostname);assert.equal(payload.p_proof,c.proof);assert.match(payload.p_evidence,/^[a-f0-9]{64}$/);assert.equal(result.evidence,payload.p_evidence);
});
test('verifier fails closed without correct DNS, adapter, mapping, TLS or challenge',async()=>{
 let calls=0;const base={resolveTxt:async()=>[[record]],verifyHosting:good,activate:async()=>{calls++;return true}};
 for(const records of [[[record+'x']],[[record.slice(0,25)],[record.slice(25)]],[]])await assert.rejects(verifyDomain(c,{...base,resolveTxt:async()=>records}),/DNS proof/);
 for(const patch of [{hostname:'other.example.com'},{storeId:c.id},{nonce:c.id},{mappingVerified:false},{tlsVerified:false},{challengeVerified:false}])await assert.rejects(verifyDomain(c,{...base,verifyHosting:async x=>({...await good(x),...patch})}),/Hosting verification/);
 for(const patch of [{hostname:'x.github.io'},{hostname:'127.0.0.1'},{state:'disabled'},{proof:'bad'}])await assert.rejects(verifyDomain({...c,...patch},base),/Invalid pending domain/);
 await assert.rejects(verifyDomain(c,{...base,verifyHosting:undefined}),/adapter required/);
 assert.equal(calls,0);
 await assert.rejects(verifyDomain(c,{...base,activate:async()=>false}),/activation rejected/);
});
