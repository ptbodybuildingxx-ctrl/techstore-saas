const origin='https://mezsyzdieqmqulddcrtg.supabase.co';
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const isId=x=>typeof x==='string'&&uuid.test(x);
const currency=x=>['SYP','USD','EUR'].includes(x);
const int=(x,min,max)=>Number.isSafeInteger(x)&&x>=min&&x<=max;
export function saleAttempt(store,lines,c,requestId=crypto.randomUUID()){
 if(!currency(c)||!isId(store)||!isId(requestId)||!Array.isArray(lines)||lines.length<1||lines.length>100||lines.some(x=>!x||!isId(x.product_id)||!int(x.units,1,10000)||!int(x.expected_price_minor,1,100000000)))throw Error('Invalid cart');
 const normalized=lines.map(x=>Object.freeze({product_id:x.product_id.toLowerCase(),units:x.units,expected_price_minor:x.expected_price_minor})).sort((a,b)=>a.product_id.localeCompare(b.product_id));
 if(new Set(normalized.map(x=>x.product_id)).size!==normalized.length)throw Error('Duplicate product');
 return Object.freeze({store:store.toLowerCase(),requestId:requestId.toLowerCase(),currency:c,lines:Object.freeze(normalized)});
}
export function createTenantApi({url,publishableKey,fetcher=fetch,clock=Date.now}){
 if(url!==origin||typeof publishableKey!=='string'||!/^sb_publishable_[A-Za-z0-9_-]{20,200}$/.test(publishableKey))throw Error('Invalid shared project configuration');
 let session=null,allowed=new Set(),epoch=0;
 function clear(){session=null;allowed=new Set();epoch++}
 async function request(path,body,token){
  const r=await fetcher(url+path,{method:'POST',headers:{apikey:publishableKey,'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:body===undefined?undefined:JSON.stringify(body),cache:'no-store',redirect:'error',credentials:'omit'});
  if(!r.ok){const e=Error('Request not confirmed');e.status=r.status;throw e}
  return r.status===204?null:r.json();
 }
 async function rpc(name,args,store=null){
  if(!session||session.expires<=clock()+5000){clear();throw Error('Sign in again')}
  if(store!==null&&(!isId(store)||!allowed.has(store.toLowerCase())))throw Error('Select your assigned store');
  const e=epoch;
  try{const r=await request('/rest/v1/rpc/'+name,args,session.token);if(e!==epoch)throw Error('Session changed');return r}
  catch(err){if(e===epoch&&(err.status===401||err.status===403))clear();throw err}
 }
 return {
  async signIn(email,password){
   clear();const e=epoch;
   if(typeof email!=='string'||!email.trim()||typeof password!=='string'||!password)throw Error('Email and password required');
   const r=await request('/auth/v1/token?grant_type=password',{email:email.trim(),password});
   if(e!==epoch||typeof r?.access_token!=='string'||!r.access_token||!Number.isFinite(r.expires_in)||r.expires_in<=0)throw Error('Invalid login');
   session={token:r.access_token,expires:clock()+r.expires_in*1000};
   try{const stores=await this.stores();if(!stores.length)throw Error('No tenant membership');return stores}catch(err){if(e===epoch)clear();throw err}
  },
  signedIn(){return !!session&&session.expires>clock()+5000},
  async signOut(){const s=session;clear();if(s)await request('/auth/v1/logout?scope=local',undefined,s.token)},
  async stores(){
   const r=await rpc('mt_my_stores',{});
   if(!Array.isArray(r)||r.some(x=>!x||!isId(x.id)||typeof x.name!=='string'||typeof x.slug!=='string'||!['owner','stock','cashier','tech'].includes(x.role)||typeof x.can_write!=='boolean'))throw Error('Invalid stores');
   allowed=new Set(r.map(x=>x.id.toLowerCase()));return r;
  },
  async context(store){const r=await rpc('mt_sale_context',{p_store:store},store);if(!r||!(r.currency===null||currency(r.currency))||!Array.isArray(r.currencies)||r.currencies.length>3||r.currencies.some(x=>!currency(x))||new Set(r.currencies).size!==r.currencies.length||(r.currency===null?r.currencies.length!==0:!r.currencies.includes(r.currency))||typeof r.can_sell!=='boolean'||typeof r.can_price!=='boolean')throw Error('Invalid context');return r},
  async products(store,c=null,after=null,limit=50){
   if(!(c===null||currency(c))||!(after===null||isId(after))||!int(limit,1,100))throw Error('Invalid page');
   const r=await rpc('mt_list_currency_products',{p_store:store,p_currency:c,p_after:after,p_limit:limit},store);
   if(!Array.isArray(r)||r.length>limit||r.some(x=>!x||x.store_id!==store||!isId(x.id)||typeof x.sku!=='string'||typeof x.name!=='string'||!int(x.quantity,0,1000000000)||!(x.unit_price_minor===null||int(x.unit_price_minor,1,100000000))))throw Error('Invalid product page');
   return r;
  },
  async configure(store,c){if(!currency(c))throw Error('Invalid currency');const r=await rpc('mt_configure_sales',{p_store:store,p_currency:c},store);if(r!==c)throw Error('Currency not confirmed');return r},
  async addProduct(store,sku,name){if(typeof sku!=='string'||!sku.trim()||sku.trim().length>80||typeof name!=='string'||!name.trim()||name.trim().length>160)throw Error('Invalid product');const r=await rpc('mt_add_product',{p_store:store,p_sku:sku.trim(),p_name:name.trim()},store);if(!isId(r))throw Error('Product not confirmed');return r},
  async adjustStock(store,product,delta,requestId){if(!isId(product)||!isId(requestId)||!int(delta,-1000000000,1000000000)||delta===0)throw Error('Invalid adjustment');const r=await rpc('mt_adjust_stock',{p_store:store,p_product:product,p_delta:delta,p_request:requestId},store);if(!int(r,0,1000000000))throw Error('Stock not confirmed');return r},
  async setPrice(store,product,c,price){if(!currency(c)||!isId(product)||!int(price,1,100000000))throw Error('Invalid price');const r=await rpc('mt_set_currency_price',{p_store:store,p_product:product,p_currency:c,p_price:price},store);if(r!==price)throw Error('Price not confirmed');return r},
  async recordSale(attempt){
   const x=saleAttempt(attempt.store,attempt.lines,attempt.currency,attempt.requestId);
   const r=await rpc('mt_record_currency_sale',{p_store:x.store,p_request:x.requestId,p_currency:x.currency,p_lines:x.lines},x.store);
   const total=x.lines.reduce((s,l)=>s+l.units*l.expected_price_minor,0);
   if(!r||!isId(r.id)||!int(r.number,1,Number.MAX_SAFE_INTEGER)||r.currency!==x.currency||r.request_id!==x.requestId||r.total_minor!==total)throw Error('Sale not confirmed');
   return r;
  },
  async sales(store,before=null,limit=50){if(!(before===null||int(before,1,Number.MAX_SAFE_INTEGER))||!int(limit,1,100))throw Error('Invalid page');const r=await rpc('mt_list_sales',{p_store:store,p_before:before,p_limit:limit},store);if(!Array.isArray(r)||r.length>limit||r.some(x=>!x||x.store_id!==store||!isId(x.id)||!isId(x.request_id)||!int(x.number,1,Number.MAX_SAFE_INTEGER)||!currency(x.currency)||!int(x.total_minor,1,100000000000000)))throw Error('Invalid sales page');return r}
 };
}
