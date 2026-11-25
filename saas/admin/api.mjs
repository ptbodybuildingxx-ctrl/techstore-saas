const allowedOrigin='https://mezsyzdieqmqulddcrtg.supabase.co';
const states=['','provisioning','ready','suspended','closed'];
const plans=['basic','business','pro'];
const actions=['trial','suspend','cancel','reopen'];
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
export function createAdminApi({url,publishableKey,fetcher=fetch,clock=Date.now}) {
 if(url!==allowedOrigin||typeof publishableKey!=='string'||!/^sb_publishable_[A-Za-z0-9_-]{20,200}$/.test(publishableKey)) throw Error('Invalid control-plane configuration');
 let session=null;
 async function request(path,body,token) {
  const res=await fetcher(url+path,{method:'POST',headers:{apikey:publishableKey,'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:body===undefined?undefined:JSON.stringify(body),cache:'no-store',redirect:'error',credentials:'omit'});
  if(!res.ok){const e=Error(res.status===401||res.status===403?'Access denied':res.status===409?'Store identifier already exists':'Request failed');e.status=res.status;throw e}
  if(res.status===204)return null;
  return res.json();
 }
 function token(){if(!session||session.expiresAt<=clock()+5000){session=null;throw Error('Sign in again')}return session.accessToken}
 async function rpc(name,args){try{return await request('/rest/v1/rpc/'+name,args,token())}catch(e){if(e.status===401||e.status===403)session=null;throw e}}
 return {
  async signIn(email,password){
   session=null;
   if(typeof email!=='string'||!email.trim()||typeof password!=='string'||!password)throw Error('Email and password required');
   const s=await request('/auth/v1/token?grant_type=password',{email:email.trim(),password});
   if(typeof s?.access_token!=='string'||!s.access_token||!Number.isFinite(s.expires_in)||s.expires_in<=0)throw Error('Invalid login response');
   session={accessToken:s.access_token,expiresAt:clock()+s.expires_in*1000};
   try{await this.overview()}catch(e){session=null;throw e}
  },
  async signOut(){const old=session;session=null;if(old)await request('/auth/v1/logout?scope=local',undefined,old.accessToken)},
  signedIn(){return !!session&&session.expiresAt>clock()+5000},
  async overview({offset=0,limit=25,query='',state=''}={}){
   if(!Number.isSafeInteger(offset)||offset<0||offset>2147483647||!Number.isInteger(limit)||limit<1||limit>100||typeof query!=='string'||query.length>160||!states.includes(state))throw Error('Invalid filters');
   const r=await rpc('saas_admin_overview',{p_offset:offset,p_limit:limit,p_query:query.trim(),p_state:state});
   if(!r||!Array.isArray(r.rows)||r.rows.length>limit||!['total','ready','suspended','active_subscriptions','matched'].every(k=>Number.isSafeInteger(r[k])&&r[k]>=0)||r.matched>r.total||r.rows.length>r.matched)throw Error('Invalid overview');
   for(const row of r.rows)if(!uuid.test(row.id)||typeof row.name!=='string'||typeof row.slug!=='string'||!states.slice(1).includes(row.state)||typeof row.provisioned!=='boolean'||!(row.plan_code===null||plans.includes(row.plan_code))||!(row.subscription_state===null||['pending','trial','active','past_due','suspended','cancelled'].includes(row.subscription_state))||!(row.valid_until===null||(typeof row.valid_until==='string'&&Number.isFinite(Date.parse(row.valid_until)))))throw Error('Invalid store row');
   return r;
  },
  async register({name,slug,plan}){
   if(typeof name!=='string'||name.trim().length<1||name.trim().length>160||typeof slug!=='string'||!/^[a-z][a-z0-9-]{2,39}$/.test(slug)||!plans.includes(plan))throw Error('Invalid store details');
   const id=await rpc('saas_admin_register',{p_name:name.trim(),p_slug:slug,p_plan:plan});
   if(typeof id!=='string'||!uuid.test(id))throw Error('Unconfirmed registration; refresh before retrying');
   return id;
  },
  async manage(id,action,days=null){
   if(typeof id!=='string'||!uuid.test(id)||!actions.includes(action)||(action==='trial'?(!Number.isInteger(days)||days<1||days>30):days!==null))throw Error('Invalid action');
   await rpc('saas_admin_manage',{p_store:id,p_action:action,p_days:days});
  }
 };
}
