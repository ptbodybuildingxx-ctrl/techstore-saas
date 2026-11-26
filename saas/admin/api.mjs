import {validCentralDenials} from '../tenant/staff-permissions.mjs';
import {validateBillingPage,validateBillingDetails} from '../design/commercial-billing.mjs';
import {createAccountSecurity} from '../design/account-security.mjs';
import {validateTheme,designResponse} from '../design/theme.mjs';
const allowedOrigin='https://mezsyzdieqmqulddcrtg.supabase.co';
const states=['','provisioning','ready','suspended','closed'];
const validPlan=x=>typeof x==='string'&&/^[a-z][a-z0-9-]{2,39}$/.test(x);
const moduleKeys=['catalog','sales','purchases','suppliers','customers','credit','standalone_debts','repairs','quotes','stock_counts','stock_transfers','branches','payroll','tradein','coupons'];
const moduleFlags=x=>x&&typeof x==='object'&&Object.keys(x).length===moduleKeys.length&&moduleKeys.every(k=>typeof x[k]==='boolean');
const validRef=x=>typeof x==='string'&&uuid.test(x);const count=x=>Number.isSafeInteger(x)&&x>=0;
const actions=['trial','suspend','cancel','reopen'];
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
export function createAdminApi({url,publishableKey,fetcher=fetch,clock=Date.now}) {
 if(url!==allowedOrigin||typeof publishableKey!=='string'||!/^sb_publishable_[A-Za-z0-9_-]{20,200}$/.test(publishableKey)) throw Error('Invalid control-plane configuration');
 let session=null,setupBusy=false;
 async function request(path,body,token,method='POST') {
  const res=await fetcher(url+path,{method,headers:{apikey:publishableKey,'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:body===undefined?undefined:JSON.stringify(body),cache:'no-store',redirect:'error',credentials:'omit'});
  if(!res.ok){const e=Error(res.status===401||res.status===403?'Access denied':res.status===409?'Store identifier already exists':'Request failed');e.status=res.status;throw e}
  if(res.status===204)return null;
  return res.json();
 }
 function token(){if(!session||session.expiresAt<=clock()+5000){session=null;throw Error('Sign in again')}return session.accessToken}
 async function rpc(name,args){try{return await request('/rest/v1/rpc/'+name,args,token())}catch(e){if(e.status===401||e.status===403)session=null;throw e}}
 const replaceSession=s=>{if(typeof s?.access_token!=='string'||!s.access_token||!Number.isFinite(s.expires_in)||s.expires_in<=0)throw Error('Invalid session');session={accessToken:s.access_token,expiresAt:clock()+s.expires_in*1000}};
 // Enrollment is optional; the server remains authoritative for operator MFA policy.
 const security=createAccountSecurity({request,token,replaceSession,rpc,requireVerifiedFactor:false});
 return {
  security,
  async signInUsername(username,password,codeProvider){
   if(typeof username!=='string'||username.trim().toLowerCase()!=='king')throw Error('Invalid username');
   return this.signIn('king@techstore-admin.invalid',password,codeProvider);
  },
  // Password-authenticated first-factor enrollment has a separate ephemeral Auth session.
  // Never publish the token to the administrative RPC adapter or open the dashboard.
  async enrollFirstTotp(username,password,codeProvider){
   if(setupBusy||session||typeof username!=='string'||username.trim().toLowerCase()!=='king'||typeof password!=='string'||!password||typeof codeProvider!=='function')throw Error('Initial enrollment unavailable');
   setupBusy=true;let temporary=null,pending=null,verificationStarted=false;
   const update=s=>{if(typeof s?.access_token!=='string'||!s.access_token||!Number.isFinite(s.expires_in)||s.expires_in<=0)throw Error('Invalid enrollment session');temporary={accessToken:s.access_token,expiresAt:clock()+s.expires_in*1000}};
   const temporaryToken=()=>{if(!temporary||temporary.expiresAt<=clock()+5000)throw Error('Enrollment session expired');return temporary.accessToken};
   const enrollment=createAccountSecurity({request,token:temporaryToken,replaceSession:update,rpc:async()=>{throw Error('Administrative RPC denied during enrollment')},requireVerifiedFactor:true});
   try{
    update(await request('/auth/v1/token?grant_type=password',{email:'king@techstore-admin.invalid',password}));
    if((await enrollment.factors()).some(x=>x.status==='verified'))throw Error('Authenticator already enrolled');
    pending=await enrollment.enroll();
    const code=await codeProvider(pending.secret);
    if(code===null||code===undefined)return false;
    if(typeof code!=='string'||!/^\d{6}$/.test(code))throw Error('Invalid TOTP');
    verificationStarted=true;
    await enrollment.verify(pending.id,code);
    if(!(await enrollment.factors()).some(x=>x.id===pending.id&&x.status==='verified'))throw Error('Enrollment not confirmed');
    return true;
   }finally{
    if(pending&&!verificationStarted)try{await enrollment.remove(pending.id)}catch{}
    const old=temporary;temporary=null;
    try{if(old)await request('/auth/v1/logout?scope=local',undefined,old.accessToken)}finally{setupBusy=false}
   }
  },
  async domains(store){
   if(!uuid.test(store))throw Error('Invalid store');const r=await rpc('mt_domain_list',{p_store:store});
   if(!Array.isArray(r)||r.length>20||r.some(x=>!x||!uuid.test(x.id)||typeof x.hostname!=='string'||!['pending','active','disabled'].includes(x.state)||x.dns_name!=='_techstore.'+x.hostname||typeof x.dns_value!=='string'||!x.dns_value.startsWith('techstore-verification=')||!uuid.test(x.dns_value.slice('techstore-verification='.length))))throw Error('Invalid domain list');return r;
  },
  async requestDomain({store,request,hostname}){
   if(!uuid.test(store)||!uuid.test(request)||typeof hostname!=='string'||hostname.length>253||!/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(hostname))throw Error('Invalid host');
   const r=await rpc('mt_domain_request',{p_store:store,p_request:request,p_host:hostname});if(!r||!uuid.test(r.id)||r.hostname!==hostname||!['pending','active','disabled'].includes(r.state)||r.dns_name!=='_techstore.'+hostname||typeof r.dns_value!=='string'||!r.dns_value.startsWith('techstore-verification='))throw Error('Domain request unconfirmed');return r;
  },
  async disableDomain(store,id){if(!uuid.test(store)||!uuid.test(id))throw Error('Invalid domain');const r=await rpc('mt_domain_disable',{p_store:store,p_id:id});if(typeof r!=='boolean')throw Error('Invalid response');return r},
  async designOriginals(store){
   if(!uuid.test(store))throw Error('Invalid store');const r=await rpc('mt_list_design_originals',{p_store:store});
   if(!Array.isArray(r)||r.length>12||r.some(x=>!x||!uuid.test(x.id)||typeof x.image_id!=='string'||!/^[a-z0-9-]{1,40}$/.test(x.image_id)||typeof x.alt!=='string'||x.path!==store+'/'+x.id+'.jpg'||typeof x.uploaded!=='boolean'||(x.public_enabled!==undefined&&typeof x.public_enabled!=='boolean')||(x.public_visible!==undefined&&typeof x.public_visible!=='boolean')))throw Error('Invalid image list');return r;
  },
  async setOriginalPublic(store,asset,enabled){if(!uuid.test(store)||!uuid.test(asset)||typeof enabled!=='boolean')throw Error('Invalid publication');const r=await rpc('mt_set_original_public',{p_store:store,p_asset:asset,p_enabled:enabled});if(r!==enabled)throw Error('Publication not confirmed');return r},
  async reserveOriginal({store,request,image,alt}){
   if(!uuid.test(store)||!uuid.test(request)||typeof image!=='string'||!/^[a-z0-9-]{1,40}$/.test(image)||typeof alt!=='string'||!alt.trim()||alt.trim().length>100)throw Error('Invalid image');
   const r=await rpc('mt_reserve_design_original',{p_store:store,p_request:request,p_image:image,p_alt:alt.trim()});if(!r||!uuid.test(r.id)||r.image_id!==image||r.path!==store+'/'+r.id+'.jpg'||typeof r.uploaded!=='boolean')throw Error('Image reservation not confirmed');return r;
  },
  async uploadOriginal(store,asset,blob){
   if(!uuid.test(store)||!uuid.test(asset?.id)||asset.path!==store+'/'+asset.id+'.jpg'||!(blob instanceof Blob)||blob.type!=='image/jpeg'||blob.size<4||blob.size>2000000)throw Error('Invalid image upload');
   const r=await fetcher(url+'/storage/v1/object/saas-design-originals/'+asset.path,{method:'POST',headers:{apikey:publishableKey,Authorization:'Bearer '+token(),'Content-Type':'image/jpeg','x-upsert':'false'},body:blob,cache:'no-store',redirect:'error',credentials:'omit'});if(!r.ok)throw Error('Upload not confirmed; refresh library before retrying');
  },
  async readOriginal(store,asset){
   if(!uuid.test(store)||!uuid.test(asset?.id)||asset.path!==store+'/'+asset.id+'.jpg'||asset.uploaded!==true)throw Error('Invalid image');
   const r=await fetcher(url+'/storage/v1/object/authenticated/saas-design-originals/'+asset.path,{method:'GET',headers:{apikey:publishableKey,Authorization:'Bearer '+token()},cache:'no-store',redirect:'error',credentials:'omit'});if(!r.ok)throw Error('Image unavailable');const blob=await r.blob();if(blob.type!=='image/jpeg'||blob.size>2000000||blob.size<4)throw Error('Invalid image response');return blob;
  },
  async designRead(store){if(!uuid.test(store))throw Error('Invalid store');return designResponse(await rpc('mt_design_read',{p_store:store,p_editor:true}))},
  async designHistory(store){if(!uuid.test(store))throw Error('Invalid store');const r=await rpc('mt_design_history',{p_store:store,p_before:null,p_limit:50});if(!Array.isArray(r)||r.length>50||r.some(x=>!Number.isSafeInteger(x?.revision)||x.revision<1))throw Error('Invalid history');return r},
  async designChange(store,state,action,theme=null,restore=null){if(!uuid.test(store)||!['save','publish','restore'].includes(action))throw Error('Invalid design action');designResponse(state);if(action==='save')theme=validateTheme(theme);else if(theme!==null)throw Error('Unexpected theme');if(action==='restore'?(!Number.isSafeInteger(restore)||restore<1):restore!==null)throw Error('Invalid restore');return designResponse(await rpc('mt_design_change',{p_store:store,p_expected:state.revision,p_expected_published:state.published_revision,p_action:action,p_theme:theme,p_restore:restore}))},
  async operationsOverview(ids){if(!Array.isArray(ids)||ids.length>100||new Set(ids).size!==ids.length||ids.some(x=>typeof x!=='string'||!uuid.test(x)))throw Error('Invalid store page');const r=await rpc('mt_admin_operations_overview',{p_stores:ids}),keys=['shared','licensed','trials','paid','manual','blocked','expiring','pending_domains','active_domains','queued_recovery','planned_releases','local_shards','verified_shards'],nonnegative=x=>Number.isSafeInteger(x)&&x>=0,s=r?.summary;if(!r||typeof r.live_billing_enabled!=='boolean'||typeof r.as_of!=='string'||!Number.isFinite(Date.parse(r.as_of))||!s||!keys.every(k=>nonnegative(s[k]))||s.licensed+s.blocked!==s.shared||s.trials+s.paid+s.manual!==s.licensed||s.expiring>s.licensed||(!r.live_billing_enabled&&s.paid!==0)||s.verified_shards>s.local_shards||!Array.isArray(r.stores)||r.stores.length>ids.length||new Set(r.stores.map(x=>x?.id)).size!==r.stores.length||r.stores.some(x=>!x||!ids.includes(x.id)||!(x.shard===null||typeof x.shard==='string')||typeof x.licensed!=='boolean'||typeof x.storefront_active!=='boolean'||(x.storefront_active&&!x.licensed)||!['none','pending','active'].includes(x.domain_state)||!nonnegative(x.pending_orders)||!nonnegative(x.dispatched_orders)||x.dispatched_orders>x.pending_orders||typeof x.backup_verified!=='boolean')||r.stores.filter(x=>x.licensed).length>s.licensed||r.stores.filter(x=>!x.licensed).length>s.blocked)throw Error('Invalid operations metrics');return r},
  async planCatalogReview(){
   const r=await rpc('mt_admin_plan_catalog_review',{});
   if(!r||typeof r.editable!=='boolean'||!Array.isArray(r.plans)||r.plans.length<3||r.plans.length>50||new Set(r.plans.map(x=>x.code)).size!==r.plans.length||r.plans.some(x=>!validPlan(x.code)||typeof x.name!=='string'||!Number.isSafeInteger(x.monthly_usd_cents)||x.monthly_usd_cents<1||typeof x.enrollment!=='boolean'||!count(x.subscribers)||typeof x.deletable!=='boolean')||!Array.isArray(r.history)||r.history.length>50||r.history.some(x=>!validRef(x.request_id)||!validRef(x.actor)||!validPlan(x.plan_code)||!['create','rename','delete'].includes(x.action)||typeof x.reference!=='string'))throw Error('Invalid plan catalog');return r
  },
  async planCatalogChange(x){
   if(!validRef(x.request)||!validPlan(x.code)||!['create','rename','delete'].includes(x.action)||!x.params||typeof x.reference!=='string'||!x.reference.trim()||x.reference.trim().length>200)throw Error('Invalid catalog action');
   const r=await rpc('mt_admin_plan_catalog_change',{req:x.request,action:x.action,code_value:x.code,expected:x.expected,params:x.params,proof:x.reference.trim()});if(r!==x.request)throw Error('Catalog action not confirmed');return r
  },
  async centralActionsReview(){const r=await rpc('mt_admin_actions_review',{});if(!r||!Array.isArray(r.plans)||r.plans.length<3||r.plans.length>50||r.plans.some(x=>!validPlan(x.code)||typeof x.name!=='string'||!Number.isSafeInteger(x.revision)||x.revision<1||!validCentralDenials(x.denied))||!Array.isArray(r.history)||r.history.length>50||r.history.some(x=>!validRef(x.request_id)||!validRef(x.actor)||!validPlan(x.plan_code)||typeof x.reference!=='string'||!validCentralDenials(x.before_denied)||!validCentralDenials(x.after_denied)))throw Error('Invalid central actions');return r},
  async centralActionsChange(x){if(!validRef(x.request)||!validPlan(x.plan)||!Number.isSafeInteger(x.expected)||x.expected<1||!validCentralDenials(x.desired)||typeof x.reference!=='string'||!x.reference.trim()||x.reference.trim().length>200)throw Error('Invalid central action');const r=await rpc('mt_admin_actions_change',{req:x.request,plan:x.plan,expected:x.expected,desired:x.desired,proof:x.reference.trim()});if(r!==x.request)throw Error('Central action not confirmed');return r},
  async modulesReview(){
   const r=await rpc('mt_admin_modules_review',{});if(!r||!Array.isArray(r.plans)||r.plans.length<3||r.plans.length>50||r.plans.some(x=>!validPlan(x.code)||typeof x.name!=='string'||!Number.isSafeInteger(x.revision)||x.revision<1||!moduleFlags(x.flags))||!Array.isArray(r.history)||r.history.length>50||r.history.some(x=>!validRef(x.request_id)||!validRef(x.actor)||!validPlan(x.plan_code)||typeof x.reference!=='string'||!moduleFlags(x.before_flags)||!moduleFlags(x.after_flags)))throw Error('Invalid module policy');return r
  },
  async modulesChange(x){
   if(!validRef(x.request)||!validPlan(x.plan)||!Number.isSafeInteger(x.expected)||x.expected<1||!moduleFlags(x.flags)||typeof x.reference!=='string'||!x.reference.trim()||x.reference.trim().length>200)throw Error('Invalid module policy action');
   const r=await rpc('mt_admin_modules_change',{req:x.request,plan:x.plan,expected:x.expected,flags_value:x.flags,proof:x.reference.trim()});if(r!==x.request)throw Error('Module action not confirmed');return r
  },
  async commercialBilling(store,offset=0){if(!validRef(store)||!Number.isSafeInteger(offset)||offset<0||offset>100000)throw Error('Invalid invoice page');const r=await rpc('mt_offline_billing_review',{s:store,off:offset});return validateBillingPage(r,store)},
  async commercialBillingDetails(store,invoice,offset=0){if(!validRef(store)||!validRef(invoice)||!Number.isSafeInteger(offset)||offset<0||offset>100000)throw Error('Invalid invoice');return validateBillingDetails(await rpc('mt_offline_billing_details',{s:store,i:invoice,off:offset}))},
  async commercialBillingWrite(store,kind,x){
   const specs={create:['mt_offline_billing_create',['req','month_value','expected_plan','expected_price','proof']],record:['mt_offline_billing_record',['req','i','k','orig','amount','method','proof','day_value','expected']],action:['mt_offline_billing_action',['req','i','k','proof']]},spec=Object.hasOwn(specs,kind)?specs[kind]:null;
   if(!validRef(store)||!spec||!validRef(x.req)||spec[1].some(k=>!Object.hasOwn(x,k)))throw Error('Invalid billing write');const args={s:store};for(const k of spec[1])args[k]=x[k];const r=await rpc(spec[0],args);if(r!==x.req)throw Error('Billing write not confirmed');return r
  },
  async transfersReview(store){if(!validRef(store))throw Error('Invalid store');const r=await rpc('mt_transfer_admin_list',{s:store});if(!Array.isArray(r)||r.length>50||r.some(x=>!validRef(x.id)||x.store_id!==store||![x.old_owner,x.new_owner,x.proposed_by].every(validRef)||!['pending','completed','cancelled'].includes(x.state)||typeof x.reference!=='string'||!Number.isFinite(Date.parse(x.expires_at))))throw Error('Invalid transfer list');return r},
  async transferPropose(store,request,oldOwner,newOwner,reference){if(![store,request,oldOwner,newOwner].every(validRef)||oldOwner===newOwner||typeof reference!=='string'||!reference.trim()||reference.length>200)throw Error('Invalid transfer proposal');const r=await rpc('mt_transfer_propose',{s:store,req:request,old_u:oldOwner,new_u:newOwner,proof:reference.trim()});if(r!==request)throw Error('Transfer proposal not confirmed');return r},
  async transferFinalize(store,request,complete){if(![store,request].every(validRef)||typeof complete!=='boolean'||await rpc('mt_transfer_finalize',{s:store,req:request,complete})!==true)throw Error('Transfer not confirmed')},
  async membersReview(store,offset=0){
   if(!validRef(store)||!count(offset)||offset>100000)throw Error('Invalid member page');const r=await rpc('mt_admin_members_review',{s:store,off:offset});
   if(!r||!Array.isArray(r.members)||r.members.length>50||typeof r.more!=='boolean'||r.members.some(x=>!validRef(x.user_id)||!['owner','cashier','stock','tech'].includes(x.role)||typeof x.active!=='boolean'||typeof x.blocked!=='boolean'||!count(x.revision)||typeof x.display_name!=='string')||!Array.isArray(r.history)||r.history.length>50||r.history.some(x=>!validRef(x.request_id)||!validRef(x.user_id)||!validRef(x.actor)||typeof x.reference!=='string'||typeof x.blocked!=='boolean'||typeof x.previous_blocked!=='boolean'))throw Error('Invalid member directory');return r
  },
  async memberChange(x){
   if(!validRef(x.store)||!validRef(x.request)||!validRef(x.user)||!count(x.expected)||!['owner','cashier','stock','tech'].includes(x.role)||typeof x.active!=='boolean'||typeof x.blocked!=='boolean'||typeof x.reference!=='string'||!x.reference.trim()||x.reference.trim().length>200)throw Error('Invalid membership control');
   const r=await rpc('mt_admin_member_change',{s:x.store,req:x.request,u:x.user,expected:x.expected,expected_role:x.role,expected_active:x.active,blocked_value:x.blocked,proof:x.reference.trim()});if(r!==x.request)throw Error('Member action not confirmed');return r
  },
  async planPolicyReview(){
   const r=await rpc('mt_admin_plan_policy_review',{}),flags=['enrollment','storefront','orders','guest','delivery'],valid=x=>x&&validPlan(x.plan_code)&&Number.isSafeInteger(x.revision)&&x.revision>=1&&flags.every(k=>typeof x[k]==='boolean');
   if(!r||!Array.isArray(r.plans)||(r.plans.length<3||r.plans.length>50)||new Set(r.plans.map(x=>x.plan_code)).size!==r.plans.length||r.plans.some(x=>!valid(x)||typeof x.name!=='string'||!Number.isSafeInteger(x.monthly_usd_cents)||x.monthly_usd_cents<1||!Number.isSafeInteger(x.subscribers)||x.subscribers<0||!Number.isSafeInteger(x.licensed)||x.licensed<0||x.licensed>x.subscribers)||!Array.isArray(r.history)||r.history.length>50||r.history.some(x=>!uuid.test(x.request_id)||!uuid.test(x.actor)||!validPlan(x.plan_code)||typeof x.reference!=='string'||!valid(x.before_state)||!valid(x.after_state)||!Number.isFinite(Date.parse(x.created_at))))throw Error('Invalid plan policy');
   return r
  },
  async planPolicyChange(request,plan,expected,flags,reference){
   if(typeof request!=='string'||!uuid.test(request)||!validPlan(plan)||!Number.isSafeInteger(expected)||expected<1||!flags||Object.keys(flags).length!==5||!['enrollment','storefront','orders','guest','delivery'].every(k=>typeof flags[k]==='boolean')||typeof reference!=='string'||!reference.trim()||reference.trim().length>200)throw Error('Invalid plan policy change');
   const r=await rpc('mt_admin_plan_policy_change',{req:request,plan,expected,flags,proof:reference.trim()});if(r!==request)throw Error('Unconfirmed policy change');return r
  },
  async storeControlReview(store,offset=0){
   if(typeof store!=='string'||!uuid.test(store)||!Number.isSafeInteger(offset)||offset<0||offset>100000)throw Error('Invalid store review');
   const r=await rpc('mt_admin_store_review',{s:store,off:offset}),v=r?.snapshot,validDate=x=>x===null||typeof x==='string'&&Number.isFinite(Date.parse(x)),validId=x=>typeof x==='string'&&uuid.test(x),count=x=>Number.isSafeInteger(x)&&x>=0;
   if(!v||v.id!==store||typeof v.name!=='string'||typeof v.slug!=='string'||!states.slice(1).includes(v.state)||!validPlan(v.plan)||!['pending','trial','active','past_due','suspended','cancelled'].includes(v.subscription_state)||![v.valid_until,v.manual_until,v.subscription_updated,v.control_updated].every(validDate)||!(v.manual_request===null||validId(v.manual_request))||!(v.manual_reference===null||typeof v.manual_reference==='string')||!['storefront_paused','provider_bound','live_billing','local'].every(k=>typeof v[k]==='boolean')||!['licensed','storefront_visible','more'].every(k=>typeof r[k]==='boolean')||!['owner_count','staff_count','product_count','pending_orders'].every(k=>count(r[k]))||!Array.isArray(r.history)||r.history.length>50||!Array.isArray(r.legacy_history)||r.legacy_history.length>50||r.history.some(x=>!validId(x.request_id)||!validId(x.actor)||typeof x.action!=='string'||typeof x.reference!=='string'||!validDate(x.created_at)||!x.before_state||!x.after_state)||r.legacy_history.some(x=>!validId(x.id)||!validId(x.actor)||typeof x.action!=='string'||!validDate(x.recorded_at)))throw Error('Invalid store control data');
   return r
  },
  async storeControlChange(store,request,action,expected,params,reference){
   if(typeof store!=='string'||!uuid.test(store)||typeof request!=='string'||!uuid.test(request)||!['grant','renew','revoke','plan','pause_shop','resume_shop','rename','trial','suspend','cancel','reopen'].includes(action)||expected?.id!==store||!params||typeof params!=='object'||Array.isArray(params)||typeof reference!=='string'||!reference.trim()||reference.trim().length>200)throw Error('Invalid administrative action');
   const r=await rpc('mt_admin_store_change',{s:store,req:request,action,expected,params,proof:reference.trim()});if(r!==request)throw Error('Unconfirmed administrative action');return r
  },
  async sharedLicenseStatus(ids){
   if(!Array.isArray(ids)||ids.length>100||ids.some(x=>typeof x!=='string'||!uuid.test(x)))throw Error('Invalid license page');
   const r=await rpc('mt_admin_shared_license_status',{p_stores:ids});
   if(!Array.isArray(r)||r.length>ids.length||new Set(r.map(x=>x?.id)).size!==r.length||r.some(x=>!x||!ids.includes(x.id)||!['pending','trial','active','past_due','suspended','cancelled'].includes(x.state)||!validPlan(x.plan)||typeof x.write_entitlement!=='boolean'||!['trial','manual','provider','none'].includes(x.license_source)))throw Error('Invalid license page');return r;
  },
  async sharedRecovery(){
   const r=await rpc('mt_admin_shared_recovery_overview',{p_limit:50});if(!r||!['requests','backups','plans'].every(k=>Array.isArray(r[k])&&r[k].length<=50&&r[k].every(x=>x&&typeof x.id==='string'&&uuid.test(x.id)&&typeof x.shard_code==='string'))||r.requests.some(x=>!['queued','cancelled'].includes(x.state)||!['project_backup','tenant_export','restore_drill'].includes(x.kind))||r.backups.some(x=>typeof x.eligible!=='boolean')||r.plans.some(x=>typeof x.eligible!=='boolean'||!['planned','cancelled'].includes(x.state)))throw Error('Invalid recovery overview');return r;
  },
  async sharedRecoveryChange(x){
   const id=v=>typeof v==='string'&&uuid.test(v);if(!x||!id(x.request)||typeof x.shard!=='string'||!/^[a-z][a-z0-9-]{2,39}$/.test(x.shard))throw Error('Invalid request');
   let r;if(x.kind==='release'){if(!id(x.release)||!id(x.backup))throw Error('Invalid release plan');r=await rpc('mt_admin_shared_release_plan',{p_request:x.request,p_shard:x.shard,p_release:x.release,p_backup:x.backup})}
   else{if(!['project_backup','tenant_export','restore_drill'].includes(x.kind)||(x.kind==='tenant_export'?!id(x.store):x.store!==null)||(x.kind==='restore_drill'?!id(x.backup):x.backup!==null))throw Error('Invalid recovery request');r=await rpc('mt_admin_shared_recovery_request',{p_request:x.request,p_shard:x.shard,p_kind:x.kind,p_store:x.store,p_backup:x.backup})}
   if(!id(r))throw Error('Unconfirmed request');return r;
  },
  async sharedRecoveryCancel(id,type){if(typeof id!=='string'||!uuid.test(id)||!['recovery','release'].includes(type))throw Error('Invalid cancel');const r=await rpc('mt_admin_shared_recovery_cancel',{p_id:id,p_type:type});if(typeof r!=='boolean')throw Error('Invalid response');return r},
  async planPrices(){
   const r=await rpc('mt_admin_plan_prices',{});if(!r||typeof r.editable!=='boolean'||!Array.isArray(r.plans)||(r.plans.length<3||r.plans.length>50)||new Set(r.plans.map(x=>x?.code)).size!==r.plans.length||r.plans.some(x=>!x||!validPlan(x.code)||typeof x.name!=='string'||!Number.isSafeInteger(x.monthly_usd_cents)||x.monthly_usd_cents<1)||!Array.isArray(r.history)||r.history.length>50||r.history.some(x=>!x||!uuid.test(x.id)||!validPlan(x.plan_code)||!Number.isSafeInteger(x.previous_cents)||!Number.isSafeInteger(x.new_cents)||typeof x.note!=='string'))throw Error('Invalid plans');return r;
  },
  async changePlanPrice({request,plan,expected,price,note}){
   if(typeof request!=='string'||!uuid.test(request)||!validPlan(plan)||!Number.isSafeInteger(expected)||expected<1||!Number.isSafeInteger(price)||price<100||price>10000000||typeof note!=='string'||!note.trim()||note.trim().length>300)throw Error('Invalid price');
   const r=await rpc('mt_admin_plan_price_change',{p_request:request,p_plan:plan,p_expected:expected,p_price:price,p_note:note.trim()});if(typeof r!=='string'||!uuid.test(r))throw Error('Price not confirmed');return r;
  },
  async contact(email=null){
   if(email!==null&&(typeof email!=='string'||email.trim().length>254||!/^\S+@[^\s@]+\.[^\s@]+$/.test(email.trim())||email.trim().toLowerCase().endsWith('.invalid')))throw Error('Invalid contact email');
   const r=await rpc('saas_admin_contact',{p_email:email===null?null:email.trim(),p_write:email!==null});
   if(!r||r.username!=='king'||r.verified!==false||!(r.contact_email===null||typeof r.contact_email==='string'))throw Error('Invalid contact response');
   return r;
  },
  async signIn(email,password,codeProvider=null){
   if(setupBusy)throw Error('Enrollment in progress');
   session=null;
   if(typeof email!=='string'||!email.trim()||typeof password!=='string'||!password)throw Error('Email and password required');
   const s=await request('/auth/v1/token?grant_type=password',{email:email.trim(),password});
   if(typeof s?.access_token!=='string'||!s.access_token||!Number.isFinite(s.expires_in)||s.expires_in<=0)throw Error('Invalid login response');
   session={accessToken:s.access_token,expiresAt:clock()+s.expires_in*1000};
   try{await security.authenticate(codeProvider,{required:false});await this.overview()}catch(e){const old=session;session=null;if(old)try{await request('/auth/v1/logout?scope=local',undefined,old.accessToken)}catch{}throw e}
  },
  async signOut(){const old=session;session=null;if(old)await request('/auth/v1/logout?scope=local',undefined,old.accessToken)},
  signedIn(){return !!session&&session.expiresAt>clock()+5000},
  async overview({offset=0,limit=25,query='',state=''}={}){
   if(!Number.isSafeInteger(offset)||offset<0||offset>2147483647||!Number.isInteger(limit)||limit<1||limit>100||typeof query!=='string'||query.length>160||!states.includes(state))throw Error('Invalid filters');
   const r=await rpc('saas_admin_overview',{p_offset:offset,p_limit:limit,p_query:query.trim(),p_state:state});
   if(!r||!Array.isArray(r.rows)||r.rows.length>limit||!['total','ready','suspended','active_subscriptions','matched'].every(k=>Number.isSafeInteger(r[k])&&r[k]>=0)||r.matched>r.total||r.rows.length>r.matched)throw Error('Invalid overview');
   for(const row of r.rows)if(!uuid.test(row.id)||typeof row.name!=='string'||typeof row.slug!=='string'||!states.slice(1).includes(row.state)||typeof row.provisioned!=='boolean'||!(row.plan_code===null||validPlan(row.plan_code))||!(row.subscription_state===null||['pending','trial','active','past_due','suspended','cancelled'].includes(row.subscription_state))||!(row.valid_until===null||(typeof row.valid_until==='string'&&Number.isFinite(Date.parse(row.valid_until)))))throw Error('Invalid store row');
   return r;
  },
  async shardDirectory(after=null,limit=50){
   if(!(after===null||typeof after==='string'&&uuid.test(after))||!Number.isInteger(limit)||limit<1||limit>100)throw Error('Invalid directory page');
   const r=await rpc('mt_admin_shard_overview',{p_after:after,p_limit:limit});
   const code=x=>typeof x==='string'&&/^[a-z][a-z0-9-]{2,39}$/.test(x);
   if(!r||!Array.isArray(r.shards)||r.shards.length>100||!Array.isArray(r.placements)||r.placements.length>limit||r.shards.some(x=>!x||!code(x.code)||!['local','planned'].includes(x.state)||typeof x.region!=='string'||!Number.isSafeInteger(x.tenants)||x.tenants<0)||r.placements.some(x=>!x||typeof x.store_id!=='string'||!uuid.test(x.store_id)||typeof x.name!=='string'||typeof x.slug!=='string'||!states.slice(1).includes(x.store_state)||!code(x.shard_code)||!Number.isSafeInteger(x.generation)||x.generation<1||!(x.planned_destination===null||code(x.planned_destination))))throw Error('Invalid shard directory');
   return r;
  },
  async registerShard(code,region){
   if(typeof code!=='string'||!/^[a-z][a-z0-9-]{2,39}$/.test(code)||typeof region!=='string'||!region.trim()||region.trim().length>80)throw Error('Invalid planned group');
   const result=await rpc('mt_admin_shard_register',{p_code:code,p_region:region.trim()});
   if(result!==code)throw Error('Unconfirmed planned group');return result;
  },
  async planMove(store,destination,action){
   if(typeof store!=='string'||!uuid.test(store)||typeof destination!=='string'||!/^[a-z][a-z0-9-]{2,39}$/.test(destination)||!['plan','cancel'].includes(action))throw Error('Invalid move plan');
   const result=await rpc('mt_admin_move_plan',{p_store:store,p_destination:destination,p_action:action});
   if(!(action==='cancel'&&result===null)&&(typeof result!=='string'||!uuid.test(result)))throw Error('Unconfirmed move plan');return result;
  },
  async registerShared({name,slug,plan,owner}){
   if(typeof name!=='string'||name.trim().length<1||name.trim().length>160||typeof slug!=='string'||!/^[a-z][a-z0-9-]{2,39}$/.test(slug)||!validPlan(plan)||typeof owner!=='string'||!uuid.test(owner))throw Error('Invalid shared store details');
   const id=await rpc('mt_admin_create_store',{p_name:name.trim(),p_slug:slug,p_plan:plan,p_owner:owner});
   if(typeof id!=='string'||!uuid.test(id))throw Error('Unconfirmed shared store registration');
   return id;
  },
  async register({name,slug,plan}){
   if(typeof name!=='string'||name.trim().length<1||name.trim().length>160||typeof slug!=='string'||!/^[a-z][a-z0-9-]{2,39}$/.test(slug)||!validPlan(plan))throw Error('Invalid store details');
   const id=await rpc('saas_admin_register',{p_name:name.trim(),p_slug:slug,p_plan:plan});
   if(typeof id!=='string'||!uuid.test(id))throw Error('Unconfirmed registration; refresh before retrying');
   return id;
  },
  async provisioningStatus(ids){
   if(!Array.isArray(ids)||ids.length>100||ids.some(id=>typeof id!=='string'||!uuid.test(id)))throw Error('Invalid stores');
   if(ids.length===0)return [];
   const r=await rpc('saas_admin_provisioning_status',{p_stores:ids});
   if(!Array.isArray(r)||r.length!==new Set(ids).size||new Set(r.map(x=>x?.id)).size!==r.length||r.some(x=>!x||!ids.includes(x.id)||!['queued','none'].includes(x.queue)||!['unprovisioned_or_blocked','expired','verification_required'].includes(x.license)))throw Error('Invalid provisioning status');
   return r;
  },
  async provisioning(id,action){
   if(typeof id!=='string'||!uuid.test(id)||!['request','cancel'].includes(action))throw Error('Invalid provisioning request');
   const result=await rpc('saas_admin_provisioning',{p_store:id,p_action:action});
   if(!(action==='cancel'&&result===null)&&(typeof result!=='string'||!uuid.test(result)))throw Error('Unconfirmed provisioning request');
   return result;
  },
  async billing(limit=50){
   if(!Number.isInteger(limit)||limit<1||limit>100)throw Error('Invalid limit');
   const r=await rpc('saas_admin_billing_overview',{p_limit:limit});
   const isId=x=>typeof x==='string'&&uuid.test(x),date=x=>typeof x==='string'&&/^\d{4}-\d{2}-01$/.test(x)&&Number.isFinite(Date.parse(x));
   if(!r||r.mode!=='sandbox'||!date(r.month)||!['stores','invoices'].every(k=>Array.isArray(r[k])&&r[k].length<=limit))throw Error('Invalid sandbox billing overview');
   if(r.stores.some(x=>!x||!isId(x.id)||typeof x.name!=='string'||!validPlan(x.plan_code)||!Number.isSafeInteger(x.monthly_usd_cents)||x.monthly_usd_cents<1)||r.invoices.some(x=>!x||!isId(x.id)||!isId(x.store_id)||typeof x.store_name!=='string'||!date(x.period_start)||!date(x.period_end)||!Number.isSafeInteger(x.amount_cents)||x.amount_cents<1||x.currency!=='USD'||!validPlan(x.plan_code)||!['draft','paid','failed','refunded','void'].includes(x.state)))throw Error('Invalid sandbox billing data');
   return r;
  },
  async billingDraft(store,month){
   if(typeof store!=='string'||!uuid.test(store)||typeof month!=='string'||!/^\d{4}-\d{2}-01$/.test(month))throw Error('Invalid sandbox draft');
   const id=await rpc('saas_admin_billing_draft',{p_store:store,p_month:month});
   if(typeof id!=='string'||!uuid.test(id))throw Error('Unconfirmed sandbox draft');
   return id;
  },
  async billingSimulate(invoice,action,requestId){
   if(typeof invoice!=='string'||!uuid.test(invoice)||!['paid','failed','refunded','void'].includes(action)||typeof requestId!=='string'||!uuid.test(requestId))throw Error('Invalid sandbox event');
   const id=await rpc('saas_admin_billing_simulate',{p_invoice:invoice,p_action:action,p_request:requestId});
   if(id!==invoice)throw Error('Unconfirmed sandbox event');
   return id;
  },
  async backups(limit=50){
   if(!Number.isInteger(limit)||limit<1||limit>100)throw Error('Invalid limit');
   const r=await rpc('saas_admin_backup_overview',{p_limit:limit});
   const isId=x=>typeof x==='string'&&uuid.test(x);
   if(!r||!['stores','backups','requests'].every(k=>Array.isArray(r[k])&&r[k].length<=limit))throw Error('Invalid backup overview');
   if(r.stores.some(x=>!x||!isId(x.id)||typeof x.name!=='string'||typeof x.slug!=='string'||!(x.recent_backup_id===null||isId(x.recent_backup_id)))||r.backups.some(x=>!x||!isId(x.id)||!isId(x.store_id)||typeof x.store_name!=='string'||typeof x.captured_at!=='string'||!Number.isFinite(Date.parse(x.captured_at))||!['verified','unverified','stale','revoked'].includes(x.status))||r.requests.some(x=>!x||!isId(x.id)||!isId(x.store_id)||typeof x.store_name!=='string'||!['backup','restore_drill'].includes(x.kind)||!['queued','cancelled'].includes(x.state)||!(x.kind==='backup'?x.backup_id===null:isId(x.backup_id))))throw Error('Invalid backup data');
   return r;
  },
  async backupRequest(store,kind,action,backup=null){
   if(typeof store!=='string'||!uuid.test(store)||!['backup','restore_drill'].includes(kind)||!['request','cancel'].includes(action)||(kind==='backup'||action==='cancel'?backup!==null:typeof backup!=='string'||!uuid.test(backup)))throw Error('Invalid backup request');
   const id=await rpc('saas_admin_backup_request',{p_store:store,p_kind:kind,p_action:action,p_backup:backup});
   if(!(action==='cancel'&&id===null)&&(typeof id!=='string'||!uuid.test(id)))throw Error('Unconfirmed backup request');
   return id;
  },
  async releases(limit=50){
   if(!Number.isInteger(limit)||limit<1||limit>100)throw Error('Invalid limit');
   const r=await rpc('saas_admin_release_overview',{p_limit:limit});
   const version=/^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$/;
   if(!r||!['releases','targets','eligible_stores'].every(k=>Array.isArray(r[k])&&r[k].length<=limit))throw Error('Invalid release overview');
   const isId=x=>typeof x==='string'&&uuid.test(x);
   if(r.releases.some(x=>!x||!isId(x.id)||typeof x.version!=='string'||!version.test(x.version)||!(/^[0-9a-f]{40}$/).test(x.commit_sha)||!(/^[0-9a-f]{64}$/).test(x.bundle_sha256)||!(/^[0-9a-f]{64}$/).test(x.migrations_sha256)||typeof x.notes!=='string'||typeof x.rollback_plan!=='string')||r.targets.some(x=>!x||!isId(x.id)||!isId(x.release_id)||!isId(x.store_id)||!version.test(x.version)||typeof x.store_name!=='string'||!['planned','cancelled'].includes(x.state))||r.eligible_stores.some(x=>!x||!isId(x.id)||typeof x.name!=='string'||typeof x.slug!=='string'))throw Error('Invalid release data');
   return r;
  },
  async registerRelease({version,commit,bundle,migrations,notes='',rollback}){
   if(typeof version!=='string'||!/^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$/.test(version)||typeof commit!=='string'||!/^[0-9a-f]{40}$/.test(commit)||typeof bundle!=='string'||!/^[0-9a-f]{64}$/.test(bundle)||typeof migrations!=='string'||!/^[0-9a-f]{64}$/.test(migrations)||typeof notes!=='string'||notes.length>2000||typeof rollback!=='string'||!rollback.trim()||rollback.trim().length>2000)throw Error('Invalid manifest');
   const id=await rpc('saas_admin_release_register',{p_version:version,p_commit:commit,p_bundle:bundle,p_migrations:migrations,p_notes:notes,p_rollback:rollback.trim()});
   if(typeof id!=='string'||!uuid.test(id))throw Error('Unconfirmed release registration');
   return id;
  },
  async planRelease(release,store,action){
   if(typeof release!=='string'||!uuid.test(release)||typeof store!=='string'||!uuid.test(store)||!['plan','cancel'].includes(action))throw Error('Invalid release plan');
   const id=await rpc('saas_admin_release_plan',{p_release:release,p_store:store,p_action:action});
   if(!(action==='cancel'&&id===null)&&(typeof id!=='string'||!uuid.test(id)))throw Error('Unconfirmed release plan');
   return id;
  },
  async manage(id,action,days=null){
   if(typeof id!=='string'||!uuid.test(id)||!actions.includes(action)||(action==='trial'?(!Number.isInteger(days)||days<1||days>30):days!==null))throw Error('Invalid action');
   await rpc('saas_admin_manage',{p_store:id,p_action:action,p_days:days});
  }
 };
}
