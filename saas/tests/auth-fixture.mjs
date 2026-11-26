import assert from 'node:assert/strict';
import {createAdminApi as admin} from '../admin/api.mjs';
import {createTenantApi as tenant} from '../tenant/api.mjs';
import {createStorefrontApi as storefront} from '../storefront/api.mjs';
export const fixtureUser='11111111-1111-1111-1111-111111111111',fixtureFactor='22222222-2222-2222-2222-222222222222',fixtureChallenge='33333333-3333-3333-3333-333333333333';
const response=value=>({ok:true,status:200,json:async()=>value});
export function authFixture(fetcher,{mfa=false,observe=()=>{}}={}){
 let challenged=false;
 return async(url,options)=>{
  const path=new URL(url).pathname;
  if(path==='/auth/v1/user'&&options.method==='GET'){
   assert.match(options.headers.Authorization,/^Bearer .+$/);observe(path);return response({id:fixtureUser,factors:mfa?[{id:fixtureFactor,status:'verified',factor_type:'totp',friendly_name:'Fixture TOTP'}]:[]});
  }
  if(path==='/auth/v1/factors/'+fixtureFactor+'/challenge'){
   assert.ok(mfa);assert.equal(options.method,'POST');assert.match(options.headers.Authorization,/^Bearer .+$/);challenged=true;observe(path);return response({id:fixtureChallenge});
  }
  if(path==='/auth/v1/factors/'+fixtureFactor+'/verify'){
   assert.ok(mfa&&challenged);assert.equal(options.method,'POST');assert.deepEqual(JSON.parse(options.body),{challenge_id:fixtureChallenge,code:'123456'});challenged=false;observe(path);return response({access_token:options.headers.Authorization.slice(7),expires_in:60});
  }
  return fetcher(url,options);
 };
}
export const fixtureTotp=async factors=>{assert.equal(factors.length,1);assert.equal(factors[0].id,fixtureFactor);return {id:fixtureFactor,code:'123456'}};
const config=(cfg,mfa)=>cfg.fetcher?{...cfg,fetcher:authFixture(cfg.fetcher,{mfa})}:cfg;
export const createAdminApi=cfg=>admin(config(cfg,true));
export const createTenantApi=cfg=>tenant(config(cfg,false));
export const createStorefrontApi=cfg=>storefront(config(cfg,false));
