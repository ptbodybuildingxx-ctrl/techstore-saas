// @ts-nocheck
const URL_BASE=Deno.env.get('SUPABASE_URL'),SERVICE=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),PUB='sb_publishable_b6YygUoLhEVE78WYApR7Ag_JfDIq1cz';
const origins=new Set(['https://ptbodybuildingxx-ctrl.github.io','http://localhost:8080','http://127.0.0.1:8080']);
const randomUUID=()=>crypto.randomUUID();
function sessionId(token){try{let x=token.split('.')[1].replace(/-/g,'+').replace(/_/g,'/');let v=JSON.parse(atob(x.padEnd(Math.ceil(x.length/4)*4,'='))).session_id;return typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)?v:null}catch{return null}}
async function upstream(path,options={},key=SERVICE,token=key){
 const r=await fetch(URL_BASE+path,{...options,headers:{apikey:key,Authorization:'Bearer '+token,'Content-Type':'application/json',...(options.headers||{})}});
 const raw=await r.text();let data;try{data=raw?JSON.parse(raw):null}catch{data=null}
 if(!r.ok){console.error('Upstream',r.status,path.split('?')[0]);throw Object.assign(Error(r.status===409?'Conflict':r.status===401||r.status===403?'Access denied':'Database or auth request failed'),{status:r.status===401||r.status===403?401:r.status===409?409:502})}return data
}
const rest=(path,method='GET',body,headers={})=>upstream('/rest/v1/'+path,{method,headers,body:body===undefined?undefined:JSON.stringify(body)});
const adminAuth=(path,method='GET',body)=>upstream('/auth/v1/admin/'+path,{method,body:body===undefined?undefined:JSON.stringify(body)});
async function profile(req){let token=req.headers.get('Authorization')?.match(/^Bearer (.+)$/i)?.[1];if(!token)return null;
 let au=await upstream('/auth/v1/user',{},PUB,token);if(!au?.id||!au.email_confirmed_at)fail(401,'Confirm email first');const sid=sessionId(token);if(!sid||await rest('rpc/ts_session_valid','POST',{p_user:au.id,p_session:sid})!==true)fail(401,'Session expired; sign in again');
 let list=await rest('ts_profiles?user_id=eq.'+encodeURIComponent(au.id)+'&select=*');
 if(!list.length){await rest('ts_profiles','POST',{user_id:au.id,name:String(au.user_metadata?.name||au.email||'Customer').slice(0,100),email:au.email||''},{Prefer:'resolution=ignore-duplicates'});list=await rest('ts_profiles?user_id=eq.'+encodeURIComponent(au.id)+'&select=*')}
 let p=list[0];if(!p?.active)fail(403,'Account disabled');return {id:p.user_id,email:au.email,name:p.name,role:p.role,active:p.active}
}
const publicUser=u=>({id:u.id,email:u.email,name:u.name,role:u.role});
function json(_res,data,status=200){return {data,status}}
const now=()=>new Date().toISOString();

