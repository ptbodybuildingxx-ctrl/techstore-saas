import {tr,currentLanguage} from '../design/i18n.mjs';
import {downloadVisibleTable} from './csv-export.mjs';

export function staffDate(value){
 if(!value)return '—';
 return new Intl.DateTimeFormat(currentLanguage()==='en'?'en-GB':'ar-SY',{dateStyle:'medium',timeStyle:'short',timeZone:'Asia/Damascus'}).format(new Date(value));
}
export function shiftHours(start,end){
 if(!end)return '—';
 const ms=Date.parse(end)-Date.parse(start);
 return Number.isFinite(ms)&&ms>=0?(ms/3600000).toFixed(2):'—';
}
const roleNames={owner:'مالك المحل',cashier:'كاشير',stock:'موظف مخزون',tech:'فني صيانة'};

export async function loadStaffRegister({api,store,section,node,table,run,money,active,onPage,onSelect}){
 const area=node('div'),navigation=node('div'),status=node('p'),first=node('button',tr('الأولى')),next=node('button',tr('التالي')),exp=node('button',tr('تصدير الصفحة الحالية CSV'));
 first.type=next.type=exp.type='button';
 status.setAttribute('role','status');
 let cursor=null;
 const valid=()=>active()&&section.isConnected;
 async function page(after){
  const rows=await api.operationsList(store,'staff',after,50);
  if(!valid())return;
  cursor=rows.length===50?rows.at(-1).user_id:null;
  onPage(rows);
  area.replaceChildren(table(['اسم الموظف','معرّف الحساب','الدور','الحالة','الفرع','الراتب الشهري','العمولة','حالة الدوام','آخر حضور','آخر انصراف','الإجراء'],rows.map(x=>{
   const button=node('button',tr('عرض سجل الموظف'));button.type='button';
   button.onclick=()=>run(async()=>{if(valid())await onSelect(x.user_id)});
   return [x.display_name||'—',x.user_id,tr(roleNames[x.role]),tr(x.active?'نشط':'موقوف'),x.branch_name||tr('كل الفروع والمستودع الرئيسي'),x.currency&&x.salary_minor!=null?money(x.salary_minor,x.currency):'—',x.commission_bps!=null?x.commission_bps/100+'%':'—',typeof x.clock_open==='boolean'?tr(x.clock_open?'مفتوح':'لا يوجد دوام مفتوح'):'—',staffDate(x.last_started_at),staffDate(x.last_ended_at),button];
  })));
  status.textContent=tr('عدد الموظفين في الصفحة')+': '+rows.length;
  first.disabled=!after;next.hidden=!cursor;exp.disabled=!rows.length;
 }
 first.onclick=()=>run(()=>page(null));next.onclick=()=>run(()=>page(cursor));
 exp.onclick=()=>{if(valid()&&confirm(tr('تصدير السجلات المعروضة إلى هذا الجهاز؟')))downloadVisibleTable(area.querySelector('table'),'techstore-staff.csv')};
 navigation.append(first,next,exp);section.append(status,area,navigation);
 await page(null);
}
