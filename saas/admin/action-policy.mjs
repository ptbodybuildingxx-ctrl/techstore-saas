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
  area.replaceChildren(t('p','القيود المركزية تُضاف إلى قيود المالك ولا تمنح صلاحيات جديدة. القسم الأول يقيّد عمليات الموظفين؛ القسم الثاني يمنع تعديلات محددة للجميع. لا يسمح بحذف السجلات المالية.'));
  if(pending)area.append(t('p','إجراء غير مؤكد؛ استخدم إعادة الطلب نفسه.'),n('code',pending.request),button('إعادة الطلب نفسه',send),button('مراجعة حالة الإجراء',load),button('ترك الطلب غير المؤكد بعد المراجعة',async()=>{if(confirm(tr('راجع السجل والحالة قبل بدء إجراء جديد. هل تريد ترك المرجع غير المؤكد؟'))){pending=null;await load()}}));
  const select=n('select');for(const p of data.plans){const o=n('option',p.name+' ('+p.code+')');o.value=p.code;select.append(o)}if(data.plans.some(p=>p.code===selected))select.value=selected;selected=select.value;select.disabled=!!pending;select.onchange=()=>{selected=select.value;paint()};area.append(label('الباقة',select),editor);paint();
  area.append(t('h3','سجل القيود المركزية'));for(const h of data.history){const d=n('div');d.className='panel';const added=h.after_denied.filter(k=>!h.before_denied.includes(k)),removed=h.before_denied.filter(k=>!h.after_denied.includes(k));d.append(n('strong',h.plan_code+' — '+when(h.created_at)),n('p',h.reference+' — '+h.actor),n('p',tr('القيود المضافة')+': '+(added.map(k=>tr(centralActionLabels[k])).join('، ')||'—')),n('p',tr('القيود المرفوعة')+': '+(removed.map(k=>tr(centralActionLabels[k])).join('، ')||'—')));area.append(d)}
 }
 function paint(){editor.replaceChildren();if(!data)return;const p=data.plans.find(x=>x.code===selected);if(!p)return;const f=n('form'),controls={},ref=n('input');ref.required=true;ref.maxLength=200;
 for(const [group,title] of [[true,'قيود قراءة وكتابة الموظفين'],[false,'قيود التعديل والأرشفة والإلغاء لجميع الأدوار']]){const fs=n('fieldset'),legend=t('legend',title);fs.append(legend);for(const k of centralActionKeys.filter(k=>k.startsWith('staff_')===group)){const input=n('input');input.type='checkbox';input.checked=p.denied.includes(k);controls[k]=input;fs.append(label(tr('منع')+': '+tr(centralActionLabels[k]),input))}fs.disabled=!!pending;f.append(fs)}
 const submit=t('button','حفظ القيود المركزية');submit.type='submit';submit.disabled=ref.disabled=!!pending;f.append(label('سبب الإجراء أو مرجع الموافقة',ref),submit);f.onsubmit=e=>{e.preventDefault();run(async()=>{if(pending||!ref.value.trim()||selected!==p.code)return;const desired=centralActionKeys.filter(k=>controls[k].checked);if(desired.length===p.denied.length&&desired.every(k=>p.denied.includes(k)))return;if(!confirm(tr('تأكيد تغيير القيود التفصيلية لجميع محلات الباقة؟')+' — '+p.name))return;pending={request:crypto.randomUUID(),plan:p.code,expected:p.revision,desired,reference:ref.value.trim()};editor.replaceChildren(n('code',pending.request),button('إعادة الطلب نفسه',send),button('مراجعة حالة الإجراء',load));await send()})};editor.append(f)
 }
 return {load,reset(){pending=null;selected=null;data=null;area.replaceChildren();editor.replaceChildren()}}
}
