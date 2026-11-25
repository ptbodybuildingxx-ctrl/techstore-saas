import {defaults,createDesignEditor} from '../design/theme.mjs';
import {configuration} from './config.mjs';
import {createAdminApi} from './api.mjs';
// Hosted GitHub Pages is a static showcase only, never accept credentials there.
if(location.hostname.endsWith('.github.io')){
 document.getElementById('loginPanel').hidden=true;
 document.getElementById('message').textContent='GitHub Pages للمعاينة فقط. تسجيل الدخول غير متاح على هذا النطاق.';
 throw Error('GitHub Pages is preview-only');
}
const api=createAdminApi(configuration),el=id=>document.getElementById(id);
const labels={provisioning:'قيد الإعداد',ready:'جاهز',suspended:'موقوف',closed:'مغلق',pending:'قيد الانتظار',trial:'تجريبي إداري',active:'نشط',past_due:'متأخر',cancelled:'ملغى',basic:'Basic',business:'Business',pro:'Business Pro'};
const node=(tag,text,cls)=>{const n=document.createElement(tag);n.textContent=text;if(cls)n.className=cls;return n};
let offset=0,limit=25,busy=false;
function setMessage(text){el('message').textContent=text}
function loggedOut(){recoveryAttempt=null;for(const id of ['sharedRequests','sharedBackups','sharedPlans'])el(id).replaceChildren();el('sharedStatus').textContent='';el('sharedRetry').hidden=true;priceAttempt=null;el('priceRows').replaceChildren();el('priceHistory').replaceChildren();el('priceForm').reset();el('priceStatus').textContent='';el('designPanel').hidden=true;el('designEditor').replaceChildren();shardPages=[null];shardNext=null;el('shardRows').replaceChildren();el('placementRows').replaceChildren();el('moveStore').replaceChildren();el('moveDestination').replaceChildren();el('shardForm').reset();el('billingRows').replaceChildren();el('billingStore').replaceChildren();el('billingMonth').textContent='';el('billingForm').reset();el('backupRows').replaceChildren();el('backupRequests').replaceChildren();el('backupStore').replaceChildren();el('backupRequest').reset();el('releaseRows').replaceChildren();el('releaseTargets').replaceChildren();el('releaseChoice').replaceChildren();el('releaseStore').replaceChildren();el('releaseRegister').reset();el('contact').reset();el('contactStatus').textContent='';el('dashboard').hidden=true;el('logout').hidden=true;el('loginPanel').hidden=false;el('rows').replaceChildren();el('metrics').replaceChildren()}
function loggedIn(){el('loginPanel').hidden=true;el('logout').hidden=false;el('dashboard').hidden=false}
async function run(fn){
 if(busy)return;busy=true;
 const controls=[...document.querySelectorAll('button')];for(const x of controls)x.disabled=true;
 try{await fn()}catch(e){setMessage(e.status===401||e.status===403?'تم رفض الصلاحية أو انتهت الجلسة.':e.status===409?'المعرّف مستخدم مسبقاً.':'لم يتم تأكيد الطلب. تحقق من الحالة قبل إعادة المحاولة.');if(!api.signedIn())loggedOut()}
 finally{busy=false;for(const x of controls)if(x.id!=='prev'&&x.id!=='next'&&x.id!=='releasePlanButton'&&x.id!=='backupRequestButton'&&x.id!=='billingDraftButton'&&x.id!=='moveButton'&&x.id!=='shardPrev'&&x.id!=='shardNext')x.disabled=false;el('prev').disabled=offset===0;el('next').disabled=offset+limit>=lastMatched;el('releasePlanButton').disabled=!el('releaseChoice').options.length||!el('releaseStore').options.length;el('backupRequestButton').disabled=!el('backupStore').options.length;el('billingDraftButton').disabled=!el('billingStore').options.length;el('moveButton').disabled=!el('moveStore').options.length||!el('moveDestination').options.length;el('shardPrev').disabled=shardPages.length<2;el('shardNext').disabled=!shardNext}
}
let lastMatched=0;
async function load(){
 const f=new FormData(el('filters'));
 const r=await api.overview({offset,limit,query:String(f.get('query')||''),state:String(f.get('state')||'')});
 const statuses=new Map((await api.sharedLicenseStatus(r.rows.map(s=>s.id))).map(s=>[s.id,s]));
 lastMatched=r.matched;
 el('metrics').replaceChildren(...[['المحلات',r.total],['جاهزة',r.ready],['موقوفة',r.suspended],['اشتراكات نشطة',r.active_subscriptions]].map(([label,value])=>{const d=node('div',label,'metric');d.append(node('strong',String(value)));return d}));
 el('rows').replaceChildren(...r.rows.map(s=>{
  const tr=document.createElement('tr');
  for(const v of [s.name,s.slug,labels[s.state],labels[s.plan_code]||'—',labels[s.subscription_state]||'—',s.valid_until?new Date(s.valid_until).toISOString().slice(0,10):'—'])tr.append(node('td',v));
  const status=statuses.get(s.id);
  const licenseLabels={unprovisioned_or_blocked:'غير مهيأ / محظور',expired:'منتهٍ',verification_required:'يتطلب التحقق'};
  tr.append(node('td',status?'قاعدة مشتركة':'مسار قديم'),node('td',status?.write_entitlement?'صلاحية تشغيل سارية':status?'غير نشط':'غير مؤكد'));
  const td=document.createElement('td');
  if(!s.provisioned){
   const choices=s.state==='provisioning'?[...(['pending','trial'].includes(s.subscription_state)?[['trial','تجربة 14 يوماً',14]]:[]),['suspend','إيقاف',null],['cancel','إغلاق',null]]:s.state==='suspended'?[['reopen','إعادة فتح',null],['cancel','إغلاق',null]]:s.state==='closed'?[['reopen','إعادة فتح',null]]:[];
   // Dedicated-project requests are deliberately disabled in the shared architecture UI.
   for(const [action,label,days] of choices){const btn=node('button',label);btn.type='button';btn.addEventListener('click',()=>{if(confirm(label+' — '+s.name+'؟'))run(async()=>{await api.manage(s.id,action,days);await load();setMessage('تم تحديث السجل الإداري.')})});td.append(btn)}
   const design=node('button','تصميم المحل');design.type='button';design.onclick=()=>run(()=>openDesign(s));td.append(design);
  }else td.textContent='يحتاج مسار إدارة إنتاج معتمد';
  tr.append(td);return tr
 }));
 el('count').textContent=r.matched+' محل';el('page').textContent=(Math.floor(offset/limit)+1)+' / '+Math.max(1,Math.ceil(r.matched/limit));
 el('prev').disabled=offset===0;el('next').disabled=offset+limit>=r.matched;
}
async function originalJpeg(file){
 if(!file||!['image/jpeg','image/png','image/webp'].includes(file.type)||file.size>12000000)throw Error('Invalid source image');
 const bmp=await createImageBitmap(file);try{if(bmp.width>6000||bmp.height>6000)throw Error('Image too large');const canvas=document.createElement('canvas'),scale=Math.min(1,1600/Math.max(bmp.width,bmp.height));canvas.width=Math.max(1,Math.round(bmp.width*scale));canvas.height=Math.max(1,Math.round(bmp.height*scale));const ctx=canvas.getContext('2d');ctx.fillStyle='#fff';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.drawImage(bmp,0,0,canvas.width,canvas.height);for(const quality of [.9,.8,.65]){const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/jpeg',quality));if(blob&&blob.size<=2000000)return blob}throw Error('Image exceeds quota')}finally{bmp.close()}
}
async function originalLibrary(s,state){
 const area=node('section'),items=await api.designOriginals(s.id),images=state.theme?.site?.images||[],status=node('p','الملفات الأصلية خاصة بالمدير العام؛ العرض العام يستخدم الصور المصغرة المنشورة. الحد 12 ملفاً للمحل، حتى 1600 بكسل و2 MB للملف. احفظ الصورة المصغرة في المسودة أولاً.');area.append(node('h3','مكتبة الصور الأصلية'),status);
 const select=node('select'),file=node('input');file.type='file';file.accept='image/jpeg,image/png,image/webp';
 const available=images.filter(x=>!items.some(y=>y.image_id===x.id&&y.uploaded));for(const x of available){const opt=node('option',x.alt);opt.value=x.id;select.append(opt)}
 const upload=node('button','رفع النسخة الأصلية');upload.type='button';upload.disabled=!available.length;upload.onclick=()=>run(async()=>{const image=available.find(x=>x.id===select.value);if(!image)throw Error('Save thumbnail first');const blob=await originalJpeg(file.files[0]);let asset=items.find(x=>x.image_id===image.id);if(!asset)asset=await api.reserveOriginal({store:s.id,request:crypto.randomUUID(),image:image.id,alt:image.alt});if(!asset.uploaded)await api.uploadOriginal(s.id,asset,blob);if(area.isConnected){const list=await originalLibrary(s,state);area.replaceWith(list)}});
 area.append(select,file,upload);for(const asset of items){const row=node('div');row.append(node('span',asset.alt+' — '+(asset.uploaded?'مرفوع':'بانتظار الملف')));if(asset.uploaded){const view=node('button','عرض الأصل');view.type='button';view.onclick=()=>run(async()=>{const blob=await api.readOriginal(s.id,asset);if(!row.isConnected)return;row.querySelector('img')?.remove();const im=document.createElement('img'),u=URL.createObjectURL(blob);im.alt=asset.alt;im.width=300;im.onload=im.onerror=()=>URL.revokeObjectURL(u);im.src=u;row.append(im)});row.append(view)}area.append(row)}return area
}
async function openDesign(s){
 const state=await api.designRead(s.id),history=await api.designHistory(s.id);
 el('designPanel').hidden=false;el('designTitle').textContent='تصميم '+s.name;
 const change=async(action,theme=null,restore=null)=>{if(busy)throw Error('Busy');busy=true;try{await api.designChange(s.id,state,action,theme,restore);await openDesign(s)}finally{busy=false}};
 el('designEditor').replaceChildren(createDesignEditor({initial:state.theme||{...defaults,brand:s.name.slice(0,80)},revision:state.revision,publishedRevision:state.published_revision,history,onSave:t=>change('save',t),onPublish:()=>change('publish'),onRestore:r=>change('restore',null,r)}));el('designEditor').append(await originalLibrary(s,state));el('designPanel').scrollIntoView({block:'start'});
}
el('login').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);const password=String(f.get('password'));e.currentTarget.elements.password.value='';run(async()=>{await api.signInUsername(String(f.get('username')),password);offset=0;await load();await loadContact();await loadPlanPrices();await loadShards();await loadBilling();await loadBackups();await loadReleases();await loadSharedRecovery();loggedIn();setMessage('تم تسجيل الدخول.')})});
let recoveryAttempt=null;
let priceAttempt=null,priceCatalog=new Map(),priceEditable=false;
async function loadPlanPrices(){const r=await api.planPrices();priceEditable=r.editable;priceCatalog=new Map(r.plans.map(p=>[p.code,p.monthly_usd_cents]));el('priceStatus').textContent=r.editable?'تعديل أسعار التطوير متاح؛ لا توجد فوترة حية.':'الأسعار مقفلة إلى حين ترحيل أسعار مزود الدفع.';
 el('priceRows').replaceChildren(...r.plans.map(p=>{const tr=node('tr','');for(const x of [p.name,(p.monthly_usd_cents/100).toFixed(2)+' USD'])tr.append(node('td',x));return tr}));
 el('priceHistory').replaceChildren(...r.history.map(p=>{const tr=node('tr','');for(const x of [p.plan_code,(p.previous_cents/100).toFixed(2),(p.new_cents/100).toFixed(2),p.note,p.created_at])tr.append(node('td',x));return tr}));el('priceRetry').hidden=!priceAttempt;}
