// Server-only account provisioning. Owner JWT authorizes every database phase.
// Never return Auth Admin responses, log credentials or reset existing passwords.
const headers={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS','Content-Type':'application/json','Cache-Control':'no-store'};
const reply=(status:number,body:unknown)=>new Response(JSON.stringify(body),{status,headers});
const id=(v:unknown):v is string=>typeof v==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(v);
function key(name:string,legacy:string){try{const k=JSON.parse(Deno.env.get(name)||'{}').default;if(typeof k==='string'&&k)return k}catch{}return Deno.env.get(legacy)||''}
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return reply(405,{error:'Method not allowed'});
 try{
  const jwt=req.headers.get('Authorization')||'';
  if(!/^Bearer [A-Za-z0-9_.-]+$/.test(jwt))return reply(401,{error:'Authentication required'});
  const url=Deno.env.get('SUPABASE_URL')||'',anon=key('SUPABASE_PUBLISHABLE_KEYS','SUPABASE_ANON_KEY'),admin=key('SUPABASE_SECRET_KEYS','SUPABASE_SERVICE_ROLE_KEY');
  if(!url||!anon||!admin)return reply(503,{error:'Provisioning unavailable'});
  if(Number(req.headers.get('Content-Length')||0)>4096)return reply(413,{error:'Request too large'});
  const raw=await req.text();if(raw.length>4096)return reply(413,{error:'Request too large'});
  const v=JSON.parse(raw),name=typeof v.name==='string'?v.name.trim():'',email=typeof v.email==='string'?v.email.trim().toLowerCase():'',pw=v.password;
  if(!id(v.store)||!id(v.request)||!(v.branch===null||id(v.branch))||!['cashier','stock','tech'].includes(v.role)||name.length<1||name.length>120||email.length>254||!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)||typeof pw!=='string'||pw.length<12||new TextEncoder().encode(pw).length>72)return reply(400,{error:'Invalid employee details'});
  const ownerHeaders={apikey:anon,Authorization:jwt,'Content-Type':'application/json'};
  const auth=await fetch(url+'/auth/v1/user',{headers:ownerHeaders,redirect:'error'});if(!auth.ok)return reply(401,{error:'Authentication required'});
  const actor=(await auth.json()).id;if(!id(actor))return reply(401,{error:'Authentication required'});
  const args={p_store:v.store,p_request:v.request,p_name:name,p_email:email,p_role:v.role,p_branch:v.branch,p_finish:false};
  async function phase(finish:boolean){const res=await fetch(url+'/rest/v1/rpc/mt_staff_provision',{method:'POST',headers:ownerHeaders,body:JSON.stringify({...args,p_finish:finish}),redirect:'error'});if(!res.ok)return null;const p=await res.json();return p&&p.actor===actor&&id(p.request_id)&&typeof p.completed==='boolean'&&(p.user_id===null||id(p.user_id))?p:null}
  let state=await phase(false);if(!state)return reply(403,{error:'Employee request unavailable or not authorized'});
  args.p_request=state.request_id;
  if(!state.completed&&!state.user_id){
   const h:Record<string,string>={apikey:admin,'Content-Type':'application/json'};
   if(!admin.startsWith('sb_secret_'))h.Authorization='Bearer '+admin;
   // An owner explicitly attests the new staff email. Never link an unrelated pre-existing account.
   await fetch(url+'/auth/v1/admin/users',{method:'POST',headers:h,body:JSON.stringify({email,password:pw,email_confirm:true,app_metadata:{techstore_staff_request:args.p_request,techstore_staff_store:v.store,techstore_staff_actor:actor}}),redirect:'error'});
   state=await phase(false);
   if(!state||!state.user_id)return reply(409,{error:'Account creation not confirmed; retry the same details'});
  }
  if(!state.completed)state=await phase(true);
  if(!state?.completed||!id(state.user_id))return reply(409,{error:'Membership not confirmed; retry the same details'});
  return reply(200,{user_id:state.user_id,request_id:state.request_id});
 }catch{return reply(400,{error:'Employee request not confirmed'})}
});
