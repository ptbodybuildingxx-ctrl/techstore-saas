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
function validReturn(x,store){return !!x&&x.store_id===store&&isId(x.id)&&isId(x.request_id)&&isId(x.sale_id)&&isId(x.product_id)&&currency(x.currency)&&int(x.units,1,10000)&&int(x.unit_price_minor,1,100000000)&&x.total_minor===x.units*x.unit_price_minor&&int(x.debt_reduction_minor,0,x.total_minor)&&x.refund_minor===x.total_minor-x.debt_reduction_minor&&typeof x.reason==='string'}
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
  async addCustomer(store,requestId,name,phone=''){
   if(!isId(requestId)||typeof name!=='string'||!name.trim()||name.trim().length>160||typeof phone!=='string'||phone.trim().length>60)throw Error('Invalid customer');
   const r=await rpc('mt_add_customer',{p_store:store,p_request:requestId,p_name:name.trim(),p_phone:phone.trim()},store);if(!isId(r))throw Error('Customer not confirmed');return r;
  },
  async customers(store,after=null,limit=50){
   if(!(after===null||isId(after))||!int(limit,1,100))throw Error('Invalid page');
   const r=await rpc('mt_list_customers',{p_store:store,p_after:after,p_limit:limit},store);
   if(!Array.isArray(r)||r.length>limit||r.some(x=>!x||x.store_id!==store||!isId(x.id)||typeof x.name!=='string'||typeof x.phone!=='string'))throw Error('Invalid customers');return r;
  },
  async recordCredit(attempt,terms){
   const x=saleAttempt(attempt.store,attempt.lines,attempt.currency,attempt.requestId);
   const total=x.lines.reduce((s,l)=>s+l.units*l.expected_price_minor,0);
   if(!terms||!isId(terms.customer)||!int(terms.deposit,0,total-1)||!int(terms.count,1,60)||total-terms.deposit<terms.count||typeof terms.due!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(terms.due)||!Number.isFinite(Date.parse(terms.due)))throw Error('Invalid credit terms');
   const r=await rpc('mt_record_credit_sale',{p_store:x.store,p_request:x.requestId,p_currency:x.currency,p_lines:x.lines,p_customer:terms.customer,p_deposit:terms.deposit,p_count:terms.count,p_due:terms.due},x.store);
   if(!r||!isId(r.id)||!int(r.number,1,Number.MAX_SAFE_INTEGER)||r.currency!==x.currency||r.request_id!==x.requestId||r.total_minor!==total)throw Error('Credit sale not confirmed');return r;
  },
  async debts(store,after=null,limit=50){
   if(!(after===null||isId(after))||!int(limit,1,100))throw Error('Invalid page');
   const r=await rpc('mt_list_debts',{p_store:store,p_after:after,p_limit:limit},store);
   if(!Array.isArray(r)||r.length>limit||r.some(x=>!x||x.store_id!==store||!isId(x.id)||!isId(x.sale_id)||!isId(x.customer_id)||!currency(x.currency)||!int(x.principal_minor,1,100000000000000)||!int(x.deposit_minor,0,x.principal_minor-1)||!int(x.remaining_minor,0,x.principal_minor-x.deposit_minor)||!int(x.installment_count,1,60)))throw Error('Invalid debts');return r;
  },
  async debtSchedule(store,debt){
   if(!isId(debt))throw Error('Invalid debt');
   const r=await rpc('mt_debt_schedule',{p_store:store,p_debt:debt},store);
   if(!Array.isArray(r)||r.length>60||r.some(x=>!x||x.store_id!==store||x.debt_id!==debt||!int(x.number,1,60)||typeof x.due_date!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(x.due_date)||!int(x.amount_minor,1,100000000000000)||!int(x.paid_minor,0,x.amount_minor)||!int(x.waived_minor,0,x.amount_minor-x.paid_minor)))throw Error('Invalid installments');return r;
  },
  async payDebt(store,debt,requestId,c,amount){
   if(!isId(debt)||!isId(requestId)||!currency(c)||!int(amount,1,100000000000000))throw Error('Invalid payment');
   const r=await rpc('mt_pay_debt',{p_store:store,p_debt:debt,p_request:requestId,p_currency:c,p_amount:amount},store);if(!isId(r))throw Error('Payment not confirmed');return r;
  },
  async receiveCostedStock(store,x){
   if(!x||!isId(x.product)||!isId(x.requestId)||!int(x.units,1,1000000000)||!currency(x.currency)||!int(x.cost,0,100000000)||typeof x.note!=='string'||!x.note.trim()||x.note.trim().length>300)throw Error('Invalid cost intake');
   const r=await rpc('mt_receive_costed_stock',{p_store:store,p_product:x.product,p_request:x.requestId,p_units:x.units,p_currency:x.currency,p_cost:x.cost,p_note:x.note.trim()},store);
   if(!int(r,0,1000000000))throw Error('Cost intake not confirmed');return r;
  },
  async saleMargin(store,sale){
   if(!isId(sale))throw Error('Invalid sale');
   const r=await rpc('mt_sale_margin',{p_store:store,p_sale:sale},store);
   const validAmounts=x=>!!x&&int(x.net_revenue_minor,0,100000000000000)&&(x.cost_minor===null?x.gross_margin_minor===null:int(x.cost_minor,0,100000000000000)&&x.gross_margin_minor===x.net_revenue_minor-x.cost_minor);
   if(!r||r.sale_id!==sale||!currency(r.currency)||!validAmounts(r)||!Array.isArray(r.lines)||r.lines.length<1||r.lines.length>100||r.lines.some(x=>!validAmounts(x)||!isId(x.product_id)||typeof x.product_name!=='string'||!int(x.units,1,10000)||!int(x.returned_units,0,x.units))||r.net_revenue_minor!==r.lines.reduce((s,x)=>s+x.net_revenue_minor,0)||(r.lines.some(x=>x.cost_minor===null)?r.cost_minor!==null:r.cost_minor!==r.lines.reduce((s,x)=>s+x.cost_minor,0)))throw Error('Invalid sale margin');
   return r;
  },
  async returnableLines(store,sale){
   if(!isId(sale))throw Error('Invalid sale');
   const r=await rpc('mt_returnable_lines',{p_store:store,p_sale:sale},store);
   if(!Array.isArray(r)||r.length>100||r.some(x=>!x||!isId(x.product_id)||typeof x.sku!=='string'||typeof x.product_name!=='string'||!int(x.units,1,10000)||!int(x.returned_units,0,x.units)||!int(x.unit_price_minor,1,100000000)||!currency(x.currency)))throw Error('Invalid sale lines');return r;
  },
  async recordReturn(store,x){
   if(!x||!isId(x.requestId)||!isId(x.sale)||!isId(x.product)||!int(x.units,1,10000)||typeof x.reason!=='string'||!x.reason.trim()||x.reason.trim().length>300||!currency(x.currency)||!int(x.price,1,100000000))throw Error('Invalid return');
   const r=await rpc('mt_record_return',{p_store:store,p_request:x.requestId,p_sale:x.sale,p_product:x.product,p_units:x.units,p_reason:x.reason.trim()},store);
   if(!validReturn(r,store)||r.request_id!==x.requestId||r.sale_id!==x.sale||r.product_id!==x.product||r.units!==x.units||r.currency!==x.currency||r.unit_price_minor!==x.price||r.reason!==x.reason.trim())throw Error('Return not confirmed');return r;
  },
  async returns(store,after=null,limit=50){
   if(!(after===null||isId(after))||!int(limit,1,100))throw Error('Invalid page');
   const r=await rpc('mt_list_returns',{p_store:store,p_after:after,p_limit:limit},store);
   if(!Array.isArray(r)||r.length>limit||r.some(x=>!validReturn(x,store)))throw Error('Invalid returns');return r;
  },
  async operationsList(store,kind,after=null,limit=50){
   if(!['suppliers','purchases','repairs','staff'].includes(kind)||!(after===null||isId(after))||!int(limit,1,100))throw Error('Invalid page');
   const r=await rpc(kind==='staff'?'mt_staff_list':'mt_list_'+kind,{p_store:store,p_after:after,p_limit:limit},store);
   if(!Array.isArray(r)||r.length>limit||r.some(x=>!x||(kind==='staff'?(!isId(x.user_id)||!['owner','stock','cashier','tech'].includes(x.role)||typeof x.active!=='boolean'):(x.store_id!==store||!isId(x.id)))))throw Error('Invalid operations page');return r;
  },
  async operation(store,x){
   if(!x||!isId(x.requestId))throw Error('Invalid operation');
   const req={p_store:store,p_request:x.requestId}, validText=(v,max)=>typeof v==='string'&&v.trim().length>0&&v.trim().length<=max;
   let name,params;
   switch(x.kind){
    case 'supplier':if(!validText(x.name,160)||typeof x.contact!=='string'||x.contact.length>160)throw Error('Invalid supplier');name='mt_add_supplier';params={p_name:x.name,p_contact:x.contact};break;
    case 'purchase':if(!isId(x.supplier)||!isId(x.product)||!currency(x.currency)||!int(x.units,1,1000000)||!int(x.cost,1,100000000)||!int(x.paid,0,x.units*x.cost)||!validText(x.note,300))throw Error('Invalid purchase');name='mt_purchase';params={p_supplier:x.supplier,p_product:x.product,p_currency:x.currency,p_units:x.units,p_cost:x.cost,p_paid:x.paid,p_note:x.note};break;
    case 'supplierPayment':if(!isId(x.purchase)||!currency(x.currency)||!int(x.amount,1,100000000000000))throw Error('Invalid payment');name='mt_pay_supplier';params={p_purchase:x.purchase,p_currency:x.currency,p_amount:x.amount};break;
    case 'repair':if(!isId(x.customer)||!validText(x.device,160)||!validText(x.fault,300)||!(x.imei===null||typeof x.imei==='string'&&/^\d{15}$/.test(x.imei)))throw Error('Invalid repair');name='mt_add_repair';params={p_customer:x.customer,p_device:x.device,p_imei:x.imei,p_fault:x.fault};break;
    case 'transition':if(!isId(x.repair)||!['diagnosing','repairing','ready','delivered','cancelled'].includes(x.next)||!validText(x.note,300))throw Error('Invalid transition');name='mt_repair_transition';params={p_repair:x.repair,p_next:x.next,p_note:x.note};break;
    case 'staff':if(!isId(x.user)||!['stock','cashier','tech'].includes(x.role)||typeof x.active!=='boolean')throw Error('Invalid staff');name='mt_staff_set';params={p_user:x.user,p_role:x.role,p_active:x.active};break;
    default:throw Error('Invalid operation');
   }
   const r=await rpc(name,{...req,...params},store);
   if(x.kind==='transition'?r!==x.next:!isId(r))throw Error('Operation not confirmed');return r;
  },
  async cashReport(store,from,to){
   if(![from,to].every(x=>typeof x==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(x)&&Number.isFinite(Date.parse(x)))||Date.parse(to)<Date.parse(from)||Date.parse(to)-Date.parse(from)>365*86400000)throw Error('Invalid date range');
   const r=await rpc('mt_cash_report',{p_store:store,p_from:from,p_to:to},store);
   if(!Array.isArray(r)||r.length>3||new Set(r.map(x=>x?.currency)).size!==r.length||r.some(x=>!x||!currency(x.currency)||!['incoming','outgoing','net','collections','refunds','supplier_payments','expenses'].every(k=>typeof x[k]==='string'&&/^-?\d+$/.test(x[k]))||BigInt(x.incoming)-BigInt(x.outgoing)!==BigInt(x.net)))throw Error('Invalid report');return r;
  },
  async cashOverview(store,before=null,beforeId=null,limit=50){
   if(!int(limit,1,100)||(before===null)!==(beforeId===null)||(before!==null&&(typeof before!=='string'||!Number.isFinite(Date.parse(before))||!isId(beforeId))))throw Error('Invalid cash page');
   const r=await rpc('mt_cash_overview',{p_store:store,p_before:before,p_before_id:beforeId,p_limit:limit},store);
   if(!r||!Array.isArray(r.balances)||r.balances.length>3||new Set(r.balances.map(x=>x?.currency)).size!==r.balances.length||r.balances.some(x=>!x||!currency(x.currency)||!int(x.balance_minor,0,Number.MAX_SAFE_INTEGER))||!Array.isArray(r.movements)||r.movements.length>limit||r.movements.some(x=>!x||!isId(x.id)||!['sale','funding','expense','exchange','debt_payment','return_refund','supplier_payment'].includes(x.kind)||!currency(x.currency)||!int(x.amount_minor,1,100000000000000)||typeof x.note!=='string'||typeof x.created_at!=='string'||!Number.isFinite(Date.parse(x.created_at))||(x.kind==='sale'?(!isId(x.sale_id)||x.request_id!==null):(!isId(x.request_id)||x.sale_id!==null))||(x.kind==='exchange'?(!currency(x.target_currency)||x.target_currency===x.currency||!int(x.target_amount_minor,1,100000000000000)):(x.target_currency!==null||x.target_amount_minor!==null))))throw Error('Invalid cash overview');
   return r;
  },
  async recordCash(store,attempt){
   const x=attempt;
   if(!x||!isId(x.requestId)||!['funding','expense','exchange'].includes(x.kind)||!currency(x.currency)||!int(x.amount,1,100000000000000)||typeof x.note!=='string'||!x.note.trim()||x.note.trim().length>300||(x.kind==='exchange'?(!currency(x.targetCurrency)||x.targetCurrency===x.currency||!int(x.targetAmount,1,100000000000000)):(x.targetCurrency!==null||x.targetAmount!==null)))throw Error('Invalid cash movement');
   const r=await rpc('mt_record_cash',{p_store:store,p_request:x.requestId,p_kind:x.kind,p_currency:x.currency,p_amount:x.amount,p_note:x.note.trim(),p_target_currency:x.targetCurrency,p_target_amount:x.targetAmount},store);
   if(!isId(r))throw Error('Cash movement not confirmed');return r;
  },
  async sales(store,before=null,limit=50){if(!(before===null||int(before,1,Number.MAX_SAFE_INTEGER))||!int(limit,1,100))throw Error('Invalid page');const r=await rpc('mt_list_sales',{p_store:store,p_before:before,p_limit:limit},store);if(!Array.isArray(r)||r.length>limit||r.some(x=>!x||x.store_id!==store||!isId(x.id)||!isId(x.request_id)||!int(x.number,1,Number.MAX_SAFE_INTEGER)||!currency(x.currency)||!['cash','credit'].includes(x.payment_mode)||!int(x.total_minor,1,100000000000000)))throw Error('Invalid sales page');return r}
 };
}