const fail=(status,message)=>{throw Object.assign(new Error(message),{status})};
const txt=(v,n=200)=>String(v??'').trim().slice(0,n);
const positive=(v,zero=false)=>{let n=Number(v);if(!Number.isFinite(n)||n<0||(!zero&&n===0)||n>1e12)fail(400,'Invalid amount');return n};
const units=v=>{let n=positive(v);if(!Number.isSafeInteger(n))fail(400,'Quantity must be integer');return n};
const email=v=>{v=txt(v,254).toLowerCase();if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v))fail(400,'Invalid email');return v};
function need(u,roles){if(!u)fail(401,'Sign in required');if(roles&&!roles.includes(u.role))fail(403,'Access denied');return u}
const roles=['admin','cashier','stock','tech','customer'];
const managers=['admin','cashier','stock','tech'];
const rules={suppliers:['admin','stock'],purchases:['admin','stock'],debts:['admin','cashier'],installments:['admin','cashier'],inventory:['admin','stock'],used:['admin','stock'],returns:['admin','cashier'],repairs:['admin','tech','cashier'],offers:['admin'],coupons:['admin'],media:['admin'],draft:['admin'],versions:['admin'],notifications:['admin','cashier','tech'],orders:['admin','cashier'],loyalty:['admin','cashier'],warranty:['admin','cashier','tech']};
function product(s,id){let p=(s.data.products||[]).find(p=>p.id===id);if(!p)fail(404,'Product not found');return p}
function publicProducts(s){return (s.data.products||[]).filter(p=>!p.hidden&&!(s.data.owner?.hiddenCategories||[]).includes(p.type)).map(p=>({id:p.id,name:txt(p.name),nameEn:txt(p.nameEn),type:txt(p.type),sku:txt(p.sku),price:Number(p.price)||0,qty:Math.max(0,Number(p.qty)||0),specs:p.specs||{},image:safeImage(p.image)}))}
function safeImage(s){return typeof s==='string'&&s.length<500000&&/^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$/.test(s)?s:''}
function validateState(data){if(!data||typeof data!=='object'||Array.isArray(data))fail(400,'Invalid snapshot');for(let k of ['products','sales','expenses','repairs','warranties','orders','staff','customers','stockMoves'])if(data[k]!=null&&!Array.isArray(data[k]))fail(400,'Invalid '+k);const ids=new Set;for(let p of data.products||[]){if(!p||typeof p.id!=='string'||ids.has(p.id)||!txt(p.name))fail(400,'Invalid product');ids.add(p.id);if(!Number.isSafeInteger(p.qty)||p.qty<0)fail(400,'Invalid stock');positive(p.cost,true);positive(p.price,true)}return data}
const cleanState=d=>{let result={...d};for(let k of ['cart','shopCart','favorites','role','lang','demo'])delete result[k];return result};
function move(s,p,delta,reason){if(!Number.isSafeInteger(p.qty)||!Number.isSafeInteger(delta)||!Number.isSafeInteger(p.qty+delta)||p.qty+delta<0)fail(409,'Insufficient stock');p.qty+=delta;s.data.stockMoves??=[];s.data.stockMoves.push({id:randomUUID(),product:p.id,name:p.name,qty:delta,reason,date:now().slice(0,10)});}

