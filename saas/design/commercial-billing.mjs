// Real external-receipt register, never a payment processor. Shared operator/owner display.
import {tr,currentLanguage} from './i18n.mjs';
const id=x=>typeof x==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(x);
const cents=x=>Number.isSafeInteger(x)&&x>=0&&x<=10000000;
const day=x=>typeof x==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(x);
const plan=x=>typeof x==='string'&&/^[a-z][a-z0-9-]{2,39}$/.test(x);
const states={unpaid:'غير مسددة',partial:'مسددة جزئياً',paid:'مسددة',refunded:'مستردة',void:'ملغاة'};
const channels={cash:'نقدي',bank_transfer:'حوالة مصرفية',other_external:'قبض خارجي آخر'};
export function validateBillingPage(r,store){
 if(!r||!plan(r.plan)||typeof r.name!=='string'||!cents(r.price)||r.price<100||typeof r.editable!=='boolean'||typeof r.more!=='boolean'||!Array.isArray(r.rows)||r.rows.length>50||r.rows.some(x=>!id(x.id)||x.store_id!==store||!plan(x.plan_code)||typeof x.store_name!=='string'||typeof x.plan_name!=='string'||!day(x.period_start)||!day(x.period_end)||!cents(x.amount_cents)||x.amount_cents<100||!cents(x.net_cents)||x.net_cents>x.amount_cents||x.currency!=='USD'||!Object.hasOwn(states,x.state)||typeof x.licensed!=='boolean'||typeof x.reference!=='string'))throw Error('Invalid invoice register');
 return r
}
export function validateBillingDetails(r){
 if(!r||!cents(r.net_cents)||typeof r.more!=='boolean'||!Array.isArray(r.rows)||r.rows.length>50||!Array.isArray(r.actions)||r.actions.length>50||r.rows.some(x=>!id(x.id)||!['payment','refund'].includes(x.kind)||!(x.kind==='refund'?id(x.original_id):x.original_id===null)||!cents(x.amount_cents)||x.amount_cents===0||!cents(x.refundable)||x.refundable>x.amount_cents||!Object.hasOwn(channels,x.channel)||typeof x.document_ref!=='string'||!day(x.occurred_on))||r.actions.some(x=>!id(x.id)||!['activate','void'].includes(x.kind)||typeof x.reference!=='string'))throw Error('Invalid invoice evidence');
 return r
}
const n=(tag,text)=>{const a=document.createElement(tag);if(text!==undefined)a.textContent=text;return a},t=(tag,x)=>n(tag,tr(x));
const fmt=x=>(x/100).toFixed(2)+' USD';
const nowDay=()=>{const p=Object.fromEntries(new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Damascus',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date()).map(x=>[x.type,x.value]));return p.year+'-'+p.month+'-'+p.day};
const when=x=>x?new Date(x).toLocaleString(currentLanguage()==='en'?'en-GB':'ar-SY',{timeZone:'Asia/Damascus'}):'—';
const minor=x=>{if(!/^\d{1,6}(?:\.\d{1,2})?$/.test(x))throw Error('Invalid USD amount');const [a,b='']=x.split('.'),v=Number(a)*100+Number(b.padEnd(2,'0'));if(!cents(v)||v<1)throw Error('Invalid USD amount');return v};
function table(headers,rows){const wrap=n('div'),tab=n('table'),h=n('thead'),hr=n('tr'),b=n('tbody');wrap.className='scroll';for(const k of headers)hr.append(t('th',k));h.append(hr);tab.append(h,b);for(const cells of rows){const row=n('tr');for(const v of cells){const td=n('td');if(v instanceof Node)td.append(v);else td.textContent=String(v??'—');row.append(td)}b.append(row)}wrap.append(tab);return wrap}
export function createCommercialBilling({api,root,run,active=()=>api.signedIn(),admin=false}){
 const area=n('div'),detail=n('div'),notice=n('p');root.append(area,notice,detail);let store=null,offset=0,pending=null;
 const button=(title,fn)=>{const b=t('button',title);b.type='button';b.onclick=()=>run(fn);return b};
 const field=(type='text',max=200)=>{const x=n('input');x.type=type;x.required=true;x.maxLength=max;return x};
 const select=values=>{const x=n('select');for(const [v,label] of values){const o=t('option',label);o.value=v;x.append(o)}return x};
 function form(title,fields,submit){const f=n('form');for(const [name,x] of fields){const l=t('label',name);l.append(x);f.append(l)}const b=t('button',title);b.type='submit';f.append(b);f.onsubmit=e=>{e.preventDefault();run(async()=>{if(pending||!active())return;await submit(...fields.map(([,x])=>x.value.trim()))})};return f}
 function retry(){notice.replaceChildren(t('span','إجراء غير مؤكد؛ استخدم إعادة الطلب نفسه.'),n('code',pending.req),button('إعادة الطلب نفسه',send),button('مراجعة حالة الإجراء',()=>load(store,offset)),button('ترك الطلب غير المؤكد بعد المراجعة',async()=>{if(confirm(tr('راجع السجل والحالة قبل بدء إجراء جديد. هل تريد ترك المرجع غير المؤكد؟'))){pending=null;notice.replaceChildren();await load(store,offset)}}))}
 async function start(kind,params){if(!admin||pending||!active())return;pending={kind,store,req:crypto.randomUUID(),...params};retry();await send()}
 async function send(){if(!pending||!active())return;const p=pending;await api.commercialBillingWrite(p.store,p.kind,p);pending=null;notice.replaceChildren(t('span','تم الحفظ'),n('code',p.req));await load(p.store,offset)}
 async function showInvoice(i,editable,off=0){const s=store,r=await api.commercialBillingDetails(s,i.id,off);if(!active()||store!==s)return;detail.replaceChildren(n('h3',i.store_name+' — '+i.period_start.slice(0,7)),n('p',i.plan_name+' — '+fmt(i.amount_cents)),n('p',tr('صافي المقبوض')+': '+fmt(r.net_cents)+' / '+tr('المبلغ المتبقي')+': '+fmt(i.amount_cents-r.net_cents)),n('code',i.id),n('p',i.reference),t('p','سجل المدفوعات الخارجية ليس بوابة دفع ولا فاتورة ضريبية معتمدة.'));
  if(admin&&editable&&!pending&&i.state!=='void'){
   if(r.net_cents<i.amount_cents){const a=field(),m=select(Object.entries(channels)),ref=field('text',160),d=field('date');a.inputMode='decimal';d.value=nowDay();detail.append(form('تسجيل قبض خارجي فعلي',[['المبلغ USD',a],['طريقة القبض',m],['مرجع سند القبض',ref],['تاريخ القبض',d]],async(amount,method,proof,day_value)=>{const v=minor(amount);if(v>i.amount_cents-r.net_cents||!proof||!confirm(tr('أؤكد أن المبلغ قُبض فعلياً خارج المنصة وفق المستند المشار إليه.')))return;await start('record',{i:i.id,k:'payment',orig:null,amount:v,method,proof,day_value,expected:r.net_cents})}))}
   if(r.net_cents===i.amount_cents&&!i.licensed&&nowDay()>=i.period_start&&nowDay()<i.period_end)detail.append(form('تفعيل ترخيص الفترة المسددة',[['سبب الإجراء أو مرجع الموافقة',field()]],async proof=>{if(!proof||!confirm(tr('تفعيل الترخيص لهذه الفترة فقط بعد مطابقة القبض؟')))return;await start('action',{i:i.id,k:'activate',proof})}));
   if(r.net_cents===0)detail.append(form('إلغاء الفاتورة غير المسددة',[['سبب الإجراء أو مرجع الموافقة',field()]],async proof=>{if(!proof||!confirm(tr('إلغاء الفاتورة مع الاحتفاظ بسجلها؟')))return;await start('action',{i:i.id,k:'void',proof})}));
  }
  const action=p=>{if(!admin||!editable||pending||i.state==='void'||p.kind!=='payment'||p.refundable===0)return '—';const a=field(),m=select(Object.entries(channels)),ref=field('text',160),d=field('date');d.value=nowDay();a.inputMode='decimal';return form('تسجيل استرداد خارجي فعلي',[['المبلغ USD',a],['طريقة القبض',m],['مرجع سند الاسترداد',ref],['تاريخ الاسترداد',d]],async(amount,method,proof,day_value)=>{const v=minor(amount);if(v>p.refundable||v>r.net_cents||!proof||!confirm(tr('أؤكد رد المبلغ فعلياً خارج المنصة. سيُلغى الترخيص المرتبط بهذه الفاتورة إن وجد.')))return;await start('record',{i:i.id,k:'refund',orig:p.id,amount:v,method,proof,day_value,expected:r.net_cents})})};
  detail.append(t('h4','سجل القبض والاسترداد'),table(['النوع','المبلغ','الطريقة','المرجع','التاريخ','الإجراء'],r.rows.map(p=>[tr(p.kind==='payment'?'قبض':'استرداد'),fmt(p.amount_cents),tr(channels[p.channel]),p.document_ref,p.occurred_on,action(p)])));
  if(off>0)detail.append(button('الأولى',()=>showInvoice(i,editable,0)));if(r.more)detail.append(button('التالي',()=>showInvoice(i,editable,off+50)));
  detail.append(t('h4','سجل إجراءات الفاتورة'),table(['الإجراء','المرجع','التاريخ'],r.actions.map(a=>[tr(a.kind==='activate'?'تفعيل ترخيص الفترة المسددة':'إلغاء الفاتورة غير المسددة'),a.reference,when(a.created_at)])));
 }
 async function load(s,off=0){if(!active())return;if(pending&&pending.store!==s)throw Error('Resolve previous billing action');const r=await api.commercialBilling(s,off);if(!active())return;store=s;offset=off;area.replaceChildren(t('h3','فواتير الاشتراكات والقبض الخارجي'),t('p','الفواتير بالدولار وفق سعر الباقة وقت الإصدار. لا يتم تحصيل الأموال أو إرسالها آلياً. المدفوعات الموثقة تسجل فقط بعد قبضها فعلياً خارج المنصة.'),n('p',r.name+' — '+fmt(r.price)));detail.replaceChildren();if(pending)retry();
  if(admin&&r.editable&&!pending){const month=field('month'),proof=field();month.value=nowDay().slice(0,7);area.append(form('إصدار فاتورة اشتراك',[['شهر الاشتراك',month],['مرجع اتفاق الاشتراك',proof]],async(m,ref)=>{if(!/^\d{4}-\d{2}$/.test(m)||!ref||!confirm(tr('إصدار مطالبة اشتراك فعلية دون تحصيل تلقائي؟')+' — '+fmt(r.price)))return;await start('create',{month_value:m+'-01',expected_plan:r.plan,expected_price:r.price,proof:ref})}))}
  area.append(table(['شهر الاشتراك','الباقة','الإجمالي','صافي المقبوض','الحالة','الترخيص','الإجراء'],r.rows.map(i=>[i.period_start.slice(0,7),i.plan_name,fmt(i.amount_cents),fmt(i.net_cents),tr(states[i.state]),tr(i.licensed?'ساري':'غير متاح'),button('عرض الفاتورة والسندات',()=>showInvoice(i,r.editable))])));
  if(off>0)area.append(button('الأولى',()=>load(s,0)));if(r.more)area.append(button('التالي',()=>load(s,off+50)));
 }
 return {load,reset(){pending=null;store=null;offset=0;area.replaceChildren();notice.replaceChildren();detail.replaceChildren()}}
}
