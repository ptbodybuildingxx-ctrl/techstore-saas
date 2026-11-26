// Administrative catalog and module controls; credentials never pass through these screens.
import {tr,currentLanguage} from '../design/i18n.mjs';
const n=(tag,text)=>{const a=document.createElement(tag);if(text!==undefined)a.textContent=text;return a};
const t=(tag,text)=>n(tag,tr(text));
const when=x=>x?new Date(x).toLocaleString(currentLanguage()==='en'?'en-GB':'ar-SY',{timeZone:'Asia/Damascus'}):'—';
const label=(title,field)=>{const a=t('label',title);a.append(field);return a};
const button=(title,run,fn)=>{const b=t('button',title);b.type='button';b.onclick=()=>run(fn);return b};
const field=(max=200)=>{const i=n('input');i.required=true;i.maxLength=max;return i};
const yes=v=>tr(v?'نعم':'لا');
const roles={owner:'مالك المحل',cashier:'أمين الصندوق',stock:'موظف المخزون',tech:'فني الصيانة'};
export const moduleLabels=Object.freeze({catalog:'إنشاء المنتجات',sales:'إصدار المبيعات والفواتير',purchases:'استلام المشتريات الجديدة',suppliers:'إضافة الموردين',customers:'إضافة العملاء',credit:'إنشاء مبيعات آجلة وأقساط',standalone_debts:'فتح ديون مستقلة',repairs:'استلام طلبات الصيانة',quotes:'إصدار عروض الأسعار',stock_counts:'تسجيل الجرد',stock_transfers:'نقل المخزون',branches:'إنشاء الفروع',payroll:'فتح مسيرات الرواتب',tradein:'إنشاء تقديرات الاستبدال',coupons:'إنشاء الكوبونات'});
function table(headers,rows){const wrap=n('div'),tab=n('table'),head=n('thead'),hr=n('tr'),tb=n('tbody');wrap.className='scroll';for(const h of headers)hr.append(t('th',h));head.append(hr);tab.append(head,tb);for(const cells of rows){const row=n('tr');for(const v of cells){const td=n('td');if(v instanceof Node)td.append(v);else td.textContent=String(v??'—');row.append(td)}tb.append(row)}wrap.append(tab);return wrap}
function retryPanel({pending,run,send,load,abandon}){const d=n('div');d.append(t('p','إجراء غير مؤكد؛ استخدم إعادة الطلب نفسه.'),n('code',pending.request),button('إعادة الطلب نفسه',run,send),button('مراجعة حالة الإجراء',run,load),button('ترك الطلب غير المؤكد بعد المراجعة',run,async()=>{if(confirm(tr('راجع السجل والحالة قبل بدء إجراء جديد. هل تريد ترك المرجع غير المؤكد؟'))){abandon();await load()}}));return d}
export function createCatalogControl({api,root,run,onChanged}){
 const area=n('div');root.append(button('تحديث كتالوج الباقات',run,load),area);
 let pending=null;
 async function send(){if(!pending||!api.signedIn())return;const p=pending;await api.planCatalogChange(p);pending=null;await load();await onChanged()}
 async function load(){
  const r=await api.planCatalogReview();if(!api.signedIn())return;if(pending&&r.history.some(x=>x.request_id===pending.request))pending=null;
  area.replaceChildren(t('p','الباقة الجديدة تبدأ مغلقة للتسجيل. فعّلها من صلاحيات الباقات بعد إعداد خصائصها. الحذف النهائي للباقات الجديدة غير المستخدمة فقط؛ استخدم إغلاق التسجيل للباقات المرتبطة بالسجلات.'));
  if(pending)area.append(retryPanel({pending,run,send,load,abandon:()=>{pending=null}}));
  const price=v=>(v/100).toFixed(2)+' USD',state=p=>({code:p.code,name:p.name,monthly_usd_cents:p.monthly_usd_cents});
  const actions=p=>{const d=n('div');if(!r.editable||pending)return d;
   const name=field(100),proof=field(),f=n('form'),submit=t('button','تعديل اسم الباقة');submit.type='submit';name.value=p.name;f.append(label('اسم الباقة',name),label('سبب الإجراء أو مرجع الموافقة',proof),submit);
   f.onsubmit=e=>{e.preventDefault();run(async()=>{if(pending||!name.value.trim()||name.value.trim()===p.name||!proof.value.trim())return;if(!confirm(tr('تعديل اسم الباقة')+' — '+p.code+'؟'))return;await start({action:'rename',code:p.code,expected:state(p),params:{name:name.value.trim()},reference:proof.value.trim()})})};d.append(f);
   if(p.deletable){const f2=n('form'),ref=field(),remove=t('button','حذف الباقة غير المستخدمة');remove.type='submit';f2.append(label('سبب الإجراء أو مرجع الموافقة',ref),remove);f2.onsubmit=e=>{e.preventDefault();run(async()=>{if(pending||!ref.value.trim()||!confirm(tr('حذف الباقة غير المستخدمة نهائياً؟')+' — '+p.code))return;await start({action:'delete',code:p.code,expected:state(p),params:{},reference:ref.value.trim()})})};d.append(f2)}return d};
  area.append(table(['المعرّف','اسم الباقة','السعر الشهري','قبول محلات جديدة في الباقة','المحلات','الإجراءات الإدارية'],r.plans.map(p=>[p.code,p.name,price(p.monthly_usd_cents),yes(p.enrollment),p.subscribers,actions(p)])));
  if(r.editable&&!pending){const f=n('form'),code=field(40),name=field(100),amount=field(12),ref=field(),submit=t('button','إنشاء باقة جديدة');code.pattern='[a-z][a-z0-9-]{2,39}';amount.inputMode='decimal';amount.placeholder='10.00';submit.type='submit';f.append(label('معرّف الباقة (أحرف لاتينية صغيرة)',code),label('اسم الباقة',name),label('السعر الشهري USD',amount),label('سبب الإجراء أو مرجع الموافقة',ref),submit);f.onsubmit=e=>{e.preventDefault();run(async()=>{const v=amount.value.trim();if(pending||!/^[0-9]{1,6}(?:\.[0-9]{1,2})?$/.test(v)||!name.value.trim()||!ref.value.trim())return;const [whole,fraction='']=v.split('.'),price=Number(whole)*100+Number(fraction.padEnd(2,'0'));if(price<100||price>10000000)throw Error('Invalid price');if(!confirm(tr('إنشاء باقة جديدة')+' — '+code.value+'؟'))return;await start({action:'create',code:code.value,expected:null,params:{name:name.value.trim(),price},reference:ref.value.trim()})})};area.append(f)}
  if(!r.editable)area.append(t('p','تعديل الكتالوج مقفل بسبب ارتباط الفوترة.'));
  const describe=x=>x?x.name+' · '+price(x.monthly_usd_cents):'—';area.append(t('h3','سجل كتالوج الباقات'),table(['التاريخ','المعرّف','الإجراء','المرجع','المدير','قبل','بعد'],r.history.map(h=>[when(h.created_at),h.plan_code,tr(({create:'إنشاء باقة جديدة',rename:'تعديل اسم الباقة',delete:'حذف الباقة غير المستخدمة'})[h.action]),h.reference,h.actor,describe(h.before_state),describe(h.after_state)])));
 }
 async function start(x){if(pending)return;pending={...x,request:crypto.randomUUID()};area.replaceChildren(retryPanel({pending,run,send,load,abandon:()=>{pending=null}}));await send()}
 return {load,reset(){pending=null;area.replaceChildren()}}
}
export function createModuleControl({api,root,run}){
 const area=n('div');root.append(button('تحديث وحدات الباقات',run,load),area);let pending=null;
 async function send(){if(!pending||!api.signedIn())return;await api.modulesChange(pending);pending=null;await load()}
 async function load(){
  const r=await api.modulesReview();if(!api.signedIn())return;if(pending&&r.history.some(x=>x.request_id===pending.request))pending=null;
  area.replaceChildren(t('p','تتحكم هذه المفاتيح بإنشاء سجلات تشغيلية جديدة من الخادم. لا تحذف البيانات أو تمنع قراءة السجلات السابقة. قد تتطلب عملية واحدة أكثر من وحدة، مثل البيع الآجل أو الاستبدال. إيقاف المبيعات يمنع تحويل الطلب إلى فاتورة جديدة.'));
  if(pending)area.append(retryPanel({pending,run,send,load,abandon:()=>{pending=null}}));
  for(const p of r.plans){const f=n('form'),fs=n('fieldset'),legend=n('legend',p.name+' ('+p.code+')'),inputs={},ref=field(),submit=t('button','حفظ وحدات الباقة');submit.type='submit';fs.append(legend);
   for(const [key,title] of Object.entries(moduleLabels)){const i=n('input');i.type='checkbox';i.checked=p.flags[key];const l=t('label',title);l.prepend(i);fs.append(l);inputs[key]=i}
   fs.append(label('سبب الإجراء أو مرجع الموافقة',ref),submit);fs.disabled=!!pending;f.append(fs);f.onsubmit=e=>{e.preventDefault();run(async()=>{if(pending||!ref.value.trim())return;const flags=Object.fromEntries(Object.keys(moduleLabels).map(k=>[k,inputs[k].checked]));if(Object.keys(flags).every(k=>flags[k]===p.flags[k])||!confirm(tr('تأكيد تغيير وحدات جميع محلات هذه الباقة؟')+' — '+p.name))return;pending={request:crypto.randomUUID(),plan:p.code,expected:p.revision,flags,reference:ref.value.trim()};area.replaceChildren(retryPanel({pending,run,send,load,abandon:()=>{pending=null}}));await send()})};area.append(f)}
  const changed=h=>Object.keys(moduleLabels).filter(k=>h.before_flags[k]!==h.after_flags[k]).map(k=>tr(moduleLabels[k])+': '+yes(h.before_flags[k])+' → '+yes(h.after_flags[k])).join(' · ');
  area.append(t('h3','سجل تعديلات وحدات الباقات'),table(['التاريخ','الباقة','المرجع','المدير','التغييرات'],r.history.map(h=>[when(h.created_at),h.plan_code,h.reference,h.actor,changed(h)])));
 }
 return {load,reset(){pending=null;area.replaceChildren()}}
}
export function createMemberControl({api,root,run}){
 const dialog=n('dialog'),body=n('div'),close=button('إغلاق',run,async()=>dialog.close());dialog.append(body,close);root.append(dialog);
 let pending=null,selected=null;
 async function send(){if(!pending||!api.signedIn())return;const p=pending;await api.memberChange(p);pending=null;await show(p.store)}
 async function show(store,offset=0){
  if(pending&&pending.store!==store)throw Error('Resolve previous account action');const r=await api.membersReview(store,offset);if(!api.signedIn())return;selected=store;
  if(pending&&r.history.some(x=>x.request_id===pending.request))pending=null;
  body.replaceChildren(t('h2','إدارة وصول حسابات المحل'),n('code',store),t('p','الإيقاف المركزي يمنع دخول الحساب إلى هذا المحل فقط، ولا يغير كلمة المرور أو دور العضو أو صلاحياته في المحلات الأخرى. رفع الإيقاف لا يعيد تنشيط عضوية أوقفها المالك.'));
  const load=()=>show(store);
  if(pending)body.append(retryPanel({pending,run,send,load,abandon:()=>{pending=null}}));
  const action=m=>{if(pending)return '—';const f=n('form'),ref=field(),submit=t('button',m.blocked?'رفع إيقاف الحساب المركزي':'إيقاف وصول الحساب للمحل');submit.type='submit';f.append(label('سبب الإجراء أو مرجع الموافقة',ref),submit);f.onsubmit=e=>{e.preventDefault();run(async()=>{if(pending||selected!==store||!ref.value.trim()||!dialog.open)return;if(!confirm(tr(m.blocked?'رفع إيقاف الحساب المركزي':'إيقاف وصول الحساب للمحل')+' — '+(m.display_name||m.user_id)+'؟'))return;pending={store,request:crypto.randomUUID(),user:m.user_id,expected:m.revision,role:m.role,active:m.active,blocked:!m.blocked,reference:ref.value.trim()};body.replaceChildren(retryPanel({pending,run,send,load,abandon:()=>{pending=null}}));await send()})};return f};
  body.append(table(['الحساب','الاسم','الدور','العضوية نشطة','الإيقاف المركزي','الإجراء'],r.members.map(m=>[m.user_id,m.display_name||'—',tr(roles[m.role]),yes(m.active),yes(m.blocked),action(m)])));
  if(offset>0)body.append(button('الأولى',run,load));if(r.more)body.append(button('التالي',run,()=>show(store,offset+50)));
  body.append(t('h3','سجل إدارة وصول الحسابات'),table(['التاريخ','الحساب','المرجع','المدير','قبل','بعد'],r.history.map(h=>[when(h.created_at),h.user_id,h.reference,h.actor,yes(h.previous_blocked),yes(h.blocked)])));
  if(!dialog.open)dialog.showModal();
 }
 return {show,reset(){pending=null;selected=null;if(dialog.open)dialog.close();body.replaceChildren()}}
}
