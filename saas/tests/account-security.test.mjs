import {test} from 'node:test';import assert from 'node:assert/strict';
import {createAccountSecurity} from '../design/account-security.mjs';
import {fixtureUser,fixtureFactor,fixtureChallenge} from './auth-fixture.mjs';
test('administrator requires verified TOTP and cannot remove the final verified factor',async()=>{let factors=[],calls=[],token='before';const request=async(path,body,t,method)=>{calls.push({path,body,t,method});if(path==='/auth/v1/user')return {id:fixtureUser,factors};if(path.endsWith('/challenge'))return {id:fixtureChallenge};if(path.endsWith('/verify'))return {access_token:'after'};throw Error('Unexpected request')};const security=createAccountSecurity({request,token:()=>token,replaceSession:r=>{token=r.access_token},rpc:async()=>null,requireVerifiedFactor:true});await assert.rejects(security.authenticate(null,{required:true}),/enrollment/);factors=[{id:fixtureFactor,status:'verified',factor_type:'totp'}];await assert.rejects(security.authenticate(null,{required:true}),/TOTP required/);await security.authenticate(async()=>({id:fixtureFactor,code:'123456'}),{required:true});assert.equal(token,'after');assert.deepEqual(calls.at(-1).body,{challenge_id:fixtureChallenge,code:'123456'});await assert.rejects(security.remove(fixtureFactor),/replacement/);assert.ok(!calls.some(x=>x.method==='DELETE'))});
test('a session switch during verification does not replace the active token',async()=>{let token='before',replaced=false;const security=createAccountSecurity({request:async p=>{if(p.endsWith('/challenge'))return {id:fixtureChallenge};token='different';return {access_token:'unwanted'}},token:()=>token,replaceSession:()=>{replaced=true},rpc:async()=>null});await assert.rejects(security.verify(fixtureFactor,'123456'),/Session changed/);assert.equal(replaced,false)});

import {createAdminApi} from '../admin/api.mjs';
test('first factor setup never exposes an administrative session and requires verified enrollment',async()=>{
 const calls=[];let verified=false,existing=false;
 const api=createAdminApi({url:'https://mezsyzdieqmqulddcrtg.supabase.co',publishableKey:'sb_publishable_fixturefixturefixture',clock:()=>0,fetcher:async(u,o)=>{
  const path=new URL(u).pathname;calls.push(path);let result;
  if(path==='/auth/v1/token')result={access_token:'setup',expires_in:60};
  else if(path==='/auth/v1/user')result={id:fixtureUser,factors:existing||verified?[{id:fixtureFactor,status:'verified',factor_type:'totp'}]:[]};
  else if(path==='/auth/v1/factors')result={id:fixtureFactor,totp:{secret:'ABCDEFGHIJKLMNOP'}};
  else if(path.endsWith('/challenge'))result={id:fixtureChallenge};
  else if(path.endsWith('/verify')){verified=true;result={access_token:'verified',expires_in:60}}
  else if(path==='/auth/v1/logout')return {ok:true,status:204};
  else throw Error('Unexpected request '+path);
  return {ok:true,status:200,json:async()=>result};
 }});
 assert.equal(await api.enrollFirstTotp('king','fixture-password',async secret=>{assert.equal(secret,'ABCDEFGHIJKLMNOP');assert.equal(api.signedIn(),false);await assert.rejects(api.overview());await assert.rejects(api.signInUsername('king','fixture-password'),/Enrollment in progress/);return '123456'}),true);
 assert.equal(api.signedIn(),false);assert.equal(calls.at(-1),'/auth/v1/logout');assert.ok(!calls.some(x=>x.includes('/rest/')));
 existing=true;await assert.rejects(api.enrollFirstTotp('king','fixture-password',()=>{throw Error('Should not enroll')}),/already enrolled/);assert.equal(api.signedIn(),false);
});
