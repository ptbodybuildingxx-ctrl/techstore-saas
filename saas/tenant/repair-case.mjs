// Repair consent workspace: no identity document numbers, no offline identity actions.
import {tr} from '../design/i18n.mjs';
const date=v=>v?new Date(v).toLocaleString('ar-SY',{timeZone:'Asia/Damascus'}):'—';
const stateLabels={received:'مستلم',diagnosing:'قيد الفحص',repairing:'قيد الإصلاح',ready:'جاهز للتسليم',delivered:'تم التسليم',cancelled:'ملغى',offered:'بانتظار الموافقة',approved:'مقبول',rejected:'مرفوض',superseded:'ملغى'};
const auditLabels={account_linked:'ربط الحساب',identity_checked:'توثيق التحقق من الهوية',tracking_activated:'تفعيل متابعة طلب تاريخي',tracking_rotated:'إعادة إصدار رمز المتابعة',paper_decision:'قرار ورقي موثق',photo_visibility:'تغيير مشاركة الصورة'};
const methods={government_id_seen:'مطابقة وثيقة الهوية حضورياً',intake_receipt_and_confirmed_account:'مطابقة وصل الاستلام وحساب مؤكد',confirmed_account_and_in_person_attestation:'تأكيد حضوري وحساب مؤكد',government_id_and_original_intake_verified:'مطابقة الهوية ووصل الاستلام الأصلي',government_id_seen_signed_paper:'مطابقة الهوية والوثيقة الورقية الموقعة'};
const isOpen=s=>['received','diagnosing','repairing','ready'].includes(s);
export function createRepairCasePanel({api,s,write,run,node,table,form,money,active,printArea}){
 const root=node('div'),area=node('div'),status=node('p'),retry=node('button',tr('إعادة تأكيد إجراء الهوية'));retry.type='button';retry.hidden=true;
 let current=null,pending=null;
 const p=t=>node('p',tr(t));const heading=t=>node('h4',tr(t));const button=(label,fn)=>{const b=node('button',tr(label));b.type='button';b.onclick=()=>run(fn);return b};
 function displayDate(value){return date(value)}
 async function send(){
  if(!pending)return;if(!active()||!navigator.onLine)throw Error('Live connection required');
  retry.hidden=false;const op=pending;
  await api.repairCaseAction(s.id,op);
  pending=null;retry.hidden=true;if(!active())return;status.textContent=tr('تم توثيق الإجراء');await load(op.repair);
 }
 async function start(kind,repair,values){
  if(pending)throw Error(tr('أعد تأكيد الإجراء السابق أولاً'));
  if(!navigator.onLine)throw Error(tr('هذا الإجراء يحتاج اتصالاً مباشراً'));
  pending={kind,repair,request:crypto.randomUUID(),...values};await send();
 }
 retry.onclick=()=>run(send);
 function printConsent(id,r,e){
  if(!active()||!printArea)return;
  printArea.replaceChildren(node('h2',tr('نموذج موافقة العميل على تقدير الصيانة')),node('p',tr('اسم العميل')+': '+r.customer_name),node('p',tr('الجهاز')+': '+r.device),node('p',tr('معرّف طلب الصيانة')+': '+id),node('p',tr('معرّف التقدير')+': '+e.id),node('p',tr('التكلفة المقدرة')+': '+money(e.amount_minor,e.currency)),node('p',e.description),node('p',tr('أوافق / أرفض التكلفة المبينة أعلاه (حدد القرار)')),node('p',tr('مرجع الوثيقة الداخلية')+': __________________'),node('p',tr('توقيع العميل وتاريخ الموافقة')+': __________________'),node('p',tr('توقيع الموظف الذي تحقق من الهوية')+': __________________'),node('p',tr('هذا النموذج ليس فاتورة دفع ولا توقيعاً رقمياً قانونياً.')));
  printArea.hidden=false;document.body.classList.add('design-printing');try{window.print()}finally{document.body.classList.remove('design-printing');printArea.hidden=true;printArea.replaceChildren()}
 }
 function auditDetail(x){const d=x.details||{},parts=[];if(d.method)parts.push(tr(methods[d.method]||d.method));if(d.reference)parts.push(tr('مرجع الوثيقة الداخلية')+': '+d.reference);if(typeof d.accepted==='boolean')parts.push(tr(d.accepted?'مقبول':'مرفوض'));if(d.currency&&d.amount_minor!=null)parts.push(money(d.amount_minor,d.currency));if(typeof d.visible==='boolean')parts.push(tr(d.visible?'مشتركة مع العميل':'خاصة بالموظفين'));if(d.superseded_estimate)parts.push(tr('التقدير السابق')+': '+d.superseded_estimate);return parts.join(' — ')||'—'}
 async function load(id){
  const r=await api.repairCaseReview(s.id,id);if(!active())return;current=id;
  area.replaceChildren(heading('ملف الموافقة والتحقق من الهوية'),node('p',r.customer_name+' — '+r.device+' — '+tr(stateLabels[r.state]||r.state)),node('p',tr(r.tracked?'المتابعة مفعلة':'طلب تاريخي دون رمز متابعة')+' / '+tr(r.linked?'حساب العميل مرتبط':'حساب العميل غير مرتبط')+' / '+tr(r.approved?'موافقة صالحة':'لا توجد موافقة صالحة')));
  const open=isOpen(r.state),offered=r.estimates.find(e=>e.superseded_at===null&&e.state==='offered');
  if(write&&open){
   {
    const mode=r.tracked?'rotate':'activate';
    area.append(heading(r.tracked?'استعادة متابعة الطلب':'تفعيل متابعة الطلب التاريخي'),p(r.tracked?'إعادة الإصدار تلغي الرمز السابق والربط والموافقة الحالية ومشاركة الصور. يتطلب الإصلاح أو التسليم موافقة جديدة.':'تفعيل المتابعة لا يسجل موافقة قديمة؛ يجب إصدار تقدير جديد والحصول على قرار العميل.'),form([['proof','مرجع الوثيقة الداخلية (دون رقم الهوية)','text'],['confirmed','تحققت من الهوية ووصل الاستلام الأصلي','select',[['no','لا'],['yes','نعم']]]],r.tracked?'إعادة إصدار رمز المتابعة':'تفعيل متابعة طلب تاريخي',async v=>{if(v.confirmed!=='yes'||!confirm(tr('أؤكد التحقق الحضوري من هوية العميل وملكيته للطلب.')))return;await start('tracking',id,{mode,proof:v.proof})}));
   }
   if(r.tracked&&!r.linked){
    area.append(heading('ربط حساب موثق'),form([['code','رمز ربط العميل','text'],['method','طريقة التحقق من الهوية','select',[['government_id_seen','مطابقة وثيقة الهوية حضورياً'],['intake_receipt_and_confirmed_account','مطابقة وصل الاستلام وحساب مؤكد']]],['proof','مرجع الوثيقة الداخلية (دون رقم الهوية)','text']],'ربط حساب العميل بطلب الصيانة',async v=>{if(!confirm(tr('أؤكد التحقق الحضوري من هوية العميل وملكيته للطلب.')))return;await start('link',id,{code:v.code,method:v.method,proof:v.proof})}));
    if(offered){area.append(heading('موافقة ورقية للعميل غير المرتبط'),node('p',money(offered.amount_minor,offered.currency)+' — '+offered.description),button('طباعة نموذج الموافقة',()=>printConsent(id,r,offered)),p('القرار الورقي توثيق من المالك بعد رؤية وثيقة الهوية والاحتفاظ بالنموذج الموقع، وليس موافقة إلكترونية من حساب العميل.'),form([['decision','قرار العميل','select',[['reject','مرفوض'],['accept','مقبول']]],['proof','مرجع الوثيقة الداخلية (دون رقم الهوية)','text'],['confirmed','اطلعت على الهوية والوثيقة الموقعة','select',[['no','لا'],['yes','نعم']]]],'تسجيل القرار الورقي',async v=>{if(v.confirmed!=='yes'||!confirm(tr('أؤكد أن القرار المدون مطابق للوثيقة الموقعة من العميل.')))return;await start('paper',id,{estimate:offered.id,accept:v.decision==='accept',currency:offered.currency,amount:offered.amount_minor,proof:v.proof})}));}
   }
   if(r.linked&&offered)area.append(p('العميل المرتبط يوافق أو يرفض التقدير من حسابه فقط.'));
  }
  area.append(heading('سجل التقديرات والقرارات'),table(['التقدير','المبلغ','الأعمال المقترحة','الحالة','طريقة الموافقة','وقت القرار','مرجع الوثيقة الداخلية'],r.estimates.map(e=>[e.id,money(e.amount_minor,e.currency),e.description,tr(stateLabels[e.state]||e.state)+(e.superseded_at?' — '+tr('تقدير سابق'):''),e.decision_method?tr(e.decision_method==='paper'?'قرار ورقي موثق':'حساب عميل مؤكد'):'—',displayDate(e.decided_at),e.document_ref||'—'])),heading('سجل انتقالات الصيانة'),table(['من','إلى','البيان','الموظف','التاريخ'],r.history.map(e=>[tr(stateLabels[e.prior_state]||e.prior_state),tr(stateLabels[e.next_state]||e.next_state),e.note,e.actor,displayDate(e.created_at)])),heading('سجل التحقق والموافقة'),table(['الإجراء','البيان','الموظف','التاريخ'],r.audit.map(e=>[tr(auditLabels[e.kind]||e.kind),auditDetail(e),e.actor,displayDate(e.created_at)])),heading('مشاركة صور الجهاز مع العميل'),p('الصور خاصة افتراضياً. لا تشارك صوراً تحتوي معلومات شخصية أو محتوى خاصاً غير ضروري. تظهر الصور المحددة فقط للحساب المرتبط.'));
  area.append(table(['نوع الصورة','الملاحظة','التاريخ','المشاركة','الإجراء'],r.photos.map(e=>[tr(e.kind==='before'?'قبل الإصلاح':'بعد الإصلاح'),e.note,displayDate(e.created_at),tr(e.shared?'مشتركة مع العميل':'خاصة بالموظفين'),write&&r.linked?button(e.shared?'إيقاف مشاركة الصورة':'مشاركة الصورة',async()=>{if(!confirm(tr(e.shared?'إيقاف مشاركة الصورة؟':'أؤكد أن صورة الجهاز لا تحتوي معلومات خاصة غير ضرورية.')))return;await start('photo',id,{evidence:e.id,visible:!e.shared})}):'—'])),p('يعرض هذا الملف أحدث 50 سجلاً لكل نوع؛ تبقى السجلات السابقة محفوظة.'));
 }
 root.append(heading('إدارة هوية العميل وموافقته'),p('اختر طلب الصيانة لعرض سجل القرارات وإدارة التحقق. لا تُدخل رقم الهوية أو صور وثائق شخصية.'),form([['repair','معرّف طلب الصيانة','text']],'فتح ملف الموافقة',v=>load(v.repair)),retry,status,area);return root;
}
