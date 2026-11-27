// Central restrictions layer on top of role, branch, license and locally assigned permissions.
import {tr,currentLanguage} from '../design/i18n.mjs';
import {centralActionLabels,centralActionKeys} from '../tenant/staff-permissions.mjs';
const n=(tag,text)=>{const a=document.createElement(tag);if(text!==undefined)a.textContent=text;return a},t=(tag,x)=>n(tag,tr(x));
const label=(title,x)=>{const l=t('label',title);l.prepend(x);return l};
const when=x=>new Date(x).toLocaleString(currentLanguage()==='en'?'en-GB':'ar-SY',{timeZone:'Asia/Damascus'});
export function createActionPolicy({api,root,run}){
 const area=n('div'),editor=n('div');let data=null,selected=null,pending=null;
 const button=(title,fn)=>{const b=t('button',title);b.type='button';b.onclick=()=>run(fn);return b};
 root.append(button('تحديث القيود التفصيلية',load),area);
 async function send(){if(!pending||!api.signedIn())return;await api.centralActionsChange(pending);pending=null;await load()}
 async function load(){const r=await api.centralActionsReview();if(!api.signedIn())return;data=r;if(pending&&r.history.some(x=>x.request_id===pending.request))pending=null;
  area.replaceChildren(t('p','القيود المركزية تُضاف إلى قيود المالك ولا تمنح صلاحيات جديدة. قيود الموظفين تضاف إلى قيود العمليات العامة لجميع الأدوار. الحذف المسموح أصلاً فقط يمكن تقييده؛ لا تُمنح صلاحية حذف السجلات المالية.'));
  if(pending)area.append(t('p','إجراء غير مؤكد؛ استخدم إعادة الطلب نفسه.'),n('code',pending.request),button('إعادة الطلب نفسه',send),button('مراجعة حالة الإجراء',load),button('ترك الطلب غير المؤكد بعد المراجعة',async()=>{if(confirm(tr('راجع السجل والحالة قبل بدء إجراء جديد. هل تريد ترك المرجع غير المؤكد؟'))){pending=null;await load()}}));
  const select=n('select');for(const p of data.plans){const o=n('option',p.name+' ('+p.code+')');o.value=p.code;select.append(o)}if(data.plans.some(p=>p.code===selected))select.value=selected;selected=select.value;select.disabled=!!pending;select.onchange=()=>{selected=select.value;paint()};area.append(label('الباقة',select),editor);paint();
  area.append(t('h3','سجل القيود المركزية'));for(const h of data.history){const d=n('div');d.className='panel';const added=h.after_denied.filter(k=>!h.before_denied.includes(k)),removed=h.before_denied.filter(k=>!h.after_denied.includes(k));d.append(n('strong',h.plan_code+' — '+when(h.created_at)),n('p',h.reference+' — '+h.actor),n('p',tr('القيود المضافة')+': '+(added.map(k=>tr(centralActionLabels[k])).join('، ')||'—')),n('p',tr('القيود المرفوعة')+': '+(removed.map(k=>tr(centralActionLabels[k])).join('، ')||'—')));area.append(d)}
 }
 function paint(){editor.replaceChildren();if(!data)return;const p=data.plans.find(x=>x.code===selected);if(!p)return;const f=n('form'),controls={},ref=n('input');ref.required=true;ref.maxLength=200;
 for(const [group,title] of [['staff','قيود قراءة وكتابة الموظفين'],['record','قيود التعديل والأرشفة والإلغاء لجميع الأدوار'],['all','قيود العمليات العامة لكل الأدوار']]){const fs=n('fieldset'),legend=t('legend',title);fs.append(legend);for(const k of centralActionKeys.filter(k=>group==='staff'?k.startsWith('staff_'):group==='all'?k.startsWith('all_'):!k.startsWith('staff_')&&!k.startsWith('all_'))){const input=n('input');input.type='checkbox';input.checked=p.denied.includes(k);controls[k]=input;fs.append(label(tr('منع')+': '+tr(centralActionLabels[k]),input))}fs.disabled=!!pending;f.append(fs)}
 const submit=t('button','حفظ القيود المركزية');submit.type='submit';submit.disabled=ref.disabled=!!pending;f.append(label('سبب الإجراء أو مرجع الموافقة',ref),submit);f.onsubmit=e=>{e.preventDefault();run(async()=>{if(pending||!ref.value.trim()||selected!==p.code)return;const desired=centralActionKeys.filter(k=>controls[k].checked);if(desired.length===p.denied.length&&desired.every(k=>p.denied.includes(k)))return;if(!confirm(tr('تأكيد تغيير القيود التفصيلية لجميع محلات الباقة؟')+' — '+p.name))return;pending={request:crypto.randomUUID(),plan:p.code,expected:p.revision,desired,reference:ref.value.trim()};editor.replaceChildren(n('code',pending.request),button('إعادة الطلب نفسه',send),button('مراجعة حالة الإجراء',load));await send()})};editor.append(f)
 }
 return {load,reset(){pending=null;selected=null;data=null;area.replaceChildren();editor.replaceChildren()}}
}

