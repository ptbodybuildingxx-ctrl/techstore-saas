// Central control workspace. No impersonation, passwords or tenant transactional data.
import {tr,currentLanguage} from '../design/i18n.mjs';
const labels={grant:'إصدار ترخيص يدوي',renew:'تجديد الترخيص اليدوي',revoke:'إلغاء الترخيص اليدوي',plan:'تغيير الباقة',pause_shop:'إيقاف عرض المتجر مركزياً',resume_shop:'رفع إيقاف المتجر المركزي',rename:'تعديل اسم المحل',trial:'منح تجربة',suspend:'إيقاف تشغيل المحل',cancel:'إغلاق المحل',reopen:'إعادة فتح المحل',register:'تسجيل محل'};
const states={provisioning:'محل مشترك',ready:'جاهز',suspended:'موقوف',closed:'مغلق',pending:'قيد الانتظار',trial:'تجريبي إداري',active:'نشط',past_due:'متأخر',cancelled:'ملغى'};
const when=x=>x?new Date(x).toLocaleString(currentLanguage()==='en'?'en-GB':'ar-SY',{timeZone:'Asia/Damascus'}):'—';
const stateLabel=x=>tr(states[x]||x);
export function createCentralControl({api,root,run,refresh}){
 const n=(tag,text)=>{const a=document.createElement(tag);if(text!==undefined)a.textContent=text;return a};
 const t=(tag,text)=>n(tag,tr(text));
 const dialog=n('dialog'),body=n('div'),footer=n('div'),close=t('button','إغلاق');close.type='button';close.onclick=()=>dialog.close();dialog.append(body,footer,close);root.append(dialog);
 let selected=null,pending=null;
 const button=(label,fn)=>{const b=t('button',label);b.type='button';b.onclick=()=>run(fn);return b};
 function table(headers,rows){const wrap=n('div'),table=n('table'),head=n('thead'),hr=n('tr'),tb=n('tbody');wrap.className='scroll';for(const label of headers)hr.append(t('th',label));head.append(hr);table.append(head,tb);for(const cells of rows){const row=n('tr');for(const value of cells)row.append(n('td',String(value??'—')));tb.append(row)}wrap.append(table);return wrap}
 const pair=(label,value)=>n('p',tr(label)+': '+String(value??'—'));
 function summary(v){return [v.name,v.plan,stateLabel(v.state),stateLabel(v.subscription_state),when(v.valid_until),tr(v.manual_request?'ترخيص يدوي':'لا يوجد ترخيص يدوي'),tr(v.storefront_paused?'موقوف مركزياً':'غير موقوف مركزياً')].join(' · ')}
 async function send(){
  if(!pending||!api.signedIn())return;
  const p=pending;await api.storeControlChange(p.store,p.request,p.action,p.expected,p.params,p.reference);
  pending=null;await show(p.store);await refresh();
 }
 async function show(id,offset=0){
  if(pending&&pending.store!==id)throw Error('Resolve previous administrative request first');
  const r=await api.storeControlReview(id,offset);if(!api.signedIn())return;selected=id;
  const v=r.snapshot,manual=!!v.manual_request,local=v.local&&!v.provider_bound&&!v.live_billing,open=v.state==='provisioning';
  body.replaceChildren(n('h2',tr('التحكم المركزي بالمحل')+' — '+v.name),pair('معرّف المحل',v.id),pair('المعرّف',v.slug),pair('الحالة',stateLabel(v.state)),pair('الخطة',v.plan),pair('الاشتراك',stateLabel(v.subscription_state)),pair('صلاحية التشغيل',tr(r.licensed?'سارية':'غير متاحة')),pair('انتهاء الترخيص',when(v.valid_until)),pair('مصدر الترخيص',tr(manual?'ترخيص يدوي':v.subscription_state==='trial'?'تجربة إدارية':v.subscription_state==='active'?'مزود دفع':'لا يوجد ترخيص')),pair('مرجع الترخيص اليدوي',v.manual_reference),pair('المتجر',tr(r.storefront_visible?'ظاهر':'مخفي')),pair('إيقاف المتجر المركزي',tr(v.storefront_paused?'نعم':'لا')),pair('ارتباط مزود الدفع',tr(v.provider_bound?'نعم':'لا')),pair('الفوترة الحية',tr(v.live_billing?'مفعلة':'معطلة')));
  body.append(table(['الملاك النشطون','الموظفون النشطون','المنتجات','الطلبات المعلقة'],[[r.owner_count,r.staff_count,r.product_count,r.pending_orders]]),t('p','الترخيص اليدوي يمنح صلاحية التشغيل فقط ولا يثبت قبضاً أو اشتراكاً مدفوعاً. تغيير الباقة يلغي الترخيص الحالي ويتطلب إصدار ترخيص جديد.'));
  const actions=['rename',v.storefront_paused?'resume_shop':'pause_shop'];
  if(open){actions.push('suspend','cancel');if(local){if(manual)actions.push('renew','revoke','plan');else if(['pending','trial','past_due'].includes(v.subscription_state))actions.push('grant','plan');if(['pending','trial'].includes(v.subscription_state))actions.push('trial')}}
  else if(['suspended','closed'].includes(v.state)){actions.push('reopen');if(v.state==='suspended')actions.push('cancel')}
  if(!pending){
   const f=n('form'),sel=n('select'),fields=n('div'),ref=n('input'),submit=t('button','اعتماد الإجراء الإداري');submit.type='submit';ref.required=true;ref.maxLength=200;
   for(const action of actions){const opt=t('option',labels[action]);opt.value=action;sel.append(opt)}
   const label=(title,field)=>{const l=t('label',title);l.append(field);return l};
   let input=null;
   function paint(){fields.replaceChildren();input=null;const a=sel.value;if(['grant','renew','trial'].includes(a)){input=n('input');input.type='number';input.min='1';input.max=a==='trial'?'30':'365';input.step='1';input.value=a==='trial'?'14':'30';input.required=true;fields.append(label('مدة الترخيص بالأيام',input));if(a==='renew')fields.append(t('p','التجديد يضيف المدة إلى تاريخ الانتهاء الحالي أو إلى اليوم إذا انتهى.'))}
    if(a==='plan'){input=n('select');for(const plan of ['basic','business','pro'].filter(x=>x!==v.plan)){const opt=n('option',plan);opt.value=plan;input.append(opt)}fields.append(label('الباقة الجديدة',input),t('p','سيتم إلغاء الصلاحية الحالية حتى إصدار ترخيص جديد.'))}
    if(a==='rename'){input=n('input');input.value=v.name;input.required=true;input.maxLength=160;fields.append(label('اسم المحل الجديد',input))}
    if(a==='pause_shop')fields.append(t('p','سيختفي المتجر العام وتتوقف خدمات العملاء المرتبطة به، دون حذف البيانات أو إيقاف لوحة المحل.'))
    if(['suspend','cancel'].includes(a))fields.append(t('p','سيتم إلغاء صلاحية التشغيل دون حذف بيانات المحل. إعادة الفتح لا تمنح ترخيصاً تلقائياً.'))
   }
   sel.onchange=paint;paint();
   f.append(label('الإجراء',sel),fields,label('سبب الإجراء أو مرجع الموافقة',ref),submit);f.onsubmit=e=>{e.preventDefault();run(async()=>{if(pending||selected!==id||!dialog.open)return;const action=sel.value,params={};if(['grant','renew','trial'].includes(action))params.days=Number(input.value);else if(action==='plan')params.plan=input.value;else if(action==='rename')params.name=input.value.trim();if(!ref.value.trim()||!confirm(tr(labels[action])+' — '+v.name+'؟'))return;pending={store:id,request:crypto.randomUUID(),action,expected:v,params,reference:ref.value.trim()};f.replaceChildren(t('p','إجراء غير مؤكد؛ استخدم إعادة الطلب نفسه.'),n('code',pending.request),button('إعادة الطلب نفسه',send),button('مراجعة حالة الإجراء',()=>show(id)));await send()})};body.append(f)
  }else{
   const applied=r.history.some(e=>e.request_id===pending.request);
   if(applied){pending=null;return show(id,offset)}
   body.append(t('p','إجراء غير مؤكد؛ استخدم إعادة الطلب نفسه.'),n('code',pending.request),button('إعادة الطلب نفسه',send),button('مراجعة حالة الإجراء',()=>show(id)),button('ترك الطلب غير المؤكد بعد المراجعة',async()=>{if(confirm(tr('راجع السجل والحالة قبل بدء إجراء جديد. هل تريد ترك المرجع غير المؤكد؟'))){pending=null;await show(id)}}));
  }
  body.append(t('h3','سجل التدقيق المركزي'),table(['التاريخ','الإجراء','المرجع','المدير','قبل','بعد'],r.history.map(e=>[when(e.created_at),tr(labels[e.action]||e.action),e.reference,e.actor,summary(e.before_state),summary(e.after_state)])),t('h3','السجل الإداري السابق'),table(['التاريخ','الإجراء','المدير'],r.legacy_history.map(e=>[when(e.recorded_at),tr(labels[e.action]||e.action),e.actor])));
  footer.replaceChildren();if(offset>0)footer.append(button('الأولى',()=>show(id,0)));if(r.more)footer.append(button('التالي',()=>show(id,offset+50)));
  if(!dialog.open)dialog.showModal();
 }
 return {show,reset(){pending=null;selected=null;if(dialog.open)dialog.close();body.replaceChildren();footer.replaceChildren()}}
}