el('priceRefresh').onclick=()=>run(loadPlanPrices);
async function sendPrice(){if(!priceAttempt)return;await api.changePlanPrice(priceAttempt);priceAttempt=null;el('priceRetry').hidden=true;await loadPlanPrices();setMessage('تم حفظ سعر الخطة.')}
el('priceRetry').onclick=()=>run(sendPrice);
el('priceForm').onsubmit=e=>{e.preventDefault();if(priceAttempt||!priceEditable)return;const f=new FormData(e.currentTarget),plan=String(f.get('plan')),raw=String(f.get('price')).trim(),note=String(f.get('note')).trim();if(!/^\d{1,6}(?:\.\d{1,2})?$/.test(raw)||!note)return;const [whole,fraction='']=raw.split('.'),price=Number(whole)*100+Number(fraction.padEnd(2,'0'));if(price<100||price>10000000||price===priceCatalog.get(plan)||!confirm('حفظ السعر الشهري الجديد دون تحصيل أي مبلغ؟'))return;priceAttempt=Object.freeze({request:crypto.randomUUID(),plan,expected:priceCatalog.get(plan),price,note});el('priceRetry').hidden=false;run(sendPrice)};
function recoveryRow(values){const tr=document.createElement('tr');for(const v of values){const td=document.createElement('td');if(v instanceof Node)td.append(v);else td.textContent=String(v??'—');tr.append(td)}return tr}
async function loadSharedRecovery(){const r=await api.sharedRecovery();const cancel=(x,type)=>{const btn=node('button','إلغاء');btn.type='button';btn.onclick=()=>{if(confirm('إلغاء السجل التخطيطي؟'))run(async()=>{await api.sharedRecoveryCancel(x.id,type);await loadSharedRecovery()})};return btn};
 el('sharedRequests').replaceChildren(...r.requests.map(x=>recoveryRow([x.id,x.shard_code,x.kind,x.state,x.state==='queued'?cancel(x,'recovery'):'—'])));
 el('sharedBackups').replaceChildren(...r.backups.map(x=>recoveryRow([x.id,x.shard_code,x.captured_at,x.eligible?'مؤهلة للتخطيط':'غير مؤهلة'])));
 el('sharedPlans').replaceChildren(...r.plans.map(x=>recoveryRow([x.id,x.shard_code,x.release_id,x.backup_id,x.eligible?'مؤهلة للتخطيط فقط':x.state,x.state==='planned'?cancel(x,'release'):'—'])));
}
async function sendRecovery(){if(!recoveryAttempt)return;const id=await api.sharedRecoveryChange(recoveryAttempt);recoveryAttempt=null;el('sharedRetry').hidden=true;el('sharedStatus').textContent='تم تسجيل الطلب التخطيطي '+id;await loadSharedRecovery()}
el('sharedRefresh').onclick=()=>run(loadSharedRecovery);el('sharedRetry').onclick=()=>run(sendRecovery);
for(const [id,kind] of [['sharedRequestForm','request'],['sharedReleaseForm','release']])el(id).onsubmit=e=>{e.preventDefault();if(recoveryAttempt)return;const f=new FormData(e.currentTarget),k=kind==='release'?'release':String(f.get('kind'));if(!confirm('تسجيل خطة فقط، دون تنفيذ استعادة أو تحديث؟'))return;recoveryAttempt=Object.freeze({request:crypto.randomUUID(),shard:String(f.get('shard')).trim(),kind:k,store:k==='tenant_export'?String(f.get('store')).trim():null,backup:k==='restore_drill'||k==='release'?String(f.get('backup')).trim():null,release:k==='release'?String(f.get('release')).trim():null});el('sharedRetry').hidden=false;el('sharedStatus').textContent='مرجع الطلب: '+recoveryAttempt.request;run(sendRecovery)};
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
let shardPages=[null],shardNext=null;
async function loadShards(){
 const r=await api.shardDirectory(shardPages.at(-1),50);
 shardNext=r.placements.length===50?r.placements.at(-1).store_id:null;
 const opt=(x,text)=>{const o=node('option',text);o.value=x;return o};
 el('shardRows').replaceChildren(...r.shards.map(s=>{const tr=document.createElement('tr');for(const v of [s.code,s.region,s.state==='local'?'محلية نشطة':'مخططة فقط',String(s.tenants)])tr.append(node('td',v));return tr}));
 el('moveStore').replaceChildren(...r.placements.filter(x=>['provisioning','suspended'].includes(x.store_state)).map(s=>opt(s.store_id,s.name+' / '+s.slug)));
 el('moveDestination').replaceChildren(...r.shards.filter(x=>x.state==='planned').map(s=>opt(s.code,s.code)));
 el('placementRows').replaceChildren(...r.placements.map(s=>{const tr=document.createElement('tr');for(const v of [s.name,s.shard_code,String(s.generation),s.planned_destination||'—'])tr.append(node('td',v));const td=document.createElement('td');if(s.planned_destination){const btn=node('button','إلغاء الخطة');btn.type='button';btn.addEventListener('click',()=>{if(confirm('إلغاء خطة النقل؟'))run(async()=>{await api.planMove(s.store_id,s.planned_destination,'cancel');await loadShards();setMessage('تم إلغاء الخطة.')})});td.append(btn)}tr.append(td);return tr}));
 el('shardPage').textContent=String(shardPages.length);
}
el('shardForm').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);run(async()=>{await api.registerShard(String(f.get('code')),String(f.get('region')));e.target.reset();await loadShards();setMessage('تم تسجيل مجموعة مخططة دون إنشاء قاعدة جديدة.')})});
el('moveForm').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);if(confirm('تسجيل خطة نقل فقط، دون نقل البيانات؟'))run(async()=>{await api.planMove(String(f.get('store')),String(f.get('destination')),'plan');await loadShards();setMessage('تم تسجيل خطة فقط؛ لم يتم نقل المحل.')})});
el('shardRefresh').addEventListener('click',()=>run(async()=>{shardPages=[null];await loadShards()}));
el('shardPrev').addEventListener('click',()=>run(async()=>{if(shardPages.length>1){shardPages.pop();await loadShards()}}));
el('shardNext').addEventListener('click',()=>run(async()=>{if(shardNext){shardPages.push(shardNext);await loadShards()}}));
el('logout').addEventListener('click',()=>run(async()=>{try{await api.signOut();setMessage('تم تسجيل الخروج.')}finally{loggedOut()}}));
el('register').addEventListener('submit',e=>{e.preventDefault();const form=e.currentTarget,f=new FormData(form);run(async()=>{await api.registerShared({name:String(f.get('name')),slug:String(f.get('slug')),plan:String(f.get('plan')),owner:String(f.get('owner'))});form.reset();offset=0;el('filters').reset();await load();shardPages=[null];await loadShards();setMessage('تم تسجيل مساحة مشتركة للمحل؛ لا يحتاج مشروع Supabase إضافياً.')})});
el('filters').addEventListener('submit',e=>{e.preventDefault();run(async()=>{offset=0;await load()})});
el('prev').addEventListener('click',()=>run(async()=>{offset=Math.max(0,offset-limit);await load()}));
el('next').addEventListener('click',()=>run(async()=>{offset+=limit;await load()}));
setInterval(()=>{if(!api.signedIn()&&!el('dashboard').hidden){loggedOut();setMessage('انتهت الجلسة. سجل الدخول مجدداً.')}},5000);
loggedOut();
