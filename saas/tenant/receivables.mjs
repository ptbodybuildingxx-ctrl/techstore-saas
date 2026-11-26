import {tr} from '../design/i18n.mjs';
import {downloadCsvRows} from './csv-export.mjs';

export function createReceivableRegister({api,store,run,print}){
 const el=id=>document.getElementById(id),node=(tag,text)=>{const n=document.createElement(tag);n.textContent=text;return n};
 const money=(v,c)=>{const s=BigInt(v).toString().padStart(3,'0');return s.slice(0,-2)+'.'+s.slice(-2)+' '+c};
 const status={open:'غير مسدد',overdue:'متأخر',settled:'مسدد أو مسوى',recorded:'مسجل'};
 const headers=['العميل','الهاتف','رقم الفاتورة','القسط','التاريخ','المبلغ','الدفعة الأولى / المسدد','تخفيض بسبب مرتجع','المتبقي','الحالة'];
 let customer=null,filter=null,offset=0,result=null;
 const form=el('receivableRegisterForm');
 function reset(){customer=null;filter=null;offset=0;result=null;form.reset();el('receivableRegisterRows').replaceChildren();el('receivableRegisterTotals').replaceChildren();el('receivableRegisterPrev').disabled=true;el('receivableRegisterNext').disabled=true;el('receivableRegisterCsv').disabled=true;el('receivableRegisterTitle').textContent=''}
 function cells(values){const r=document.createElement('tr');for(const v of values)r.append(node('td',String(v)));return r}
 function values(x){const m=result.mode,c=x.currency;return [x.name,x.phone||'—',x.invoice_number,m==='schedule'?x.installment_number:'—',x.due_date||x.recorded_at?.slice(0,10)||'—',money(x.amount_minor,c),m==='payments'?'—':money(x.paid_minor,c),m==='schedule'?money(x.waived_minor,c):'—',m==='payments'?'—':money(x.remaining_minor,c),m==='payments'?tr(x.method==='cash'?'قبض نقدي':'طريقة التسوية')+' ('+x.method+')':tr(status[x.status])]}
 function receipt(x){const s=store();if(!s||s.id!==result?.store_id)return;const a=node('article','');a.className='receipt-paper';for(const [tag,v] of [['h2',s.name],['h3',tr(x.method==='cash'?'سند قبض':'إثبات تسوية')],['p',tr('مرجع السند')+': '+x.item_id],['p',tr('رقم الفاتورة')+': '+x.invoice_number],['p',tr('العميل')+': '+x.name],['p',tr('الهاتف')+': '+(x.phone||'—')],['p',x.recorded_at],['h2',money(x.amount_minor,x.currency)],['p',tr(x.is_deposit?'الدفعة الأولى':'دفعة دين')],['p',tr('طريقة التسوية')+': '+x.method],['p',tr('توقيع المستلم')+': __________________']])a.append(node(tag,v));print(a)}
 function paint(){if(!result)return;const records=result.rows.slice(0,50);el('receivableRegisterTotals').replaceChildren(...result.totals.map(x=>node('p',tr('أصل الدين')+': '+money(x.principal,x.currency)+' · '+tr('الدفعة الأولى')+': '+money(x.deposit,x.currency)+' · '+tr('المتبقي')+': '+money(x.remaining,x.currency))));
 el('receivableRegisterRows').replaceChildren(...records.map(x=>{const r=cells(values(x)),td=node('td','');if(result.mode==='payments'){const b=node('button',tr('طباعة سند'));b.type='button';b.onclick=()=>run(()=>receipt(x));td.append(b)}r.append(td);return r}));el('receivableRegisterPrev').disabled=offset===0;el('receivableRegisterNext').disabled=result.rows.length<=50||offset>=100000;el('receivableRegisterCsv').disabled=!records.length;el('receivableRegisterTitle').textContent=customer?tr('كشف العميل')+' · '+customer.name:tr('سجل الذمم والأقساط')}
 async function fetchPage(next=0){const s=store();if(s?.role!=='owner'||!filter)return;const r=await api.receivableRegister(s.id,filter,next);if(store()?.id!==s.id)return;result=r;offset=next;paint()}
 async function start(){const f=new FormData(form);filter={mode:String(f.get('mode')),query:String(f.get('query')).trim(),customer:customer?.id||null,currency:String(f.get('currency'))||null,status:String(f.get('status'))};result=null;el('receivableRegisterRows').replaceChildren();el('receivableRegisterTotals').replaceChildren();el('receivableRegisterCsv').disabled=true;el('receivableRegisterPrev').disabled=true;el('receivableRegisterNext').disabled=true;await fetchPage()}
 form.addEventListener('submit',e=>{e.preventDefault();run(start)});
 el('receivableRegisterPrev').onclick=()=>run(()=>fetchPage(Math.max(0,offset-50)));
 el('receivableRegisterNext').onclick=()=>run(()=>fetchPage(offset+50));
 el('receivableRegisterAll').onclick=()=>run(async()=>{reset();await start()});
 el('receivableRegisterCsv').onclick=()=>run(()=>{if(!result||store()?.id!==result.store_id)return;downloadCsvRows([headers.map(tr),...result.rows.slice(0,50).map(values)],'receivables.csv')});
 document.addEventListener('techstore-languagechange',paint);
 return {reset,async select(x){reset();customer={id:x.id,name:x.name};await start()}};
}
