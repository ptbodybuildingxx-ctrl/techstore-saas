import {configuration} from './config.mjs';
import {createAdminApi} from './api.mjs';
const api=createAdminApi(configuration),el=id=>document.getElementById(id);
const labels={provisioning:'قيد الإعداد',ready:'جاهز',suspended:'موقوف',closed:'مغلق',pending:'قيد الانتظار',trial:'تجريبي إداري',active:'نشط',past_due:'متأخر',cancelled:'ملغى',basic:'Basic',business:'Business',pro:'Business Pro'};
const node=(tag,text,cls)=>{const n=document.createElement(tag);n.textContent=text;if(cls)n.className=cls;return n};
let offset=0,limit=25,busy=false;
function setMessage(text){el('message').textContent=text}
function loggedOut(){el('contact').reset();el('contactStatus').textContent='';el('dashboard').hidden=true;el('logout').hidden=true;el('loginPanel').hidden=false;el('rows').replaceChildren();el('metrics').replaceChildren()}
function loggedIn(){el('loginPanel').hidden=true;el('logout').hidden=false;el('dashboard').hidden=false}
async function run(fn){
 if(busy)return;busy=true;
 const controls=[...document.querySelectorAll('button')];for(const x of controls)x.disabled=true;
 try{await fn()}catch(e){setMessage(e.status===401||e.status===403?'تم رفض الصلاحية أو انتهت الجلسة.':e.status===409?'المعرّف مستخدم مسبقاً.':'لم يتم تأكيد الطلب. تحقق من الحالة قبل إعادة المحاولة.');if(!api.signedIn())loggedOut()}
 finally{busy=false;for(const x of controls)if(x.id!=='prev'&&x.id!=='next')x.disabled=false;el('prev').disabled=offset===0;el('next').disabled=offset+limit>=lastMatched}
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
el('login').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);const password=String(f.get('password'));e.currentTarget.elements.password.value='';run(async()=>{await api.signInUsername(String(f.get('username')),password);offset=0;await load();await loadContact();loggedIn();setMessage('تم تسجيل الدخول.')})});
async function loadContact(){
 const r=await api.contact();el('contact').elements.email.value=r.contact_email||'';
 el('contactStatus').textContent=r.contact_email?'محفوظ كبريد تواصل غير مؤكد':'لم تتم إضافة البريد بعد';
}
el('contact').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);run(async()=>{await api.contact(String(f.get('email')));await loadContact();setMessage('تم حفظ بريد التواصل؛ لا يستخدم لاسترداد كلمة المرور حتى التحقق منه.')})});
el('logout').addEventListener('click',()=>run(async()=>{try{await api.signOut();setMessage('تم تسجيل الخروج.')}finally{loggedOut()}}));
el('register').addEventListener('submit',e=>{e.preventDefault();const form=e.currentTarget,f=new FormData(form);run(async()=>{await api.register({name:String(f.get('name')),slug:String(f.get('slug')),plan:String(f.get('plan'))});form.reset();offset=0;el('filters').reset();await load();setMessage('تم تسجيل المحل. لم تُنشأ قاعدة بيانات بعد.')})});
el('filters').addEventListener('submit',e=>{e.preventDefault();run(async()=>{offset=0;await load()})});
el('prev').addEventListener('click',()=>run(async()=>{offset=Math.max(0,offset-limit);await load()}));
el('next').addEventListener('click',()=>run(async()=>{offset+=limit;await load()}));
setInterval(()=>{if(!api.signedIn()&&!el('dashboard').hidden){loggedOut();setMessage('انتهت الجلسة. سجل الدخول مجدداً.')}},5000);
loggedOut();
