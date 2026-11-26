// Operator initiates and finalizes only after both verified account holders consent.
import {tr} from '../design/i18n.mjs';
export function createTransferControl({api,root,run}){
 const n=(tag,text)=>{const a=document.createElement(tag);if(text!==undefined)a.textContent=text;return a},t=(tag,x)=>n(tag,tr(x));
 const dialog=n('dialog'),body=n('div'),button=(title,fn)=>{const b=t('button',title);b.type='button';b.onclick=()=>run(fn);return b};
 const close=button('إغلاق',async()=>dialog.close());dialog.append(body,close);root.append(dialog);
 let pending=null,selected=null;
 async function send(){if(!pending||!api.signedIn())return;const p=pending;await api.transferPropose(p.store,p.id,p.old,p.next,p.proof);pending=null;await show(p.store)}
 async function show(store){
  if(pending&&pending.store!==store)throw Error('Resolve previous transfer');const r=await api.transfersReview(store);if(!api.signedIn())return;selected=store;
  if(pending&&r.some(x=>x.id===pending.id))pending=null;
  body.replaceChildren(t('h2','نقل ملكية المحل'),n('code',store),t('p','يتطلب نقل الملكية حساباً جديداً مؤكداً ومصادقة ثنائية من الطرفين والمدير. يوافق كل طرف من شاشة الهوية قبل الاعتماد النهائي. لا تُحذف بيانات المحل.'));
  if(pending){body.append(t('p','إجراء غير مؤكد؛ استخدم إعادة الطلب نفسه.'),n('code',pending.id),button('إعادة الطلب نفسه',send),button('مراجعة حالة الإجراء',()=>show(store)),button('ترك الطلب غير المؤكد بعد المراجعة',async()=>{if(confirm(tr('راجع السجل والحالة قبل بدء إجراء جديد. هل تريد ترك المرجع غير المؤكد؟'))){pending=null;await show(store)}}))}
  else if(!r.some(x=>x.state==='pending'&&Date.parse(x.expires_at)>Date.now())){
   const form=n('form'),fields=[['المالك الحالي (UUID)',36],['المالك الجديد (UUID)',36],['سبب الإجراء أو مرجع الموافقة',200]].map(([label,max])=>{const x=n('input');x.required=true;x.maxLength=max;const l=t('label',label);l.append(x);form.append(l);return x});
   const submit=t('button','إنشاء طلب نقل الملكية');submit.type='submit';form.append(submit);form.onsubmit=e=>{e.preventDefault();run(async()=>{if(pending||selected!==store||!dialog.open||!fields[2].value.trim())return;if(!confirm(tr('إنشاء طلب نقل الملكية؟')))return;pending={store,id:crypto.randomUUID(),old:fields[0].value.trim(),next:fields[1].value.trim(),proof:fields[2].value.trim()};body.replaceChildren(n('code',pending.id),button('إعادة الطلب نفسه',send),button('مراجعة حالة الإجراء',()=>show(store)));await send()})};body.append(form)
  }
  for(const x of r){const d=n('section');d.className='panel';d.append(n('strong',x.id),n('p',tr('المالك الحالي')+': '+x.old_owner),n('p',tr('المالك الجديد')+': '+x.new_owner),n('p',x.reference),n('p',tr(({pending:'قيد الانتظار',completed:'مكتمل',cancelled:'ملغى'})[x.state])+' — '+x.expires_at),n('p',tr('موافقة المالك الحالي')+': '+tr(x.old_approved_at?'نعم':'لا')+' / '+tr('موافقة المالك الجديد')+': '+tr(x.new_approved_at?'نعم':'لا')));
   if(x.state==='pending'&&!pending){d.append(t('p','شارك معرّف الطلب مع الطرفين ليوافقا من شاشة الهوية.'));
   if(x.old_approved_at&&x.new_approved_at&&Date.parse(x.expires_at)>Date.now())d.append(button('اعتماد نقل الملكية نهائياً',async()=>{if(selected!==store||!confirm(tr('سيُمنع المالك السابق من الوصول إلى هذا المحل. اعتماد النقل؟')))return;await api.transferFinalize(store,x.id,true);await show(store)}));
   d.append(button('إلغاء طلب النقل',async()=>{if(selected!==store||!confirm(tr('إلغاء طلب النقل؟')))return;await api.transferFinalize(store,x.id,false);await show(store)}))}
   body.append(d)
  }
  if(!dialog.open)dialog.showModal();
 }
 return {show,reset(){pending=null;selected=null;if(dialog.open)dialog.close();body.replaceChildren()}}
}