async function handle(req,path,method,b,u){
 if(path==='/api/health')return json(null,{ok:true,backend:'supabase',version:'5.3'});
 if(path==='/api/me')return json(null,u?publicUser(u):null);
 let profiles=[];if(u&&['admin','cashier','tech'].includes(u.role))profiles=(await rest('ts_profiles?select=user_id,name,email,role,active')).map(({user_id,...x})=>({id:user_id,...x}));
 if(method==='POST'&&path==='/api/users'){need(u,['admin']);if(!['cashier','stock','tech','customer'].includes(b.role))fail(400,'Invalid role');if(typeof b.password!=='string'||b.password.length<12||new TextEncoder().encode(b.password).length>72)fail(400,'Password must be 12 characters minimum and 72 bytes maximum');let au=await adminAuth('users','POST',{email:email(b.email),password:b.password,email_confirm:true,user_metadata:{name:txt(b.name)||'User'}});if(!au.id)fail(502,'User creation failed');try{await rest('ts_profiles','POST',{user_id:au.id,name:txt(b.name)||'User',email:au.email,role:b.role},{Prefer:'resolution=merge-duplicates'});}catch(e){await adminAuth('users/'+au.id,'DELETE').catch(()=>{});throw e}await rest('ts_audit','POST',{actor:u.id,action:'create account '+au.id});return json(null,{id:au.id},201)}
 if(method==='POST'&&path==='/api/users/active'){need(u,['admin']);let p=profiles.find(x=>x.id===b.id);if(!p||p.role==='admin')fail(403,'Cannot modify this account');await rest('ts_profiles?user_id=eq.'+encodeURIComponent(p.id),'PATCH',{active:b.active===true});await rest('ts_audit','POST',{actor:u.id,action:'change account '+p.id});return json(null,{ok:true})}
 const ws=(await rest('ts_workspace?id=eq.1&select=revision,payload'))[0];if(!ws)fail(503,'Workspace unavailable');
 const s0={revision:Number(ws.revision),data:ws.payload.data||{}},rec=ws.payload.records||{};
 let dirty=false,action='update';
 const state=()=>s0,putState=(s,data)=>{s0.data=data;return s0.revision+1};
 const rows=k=>rec[k]||[];
 const record=(k,data,owner=null)=>{let r={...data,id:randomUUID(),owner,created:now()};(rec[k]??=[]).unshift(r);return r};
 const getRecord=(k,id)=>{let r=rows(k).find(x=>x.id===id);if(!r)fail(404,'Record not found');return r};
 const replaceRecord=(k,r,data)=>{let x={...data,id:r.id,owner:r.owner,created:r.created};rec[k][rec[k].findIndex(z=>z.id===r.id)]=x;return x};
 const audit=(_u,a)=>{action=a};
 const transaction=fn=>{const x=fn();dirty=true;return x};
 const points=id=>rows('loyalty').filter(r=>r.owner===id).reduce((n,r)=>n+Number(r.points||0),0);
 const notify=(owner,title,body)=>record('notifications',{title:txt(title),body:txt(body,1000)},owner);
 const res=null;
const fields={suppliers:['name','phone','email','address'],debts:['name','direction','amount','due','notes'],installments:['name','amount','count','due','notes'],used:['name','serial','condition','cost','price','notes'],offers:['title','description','end'],coupons:['code','percent','end'],repairs:['customer','phone','device','serial','fault','estimate','status','notes','customerId'],media:['name','image'],draft:['title','subtitle','accent','blocks','menu']};
function clean(kind,b){let o={};for(let k of fields[kind]||[])o[k]=txt(b[k],k==='image'?500000:k==='blocks'||k==='menu'?20000:1000);if(kind==='media'){o.image=safeImage(o.image);if(!o.image)fail(400,'PNG/JPEG/WebP required (under 350 KB)')}
if(kind==='coupons'){o.code=o.code.toUpperCase();o.percent=positive(o.percent);if(o.percent>100||!o.code)fail(400,'Invalid coupon')}
if(['debts','installments'].includes(kind))o.amount=positive(o.amount);
if(kind==='installments'){o.count=units(o.count);if(o.count>120)fail(400,'Too many installments');o.paid=0}
if(kind==='used'){o.cost=positive(o.cost,true);o.price=positive(o.price,true)}
if(kind==='repairs'){if(o.customerId&&!profiles.some(x=>x.id===o.customerId&&x.role==='customer'))fail(400,'Invalid customer account');o.estimate=positive(o.estimate,true);o.status='received'}
if(kind==='draft'){for(const k of ['blocks','menu']){try{o[k]=JSON.parse(o[k]||'[]')}catch{fail(400,'Invalid page JSON')}if(!Array.isArray(o[k])||o[k].length>50)fail(400,'Invalid page blocks')}o.blocks=o.blocks.map(x=>({title:txt(x.title),text:txt(x.text,3000),image:txt(x.image,80)}));o.menu=o.menu.map(x=>({label:txt(x.label),target:txt(x.target)}));o.accent=/^#[a-f0-9]{6}$/i.test(o.accent)?o.accent:'#1768db'}
return o}
function report(s){let sales=s.data.sales||[],expenses=s.data.expenses||[],total=sales.reduce((a,x)=>a+Number(x.total||0),0),cost=sales.reduce((a,x)=>a+Number(x.cost||0),0),expense=expenses.reduce((a,x)=>a+Number(x.amount||0),0);let cutoff=Date.now()-30*86400000;return {total,cost,expense,profit:total-cost-expense,forecast:(s.data.products||[]).map(p=>{let sold=sales.filter(x=>Date.parse(x.date)>=cutoff).flatMap(x=>x.items||[]).filter(x=>x.id===p.id).reduce((a,x)=>a+Number(x.qty||0),0);return {id:p.id,name:p.name,qty:p.qty,sold30:sold,days:sold?Math.round(p.qty*30/sold):null,suggestedPrice:Math.round(Number(p.cost||0)*1.25*100)/100}})}}

async function dispatch(){if(method==='GET'){
 if(path==='/api/health')return json(res,{ok:true});
 if(path==='/api/me')return json(res,u?publicUser(u):null);
 if(path==='/api/catalog'){let s=state(),site=rows('versions').find(x=>x.published);return json(res,{products:s.data.owner?.maintenance?[]:publicProducts(s),maintenance:!!s.data.owner?.maintenance,site:site?.page||null,media:rows('media').filter(m=>site?.page?.blocks?.some(b=>b.image===m.id)).map(m=>({id:m.id,name:m.name,image:m.image})),offers:rows('offers').filter(x=>!x.end||Date.parse(x.end)+86400000>Date.now()),currency:'USD'})}
 if(path==='/api/state'){need(u,['admin']);return json(res,state())}
 if(path==='/api/stock'){need(u,['admin','cashier','stock']);let s=state();return json(res,{products:(s.data.products||[]).map(p=>({id:p.id,name:p.name,sku:p.sku,qty:p.qty,price:p.price,...(u.role==='cashier'?{}:{cost:p.cost})})),sales:u.role==='stock'?[]:(s.data.sales||[]).map(({id,number,items})=>({id,number,items:items.map(({id,name,qty,price})=>({id,name,qty,price}))}))})}
 if(path==='/api/customers'){need(u,['admin','cashier','tech']);return json(res,profiles.filter(x=>x.role==='customer'&&x.active).map(({id,name,email})=>({id,name,email})))}
 if(path==='/api/users'){need(u,['admin']);return json(res,profiles)}
 if(path==='/api/audit'){need(u,['admin']);return json(res,(await rest('ts_audit?select=*&order=id.desc&limit=500')).map(x=>({...x,time:x.created_at})))}
 if(path==='/api/report'){need(u,['admin']);return json(res,report(state()))}
 if(path==='/api/account'){need(u);return json(res,{user:publicUser(u),points:points(u.id),orders:rows('orders').filter(r=>r.owner===u.id).map(({cost,items,...r})=>({...r,items:items.map(({cost,...i})=>i)})),repairs:rows('repairs').filter(r=>r.customerId===u.id).map(({device,status,estimate,created,id})=>({device,status,estimate,created,id})),warranties:rows('warranty').filter(r=>r.owner===u.id),notifications:rows('notifications').filter(r=>r.owner===u.id)})}
 if(path.startsWith('/api/records/')){let kind=path.split('/')[3];need(u,Object.hasOwn(rules,kind)?rules[kind]:[]);return json(res,kind==='orders'&&u.role!=='admin'?rows(kind).map(({cost,items,...r})=>({...r,items:(items||[]).map(({cost,...i})=>i)})):rows(kind))}
 fail(404,'Not found')
}

if(method!=='POST')fail(405,'Method not allowed');need(u);
if(path==='/api/state'){need(u,['admin']);return json(res,transaction(()=>{let s=state();if(b.revision!==s.revision)fail(409,'Revision conflict: reload before saving');let revision=putState(s,validateState(cleanState(b.data)));audit(u,'update legacy snapshot '+revision);return {revision}}))}
if(path==='/api/records'){let k=txt(b.kind);need(u,Object.hasOwn(rules,k)?rules[k]:[]);if(!Object.hasOwn(fields,k))fail(400,'Use dedicated operation');let data=clean(k,b);return json(res,transaction(()=>{let r=record(k,data);audit(u,'create '+k+' '+r.id);return r}),201)}
if(path==='/api/publish'||path==='/api/restore'){need(u,['admin']);return json(res,transaction(()=>{let source=getRecord(path==='/api/publish'?'draft':'versions',b.id);let page=path==='/api/publish'?{title:source.title,subtitle:source.subtitle,accent:source.accent,blocks:source.blocks,menu:source.menu}:source.page;let r=record('versions',{page,published:true});audit(u,'publish '+r.id);return r}))}
if(path==='/api/operation'){let k=txt(b.kind);need(u,Object.hasOwn(rules,k)?rules[k]:[]);return json(res,transaction(()=>{let s=state(),r;
 if(k==='purchases'){let p=product(s,b.product),qty=units(b.qty),cost=positive(b.cost,true);getRecord('suppliers',b.supplier);move(s,p,qty,'purchase');p.cost=cost;r=record(k,{product:p.id,name:p.name,qty,cost,total:qty*cost,supplier:b.supplier});putState(s,s.data)}
 else if(k==='inventory'){let p=product(s,b.product),qty=positive(b.qty,true);if(!Number.isSafeInteger(qty))fail(400,'Invalid stock count');let before=p.qty;move(s,p,qty-before,'inventory count');r=record(k,{product:p.id,name:p.name,before,qty,delta:qty-before,barcode:p.sku||p.id});putState(s,s.data)}
 else if(k==='returns'){let sale=(s.data.sales||[]).find(x=>x.id===b.sale),line=sale?.items?.find(x=>x.id===b.product);if(!line)fail(404,'Invoice item not found');let qty=units(b.qty),previous=rows('returns').filter(x=>x.sale===b.sale&&x.product===b.product).reduce((a,x)=>a+x.qty,0);if(qty+previous>line.qty)fail(409,'Quantity exceeds original sale');let p=product(s,b.product);move(s,p,qty,'return');r=record(k,{sale:b.sale,product:p.id,name:p.name,qty,refund:qty*line.price,reason:txt(b.reason)});s.data.expenses??=[];s.data.expenses.push({id:r.id,date:now().slice(0,10),desc:'Return '+sale.number,amount:r.refund-qty*Number(line.cost||0)});putState(s,s.data)}
 else if(k==='installments'||k==='debts'){let old=getRecord(k,b.id),amount=positive(b.amount),paid=Number(old.paid||0)+amount;if(paid>old.amount)fail(400,'Exceeds balance');let {id,owner,created,...d}=old;r=replaceRecord(k,old,{...d,paid});record('payments',{kind:k,reference:id,amount})}
 else if(k==='repairs'){let old=getRecord(k,b.id);if(!['received','diagnosed','approval','repairing','testing','ready','delivered','cancelled'].includes(b.status))fail(400,'Invalid status');let {id,owner,created,...d}=old;r=replaceRecord(k,old,{...d,status:b.status,notes:txt(b.notes,1000)});let user=profiles.find(x=>x.id===old.customerId&&x.role==='customer');if(user)notify(user.id,'Repair '+old.device,b.status)}
 else if(k==='orders'){let old=getRecord(k,b.id);if(!['pending','confirmed','delivered','cancelled'].includes(old.status))fail(409,'Invalid state');let allowed={pending:['confirmed','cancelled'],confirmed:['delivered','cancelled'],delivered:[],cancelled:[]};if(!allowed[old.status].includes(b.status))fail(409,'Invalid order transition');let {id,owner,created,...d}=old;if(b.status==='cancelled'){for(let i of old.items)move(s,product(s,i.id),i.qty,'cancel order');putState(s,s.data)}if(b.status==='delivered'){s.data.sales??=[];s.data.sales.push({id,number:'WEB-'+id.slice(0,8),date:now().slice(0,10),customer:old.customer,payment:'cod',paid:true,items:old.items,total:old.total,cost:old.cost});putState(s,s.data);if(owner)record('loyalty',{points:Math.floor(old.total),order:id},owner)}r=replaceRecord(k,old,{...d,status:b.status});if(owner)notify(owner,'Order '+id.slice(0,8),b.status)}
 else fail(400,'Unknown operation');audit(u,'operation '+k+' '+r.id);return r}))}
if(path==='/api/warranty'){need(u,['admin','cashier','tech']);return json(res,transaction(()=>{let serial=txt(b.serial),device=txt(b.device),months=units(b.months);if(!serial||!device||months>120)fail(400,'Invalid warranty');if(rows('warranty').some(x=>x.serial.toLowerCase()===serial.toLowerCase()))fail(409,'Duplicate serial');let customer=profiles.find(x=>x.id===txt(b.customerId)&&x.role==='customer');if(!customer)fail(400,'Invalid customer');let start=new Date(),end=new Date(start);end.setUTCMonth(end.getUTCMonth()+months);let w=record('warranty',{serial,device,months,start:start.toISOString().slice(0,10),end:end.toISOString().slice(0,10)},customer.id);notify(customer.id,'Warranty '+device,w.end);audit(u,'warranty '+w.id);return w}),201)}
if(path==='/api/pos'){need(u,['admin','cashier']);return json(res,transaction(()=>{let s=state(),qty=units(b.qty),p=product(s,b.product);move(s,p,-qty,'POS sale');let sale={id:randomUUID(),number:'POS-'+Date.now(),date:now().slice(0,10),customer:txt(b.customer),payment:'cash',paid:true,items:[{id:p.id,name:p.name,qty,price:p.price,cost:p.cost}],total:p.price*qty,cost:p.cost*qty};s.data.sales??=[];s.data.sales.push(sale);putState(s,s.data);audit(u,'POS '+sale.id);let {cost,items,...out}=sale;return {...out,items:items.map(({cost,...i})=>i)}}),201)}
if(path==='/api/order'){need(u,['customer']);return json(res,transaction(()=>{let s=state();if(s.data.owner?.maintenance)fail(409,'Store closed');if(!txt(b.phone)||!txt(b.address))fail(400,'Phone and address required');if(!Array.isArray(b.items)||!b.items.length||b.items.length>50)fail(400,'Invalid cart');let counts=new Map;for(let i of b.items)counts.set(i.id,(counts.get(i.id)||0)+units(i.qty));let items=[];for(let [id,qty] of counts){let p=product(s,id);if(p.hidden||(s.data.owner?.hiddenCategories||[]).includes(p.type))fail(409,'Unavailable');move(s,p,-qty,'web order reservation');items.push({id,name:p.name,qty,price:p.price,cost:p.cost})}let subtotal=items.reduce((a,i)=>a+i.price*i.qty,0),cost=items.reduce((a,i)=>a+i.cost*i.qty,0),coupon=rows('coupons').find(x=>x.code===txt(b.coupon).toUpperCase()&&(!x.end||Date.parse(x.end)+86400000>Date.now())),discount=coupon?subtotal*coupon.percent/100:0,total=Math.round((subtotal-discount)*100)/100;let order=record('orders',{customer:u.name,address:txt(b.address,1000),phone:txt(b.phone),items,total,cost,discount,status:'pending',payment:'cod'},u.id);putState(s,s.data);notify(u.id,'Order '+order.id.slice(0,8),'pending');audit(u,'order '+order.id);return {id:order.id,total,status:order.status}}),201)}
fail(404,'Not found')
}

 const result=await dispatch();
 if(dirty){let revision=await rest('rpc/ts_commit','POST',{p_revision:s0.revision,p_payload:{data:s0.data,records:rec},p_actor:u.id,p_action:action});if(revision===null)fail(409,'Revision conflict: refresh and retry')}
 return result;
}
Deno.serve(async req=>{
 const origin=req.headers.get('Origin');const headers={'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','Vary':'Origin','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'GET, POST, OPTIONS'};
 if(origin&&origins.has(origin))headers['Access-Control-Allow-Origin']=origin;
 if(origin&&!origins.has(origin))return new Response(JSON.stringify({error:'Origin not allowed'}),{status:403,headers});
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 try{if(!['GET','POST'].includes(req.method))fail(405,'Method not allowed');
 const path=new URL(req.url).searchParams.get('path')||'/api/health';
 if(!/^\/api\/[a-z]+(?:\/[a-z]+)?$/.test(path))fail(404,'Not found');
 let b={};if(req.method==='POST'){const limit=['/api/state','/api/records'].includes(path)?8000000:64000;if(Number(req.headers.get('content-length')||0)>limit)fail(413,'Payload too large');const raw=await req.text();if(new TextEncoder().encode(raw).length>limit)fail(413,'Payload too large');try{b=JSON.parse(raw)}catch{fail(400,'Invalid JSON')}if(!b||typeof b!=='object'||Array.isArray(b))fail(400,'Invalid JSON')}
 let u=path==='/api/health'||path==='/api/catalog'?null:await profile(req);
 // Use the same authorization and data projection for all authenticated workspace reads.
 if(req.method==='GET'&&(['/api/me','/api/stock','/api/customers','/api/account'].includes(path)||path.startsWith('/api/records/'))){
  if(!u&&path==='/api/me')return new Response('null',{status:200,headers});
  need(u);
  const caller=req.headers.get('Authorization')?.match(/^Bearer (.+)$/i)?.[1];
  if(!caller)fail(401,'Sign in required');
  const data=await upstream('/rest/v1/rpc/ts_read_workspace',{method:'POST',body:JSON.stringify({p_path:path.slice(5)})},PUB,caller);
  return new Response(JSON.stringify(data),{status:200,headers});
 }
 // Standalone debt and installment writes are now atomic ledger operations.
 if(req.method==='POST'&&['/api/records','/api/operation'].includes(path)&&['debts','installments'].includes(b.kind)){
  need(u);
  if(!b.request_id)fail(400,'Refresh TechStore before recording a financial operation');
  const caller=req.headers.get('Authorization')?.match(/^Bearer (.+)$/i)?.[1];
  if(!caller)fail(401,'Sign in required');
  const data=await upstream('/rest/v1/rpc/ts_legacy_finance',{method:'POST',body:JSON.stringify({p_action:path==='/api/records'?'create':'pay',p_kind:b.kind,p_args:b})},PUB,caller);
  return new Response(JSON.stringify(data),{status:path==='/api/records'?201:200,headers});
 }
 const r=await handle(req,path,req.method,b,u);return new Response(JSON.stringify(r.data),{status:r.status,headers});
 }catch(e){if(!e.status)console.error(String(e));return new Response(JSON.stringify({error:e.status?e.message:'Internal error'}),{status:e.status||500,headers})}
});