export function createStoreActionPolicy({api,root,run}){
 const dialog=n('dialog'),area=n('div'),close=t('button','إغلاق');close.type='button';close.onclick=()=>dialog.close();dialog.append(area,close);root.append(dialog);
 let store=null,pending=null;
 const button=(title,fn)=>{const b=t('button',title);b.type='button';b.onclick=()=>run(fn);return b};
 async function send(){if(!pending||!api.signedIn())return;const p=pending;await api.storeActionsChange(p.store,p);pending=null;await show(p.store)}
 async function show(s){if(pending&&pending.store!==s)throw Error('Resolve previous administrative request first');const r=await api.storeActionsReview(s);if(!api.signedIn())return;store=s;if(pending&&r.history.some(x=>x.request_id===pending.request))pending=null;
 area.replaceChildren(n('h2',tr('القيود الخاصة بالمحل')+' — '+r.name),n('p',tr('الباقة')+': '+r.plan),t('p','قيود المحل تضاف إلى قيود الباقة ولا تستطيع رفع أي منع مركزي من الباقة.'));
 if(pending)area.append(n('code',pending.request),button('إعادة الطلب نفسه',send),button('مراجعة حالة الإجراء',()=>show(s)));
 const f=n('form'),controls={},ref=n('input');ref.required=true;ref.maxLength=200;
 for(const [group,title] of [['staff','قيود قراءة وكتابة الموظفين'],['record','قيود التعديل والأرشفة والإلغاء لجميع الأدوار'],['all','قيود العمليات العامة لكل الأدوار']]){
 const fs=n('fieldset');fs.append(t('legend',title));for(const k of centralActionKeys.filter(k=>group==='staff'?k.startsWith('staff_'):group==='all'?k.startsWith('all_'):!k.startsWith('staff_')&&!k.startsWith('all_'))){const x=n('input');x.type='checkbox';x.checked=r.denied.includes(k);controls[k]=x;const l=label(tr('منع')+': '+tr(centralActionLabels[k]),x);if(r.plan_denied.includes(k))l.append(n('small',' — '+tr('ممنوعة على مستوى الباقة')));fs.append(l)}fs.disabled=!!pending;f.append(fs)}
 const submit=t('button','حفظ قيود المحل');submit.type='submit';submit.disabled=ref.disabled=!!pending;f.append(label('سبب الإجراء أو مرجع الموافقة',ref),submit);f.onsubmit=e=>{e.preventDefault();run(async()=>{if(pending||store!==s||!ref.value.trim())return;const desired=centralActionKeys.filter(k=>controls[k].checked);if(desired.length===r.denied.length&&desired.every(k=>r.denied.includes(k)))return;if(!confirm(tr('تأكيد تغيير قيود هذا المحل فقط؟')+' — '+r.name))return;pending={store:s,request:crypto.randomUUID(),expected:r.revision,desired,reference:ref.value.trim()};submit.disabled=true;await send()})};area.append(f,t('h3','سجل القيود المركزية'));for(const h of r.history){const d=n('div');d.className='panel';d.append(n('strong',when(h.created_at)+' — '+h.actor),n('p',h.reference),n('p',tr('القيود المضافة')+': '+(h.after_denied.filter(k=>!h.before_denied.includes(k)).map(k=>tr(centralActionLabels[k])).join('، ')||'—')),n('p',tr('القيود المرفوعة')+': '+(h.before_denied.filter(k=>!h.after_denied.includes(k)).map(k=>tr(centralActionLabels[k])).join('، ')||'—')));area.append(d)}if(!dialog.open)dialog.showModal();
 }
 return {show,reset(){pending=null;store=null;area.replaceChildren();if(dialog.open)dialog.close()}}
}
export function createCommercialRegister({api,root,run,openInvoice}){
 const dialog=n('dialog'),area=n('div'),close=t('button','إغلاق');close.type='button';close.onclick=()=>dialog.close();dialog.append(area,close);root.append(dialog);
 const btn=(title,fn)=>{const b=t('button',title);b.type='button';b.onclick=()=>run(fn);return b};
 const money=x=>{const a=BigInt(x),s=a.toString().padStart(3,'0');return s.slice(0,-2)+'.'+s.slice(-2)+' USD'};
 let month=new Date().toISOString().slice(0,7),filter='all',offset=0;
 const states={all:'الكل',unpaid:'غير مسددة',partial:'مسددة جزئياً',paid:'مسددة',refunded:'مستردة',void:'ملغاة',overdue:'متأخرة السداد',paid_unlicensed:'مسددة دون ترخيص حالي'};
 function table(headers,rows){const wrap=n('div'),tab=n('table'),head=n('thead'),hr=n('tr'),body=n('tbody');wrap.className='scroll';for(const h of headers)hr.append(t('th',h));head.append(hr);tab.append(head,body);for(const cells of rows){const row=n('tr');for(const c of cells){const td=n('td');if(c instanceof Node)td.append(c);else td.textContent=String(c??'—');row.append(td)}body.append(row)}wrap.append(tab);return wrap}
 async function show(off=0){const r=await api.commercialRegister(month+'-01',filter,off);if(!api.signedIn())return;offset=off;area.replaceChildren(t('h2','كشف الفوترة التجارية المركزي'),t('p','يعرض الفواتير والمقبوضات الخارجية الموثقة، لا معاملات بوابة دفع. الإجماليات لجميع فواتير الشهر المحدد.'));
 const f=n('form'),m=n('input'),s=n('select'),submit=t('button','عرض الكشف');m.type='month';m.required=true;m.value=month;for(const [k,v] of Object.entries(states)){const o=t('option',v);o.value=k;s.append(o)}s.value=filter;submit.type='submit';f.append(label('شهر الاشتراك',m),label('الحالة',s),submit);f.onsubmit=e=>{e.preventDefault();run(async()=>{month=m.value;filter=s.value;await show(0)})};area.append(f);
 const a=r.summary;area.append(table(['البيان','القيمة'],[['الفواتير',a.invoices],['إجمالي الفواتير',money(a.billed)],['المقبوضات',money(a.collected)],['الاستردادات',money(a.refunded)],['صافي المقبوض',money(a.net)],['المبلغ المتبقي',money(a.outstanding)],['متأخرة السداد',a.overdue],['مسددة دون ترخيص حالي',a.paid_unlicensed]].map(([k,v])=>[tr(k),v])),table(['المحل','الباقة','الإجمالي','صافي المقبوض','المبلغ المتبقي','الحالة','الترخيص','الإجراء'],r.rows.map(x=>[x.store_name,x.plan_name,money(x.amount_cents),money(x.net),money(x.outstanding),tr(states[x.state])+(x.overdue?' — '+tr('متأخرة السداد'):''),tr(x.licensed?'ساري':'غير متاح'),btn('عرض الفاتورة والسندات',async()=>{dialog.close();await openInvoice(x.store_id)})])));if(off>0)area.append(btn('السابق',()=>show(Math.max(0,offset-50))));if(r.more)area.append(btn('التالي',()=>show(offset+50)));if(!dialog.open)dialog.showModal();
 }
 return {show,reset(){offset=0;area.replaceChildren();if(dialog.open)dialog.close()}}
}
