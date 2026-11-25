import {configuration} from './config.mjs';
import {createAdminApi} from './api.mjs';
const api=createAdminApi(configuration),el=id=>document.getElementById(id);
const labels={provisioning:'قيد الإعداد',ready:'جاهز',suspended:'موقوف',closed:'مغلق',pending:'قيد الانتظار',trial:'تجريبي إداري',active:'نشط',past_due:'متأخر',cancelled:'ملغى',basic:'Basic',business:'Business',pro:'Business Pro'};
const node=(tag,text,cls)=>{const n=document.createElement(tag);n.textContent=text;if(cls)n.className=cls;return n};
let offset=0,limit=25,busy=false;
function setMessage(text){el('message').textContent=text}
function loggedOut(){el('billingRows').replaceChildren();el('billingStore').replaceChildren();el('billingMonth').textContent='';el('billingForm').reset();el('backupRows').replaceChildren();el('backupRequests').replaceChildren();el('backupStore').replaceChildren();el('backupRequest').reset();el('releaseRows').replaceChildren();el('releaseTargets').replaceChildren();el('releaseChoice').replaceChildren();el('releaseStore').replaceChildren();el('releaseRegister').reset();el('contact').reset();el('contactStatus').textContent='';el('dashboard').hidden=true;el('logout').hidden=true;el('loginPanel').hidden=false;el('rows').replaceChildren();el('metrics').replaceChildren()}
function loggedIn(){el('loginPanel').hidden=true;el('logout').hidden=false;el('dashboard').hidden=false}
async function run(fn){
 if(busy)return;busy=true;
 const controls=[...document.querySelectorAll('button')];for(const x of controls)x.disabled=true;
 try{await fn()}catch(e){setMessage(e.status===401||e.status===403?'تم رفض الصلاحية أو انتهت الجلسة.':e.status===409?'المعرّف مستخدم مسبقاً.':'لم يتم تأكيد الطلب. تحقق من الحالة قبل إعادة المحاولة.');if(!api.signedIn())loggedOut()}
 finally{busy=false;for(const x of controls)if(x.id!=='prev'&&x.id!=='next'&&x.id!=='releasePlanButton'&&x.id!=='backupRequestButton'&&x.id!=='billingDraftButton')x.disabled=false;el('prev').disabled=offset===0;el('next').disabled=offset+limit>=lastMatched;el('releasePlanButton').disabled=!el('releaseChoice').options.length||!el('releaseStore').options.length;el('backupRequestButton').disabled=!el('backupStore').options.length;el('billingDraftButton').disabled=!el('billingStore').options.length}
}
let lastMatched=0;
async function load(){
 const f=new FormData(el('filters'));
 const r=await api.overview({offset,limit,query:String(f.get('query')||''),state:String(f.get('state')||'')});
 const statuses=new Map((await api.provisioningStatus(r.rows.map(s=>s.id))).map(s=>[s.id,s]));
 lastMatched=r.matched;
 el('metrics').replaceChildren(...[['المحلات',r.total],['جاهزة',r.ready],['موقوفة',r.suspended],['اشتراكات نشطة',r.active_subscriptions]].map(([label,value])=>{const d=node('div',label,'metric');d.append(node('strong',String(value)));return d}));
 el('rows').replaceChildren(...r.rows.map(s=>{
  const tr=document.createElement('tr');
  for(const v of [s.name,s.slug,labels[s.state],labels[s.plan_code]||'—',labels[s.subscription_state]||'—',s.valid_until?new Date(s.valid_until).toISOString().slice(0,10):'—'])tr.append(node('td',v));
  const status=statuses.get(s.id);
  const licenseLabels={unprovisioned_or_blocked:'غير مهيأ / محظور',expired:'منتهٍ',verification_required:'يتطلب التحقق'};
  tr.append(node('td',status?.queue==='queued'?'طلب بانتظار التنفيذ':'لا يوجد طلب'),node('td',licenseLabels[status?.license]||'غير مؤكد'));
  const td=document.createElement('td');
  if(!s.provisioned){
   const choices=s.state==='provisioning'?[['trial','تجربة 14 يوماً',14],['suspend','إيقاف',null],['cancel','إغلاق',null]]:s.state==='suspended'?[['reopen','إعادة فتح',null],['cancel','إغلاق',null]]:s.state==='closed'?[['reopen','إعادة فتح',null]]:[];
   if(s.state==='provisioning'&&status){
    const queued=status.queue==='queued';
    const btn=node('button',queued?'إلغاء طلب الإنشاء':'طلب إنشاء قاعدة');btn.type='button';
    btn.addEventListener('click',()=>{if(confirm(queued?'إلغاء الطلب؟':'تسجيل طلب فقط، دون إنشاء مشروع أو تكاليف؟'))run(async()=>{await api.provisioning(s.id,queued?'cancel':'request');await load();setMessage(queued?'أُلغي الطلب.':'تم تسجيل الطلب؛ لم تُنشأ قاعدة بيانات.')})});
    td.append(btn);
   }
   for(const [action,label,days] of choices){const btn=node('button',label);btn.type='button';btn.addEventListener('click',()=>{if(confirm(label+' — '+s.name+'؟'))run(async()=>{await api.manage(s.id,action,days);await load();setMessage('تم تحديث السجل الإداري.')})});td.append(btn)}
  }else td.textContent='يحتاج مسار إدارة إنتاج معتمد';
  tr.append(td);return tr
 }));
 el('count').textContent=r.matched+' محل';el('page').textContent=(Math.floor(offset/limit)+1)+' / '+Math.max(1,Math.ceil(r.matched/limit));
 el('prev').disabled=offset===0;el('next').disabled=offset+limit>=r.matched;
}
el('login').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);const password=String(f.get('password'));e.currentTarget.elements.password.value='';run(async()=>{await api.signInUsername(String(f.get('username')),password);offset=0;await load();await loadContact();await loadBilling();await loadBackups();await loadReleases();loggedIn();setMessage('تم تسجيل الدخول.')})});
async function loadContact(){
 const r=await api.contact();el('contact').elements.email.value=r.contact_email||'';
 el('contactStatus').textContent=r.contact_email?'محفوظ كبريد تواصل غير مؤكد':'لم تتم إضافة البريد بعد';
}
el('contact').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);run(async()=>{await api.contact(String(f.get('email')));await loadContact();setMessage('تم حفظ بريد التواصل؛ لا يستخدم لاسترداد كلمة المرور حتى التحقق منه.')})});
async function loadReleases(){
 const r=await api.releases();
 const eligible=new Set((await api.backups(100)).stores.filter(s=>s.recent_backup_id).map(s=>s.id));
 const options=(items,label)=>items.map(x=>{const o=node('option',label(x));o.value=x.id;return o});
 el('releaseChoice').replaceChildren(...options(r.releases,x=>x.version));
 el('releaseStore').replaceChildren(...options(r.eligible_stores.filter(x=>eligible.has(x.id)),x=>x.name+' / '+x.slug));
 el('releasePlanButton').disabled=!el('releaseChoice').options.length||!el('releaseStore').options.length;
 el('releaseRows').replaceChildren(...r.releases.map(x=>{const tr=document.createElement('tr');for(const v of [x.version,x.commit_sha.slice(0,12),x.notes||'—',x.rollback_plan])tr.append(node('td',v));return tr}));
 el('releaseTargets').replaceChildren(...r.targets.map(x=>{const tr=document.createElement('tr');for(const v of [x.version,x.store_name,x.state==='planned'?'مخطط فقط':'ملغى'])tr.append(node('td',v));const td=document.createElement('td');if(x.state==='planned'){const btn=node('button','إلغاء الخطة');btn.type='button';btn.addEventListener('click',()=>{if(confirm('إلغاء خطة التحديث؟'))run(async()=>{await api.planRelease(x.release_id,x.store_id,'cancel');await loadReleases();setMessage('أُلغيت خطة التحديث.')})});td.append(btn)}tr.append(td);return tr}));
}
el('releaseRegister').addEventListener('submit',e=>{e.preventDefault();const form=e.currentTarget,f=new FormData(form);run(async()=>{await api.registerRelease(Object.fromEntries(f));form.reset();await loadReleases();setMessage('تم تسجيل بيان الإصدار. لم يتم نشره أو التحقق من ملفاته بعد.')})});
el('releasePlan').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);if(confirm('تسجيل خطة فقط دون تنفيذ تحديث؟'))run(async()=>{await api.planRelease(String(f.get('release')),String(f.get('store')),'plan');await loadReleases();setMessage('تم تسجيل خطة التحديث.')})});
el('releaseRefresh').addEventListener('click',()=>run(loadReleases));
async function loadBackups(){
 const r=await api.backups();
 const statuses={verified:'موثقة حديثاً',unverified:'غير متحقق منها',stale:'قديمة أو غير صالحة زمنياً',revoked:'ملغاة'};
 el('backupStore').replaceChildren(...r.stores.map(s=>{const o=node('option',s.name+' / '+s.slug);o.value=s.id;return o}));
 el('backupRequestButton').disabled=!r.stores.length;
 el('backupRows').replaceChildren(...r.backups.map(x=>{const tr=document.createElement('tr');for(const v of [x.store_name,new Date(x.captured_at).toISOString(),statuses[x.status]])tr.append(node('td',v));const td=document.createElement('td');if(x.status!=='revoked'&&r.stores.some(s=>s.id===x.store_id)){const btn=node('button','طلب اختبار استعادة');btn.type='button';btn.addEventListener('click',()=>{if(confirm('طلب اختبار في بيئة معزولة فقط؟'))run(async()=>{await api.backupRequest(x.store_id,'restore_drill','request',x.id);await loadBackups();setMessage('تم تسجيل طلب الاختبار؛ لم تتم الاستعادة.')})});td.append(btn)}tr.append(td);return tr}));
 el('backupRequests').replaceChildren(...r.requests.map(x=>{const tr=document.createElement('tr');for(const v of [x.store_name,x.kind==='backup'?'نسخ احتياطي':'اختبار استعادة',x.state==='queued'?'بانتظار التنفيذ':'ملغى'])tr.append(node('td',v));const td=document.createElement('td');if(x.state==='queued'){const btn=node('button','إلغاء الطلب');btn.type='button';btn.addEventListener('click',()=>{if(confirm('إلغاء الطلب؟'))run(async()=>{await api.backupRequest(x.store_id,x.kind,'cancel');await loadBackups();setMessage('تم إلغاء الطلب.')})});td.append(btn)}tr.append(td);return tr}));
}
el('backupRequest').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);run(async()=>{await api.backupRequest(String(f.get('store')),'backup','request');await loadBackups();setMessage('تم تسجيل طلب النسخ؛ لم تُنشأ نسخة بعد.')})});
el('backupRefresh').addEventListener('click',()=>run(async()=>{await loadBackups();await loadReleases()}));
let billingMonth=null;
async function loadBilling(){
 const r=await api.billing();billingMonth=r.month;
 el('billingMonth').textContent=r.month.slice(0,7);
 el('billingStore').replaceChildren(...r.stores.map(x=>{const o=node('option',x.name+' / '+(x.monthly_usd_cents/100).toFixed(2)+' USD');o.value=x.id;return o}));
 el('billingDraftButton').disabled=!r.stores.length;
 const states={draft:'مسودة تجريبية',paid:'نجاح محاكى',failed:'فشل محاكى',refunded:'استرداد محاكى',void:'ملغاة'};
 el('billingRows').replaceChildren(...r.invoices.map(x=>{const tr=document.createElement('tr');for(const v of [x.store_name,x.plan_code,x.period_start.slice(0,7),(x.amount_cents/100).toFixed(2)+' USD',states[x.state]])tr.append(node('td',v));const td=document.createElement('td');
 const actions=x.state==='paid'?['refunded']:['draft','failed'].includes(x.state)?[...(x.period_start===r.month?(x.state==='draft'?['paid','failed']:['paid']):[]),'void']:[];
 const labels={paid:'محاكاة نجاح',failed:'محاكاة فشل',refunded:'محاكاة استرداد',void:'إلغاء المسودة'};
 for(const action of actions){const btn=node('button',labels[action]);btn.type='button';const requestId=crypto.randomUUID();btn.addEventListener('click',()=>{if(confirm('محاكاة فقط، دون تحصيل أو ترخيص حقيقي؟'))run(async()=>{await api.billingSimulate(x.id,action,requestId);await loadBilling();setMessage('تم تسجيل المحاكاة فقط.')})});td.append(btn)}tr.append(td);return tr}));
}
el('billingForm').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);run(async()=>{if(!billingMonth)throw Error('Missing sandbox month');await api.billingDraft(String(f.get('store')),billingMonth);await loadBilling();setMessage('تم تسجيل مسودة تجريبية؛ لا توجد فاتورة مالية.')})});
el('billingRefresh').addEventListener('click',()=>run(loadBilling));
el('logout').addEventListener('click',()=>run(async()=>{try{await api.signOut();setMessage('تم تسجيل الخروج.')}finally{loggedOut()}}));
el('register').addEventListener('submit',e=>{e.preventDefault();const form=e.currentTarget,f=new FormData(form);run(async()=>{await api.register({name:String(f.get('name')),slug:String(f.get('slug')),plan:String(f.get('plan'))});form.reset();offset=0;el('filters').reset();await load();setMessage('تم تسجيل المحل. لم تُنشأ قاعدة بيانات بعد.')})});
el('filters').addEventListener('submit',e=>{e.preventDefault();run(async()=>{offset=0;await load()})});
el('prev').addEventListener('click',()=>run(async()=>{offset=Math.max(0,offset-limit);await load()}));
el('next').addEventListener('click',()=>run(async()=>{offset+=limit;await load()}));
setInterval(()=>{if(!api.signedIn()&&!el('dashboard').hidden){loggedOut();setMessage('انتهت الجلسة. سجل الدخول مجدداً.')}},5000);
loggedOut();
