// Encrypted snapshot validation and read-only ledger UI. Never authorize a server operation here.
import {tr} from '../design/i18n.mjs';
const uuid=v=>typeof v==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(v);
const nullableId=v=>v===null||uuid(v),text=(v,max)=>typeof v==='string'&&v.length<=max;
const number=(v,min=0,max=100000000000000)=>Number.isSafeInteger(v)&&v>=min&&v<=max;
const currency=v=>['SYP','USD','EUR'].includes(v),date=v=>typeof v==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(v)&&Number.isFinite(Date.parse(v));
const timestamp=v=>typeof v==='string'&&Number.isFinite(Date.parse(v));
const actions=['read','customer_create','customer_edit','credit_sale','debt_payment','standalone_open','standalone_payment','payable_manage'];
const key=(kind,id)=>kind+':'+id,kindOk=v=>v==='invoice'||v==='standalone';
function index(rows,valid,getKey){if(!Array.isArray(rows))throw Error('Invalid offline ledger rows');const m=new Map();for(const r of rows){if(!r||!valid(r))throw Error('Invalid offline ledger row');const k=getKey(r);if(m.has(k))throw Error('Duplicate offline ledger row');m.set(k,r)}return m}
export function validateOfflineReceivables(v,identity={}){
 if(!v||v.version!==1||!uuid(v.store)||!uuid(v.actor)||!['owner','cashier'].includes(v.role)||!nullableId(v.branch)||v.role==='owner'&&v.branch!==null||!timestamp(v.capturedAt)||!Array.isArray(v.actions)||v.actions.length>8||new Set(v.actions).size!==v.actions.length||!v.actions.includes('read')||v.actions.some(a=>!actions.includes(a))||identity.store!==undefined&&v.store!==identity.store||identity.actor!==undefined&&v.actor!==identity.actor||identity.role!==undefined&&v.role!==identity.role||v.role==='cashier'&&identity.branch!==undefined&&v.branch!==identity.branch)throw Error('Invalid offline ledger identity');
 const customers=index(v.customers,r=>uuid(r.id)&&text(r.name,160)&&r.name.trim()&&text(r.phone,60),r=>r.id);
 const branches=index(v.branches,r=>uuid(r.id)&&text(r.name,160)&&(v.role==='owner'||r.id===v.branch),r=>r.id);
 if(v.branch!==null&&!branches.has(v.branch))throw Error('Missing assigned branch');
 const debts=index(v.debts,d=>kindOk(d.kind)&&uuid(d.id)&&nullableId(d.customer_id)&&(d.customer_id===null?d.kind==='standalone':customers.has(d.customer_id))&&text(d.party,160)&&text(d.phone,60)&&nullableId(d.branch_id)&&(d.branch_id===null||branches.has(d.branch_id))&&(v.role==='owner'||d.branch_id===v.branch)&&text(d.branch_name,160)&&['receivable','payable'].includes(d.direction)&&(d.direction!=='payable'||d.kind==='standalone'&&v.actions.includes('payable_manage'))&&currency(d.currency)&&number(d.principal_minor,1)&&number(d.deposit_minor,0,d.principal_minor)&&number(d.remaining_minor,0,d.principal_minor-d.deposit_minor)&&number(d.installment_count,1,120)&&date(d.first_due)&&timestamp(d.created_at)&&text(d.notes,300)&&(d.kind==='invoice'?typeof d.invoice_number==='string'&&/^\d+$/.test(d.invoice_number):d.invoice_number===null&&d.deposit_minor===0),d=>key(d.kind,d.id));
 const remaining=new Map(),installments=new Map();
 index(v.schedule,r=>kindOk(r.kind)&&uuid(r.debt_id)&&debts.has(key(r.kind,r.debt_id))&&number(r.number,1,debts.get(key(r.kind,r.debt_id)).installment_count)&&date(r.due_date)&&number(r.amount_minor,1)&&number(r.paid_minor,0,r.amount_minor)&&number(r.waived_minor,0,r.amount_minor-r.paid_minor)&&(r.kind==='invoice'||r.waived_minor===0),r=>key(r.kind,r.debt_id)+':'+r.number);
 for(const r of v.schedule){const k=key(r.kind,r.debt_id);remaining.set(k,(remaining.get(k)||0n)+BigInt(r.amount_minor-r.paid_minor-r.waived_minor));installments.set(k,(installments.get(k)||0)+1)}
 for(const [k,d] of debts)if(remaining.get(k)!==BigInt(d.remaining_minor)||installments.get(k)!==d.installment_count)throw Error('Incomplete offline schedule');
 index(v.payments,p=>kindOk(p.kind)&&uuid(p.debt_id)&&debts.has(key(p.kind,p.debt_id))&&uuid(p.id)&&number(p.amount_minor,1)&&timestamp(p.created_at)&&text(p.method,64)&&typeof p.is_deposit==='boolean'&&text(p.memo,300)&&(p.kind==='invoice'||!p.is_deposit&&p.method==='cash'),p=>key(p.kind,p.id));
 return v;
}
export function ledgerFresh(v,now=Date.now()){const age=now-Date.parse(v?.capturedAt);return Number.isFinite(age)&&age>=-60000&&age<=86400000}
const money=(n,c)=>{const s=BigInt(n).toString().padStart(3,'0');return s.slice(0,-2)+'.'+s.slice(-2)+' '+c};
const normal=v=>String(v??'').normalize('NFKC').toLowerCase().trim();
const matches=(q,...values)=>!q||values.some(v=>normal(v).includes(q));
const today=()=>{const p=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Damascus',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date());return ['year','month','day'].map(k=>p.find(x=>x.type===k).value).join('-')};
const direction=d=>tr(d==='receivable'?'لنا (ذمم مدينة)':'علينا (ذمم دائنة)');
const labelStatus=s=>tr(({settled:'مسدد أو مسوى',overdue:'متأخر',open:'غير مسدد'})[s]);
const typeLabel=k=>tr(k==='invoice'?'دين فاتورة':'دين مستقل');
const el=(tag,t)=>{const n=document.createElement(tag);if(t!==undefined)n.textContent=String(t);return n};
function button(t,fn,disabled=false){const n=el('button',tr(t));n.type='button';n.onclick=fn;n.disabled=disabled;return n}
function table(headers,rows){const wrap=el('div');wrap.className='scroll';const t=el('table'),h=el('thead'),r=el('tr'),b=el('tbody');for(const x of headers)r.append(el('th',tr(x)));h.append(r);for(const cells of rows){const row=el('tr');for(const c of cells){const td=el('td');if(c instanceof Node)td.append(c);else td.textContent=String(c??'—');row.append(td)}b.append(row)}t.append(h,b);wrap.append(t);return wrap}
function groupButtons(...nodes){const n=el('div');n.className='design-actions';n.append(...nodes.filter(Boolean));return n}
function aggregate(debts){const m=new Map();for(const d of debts){const k=d.direction+':'+d.currency,t=m.get(k)||{direction:d.direction,currency:d.currency,principal:0n,remaining:0n};t.principal+=BigInt(d.principal_minor);t.remaining+=BigInt(d.remaining_minor);m.set(k,t)}return [...m.values()].sort((a,b)=>(a.direction+a.currency).localeCompare(b.direction+b.currency))}
function summary(debts){return aggregate(debts).map(t=>direction(t.direction)+' · '+tr('أصل الدين')+': '+money(t.principal,t.currency)+' · '+tr('المتبقي')+': '+money(t.remaining,t.currency)).join(' | ')||'—'}
export function createOfflineReceivablePanel({root,canDraft,onDraft,onCredit}){
 let data=null,customerIndex=new Map(),customerId='',branch='all',mode='all',c='all',status='all',query='',customerPage=0,debtPage=0,paymentPage=0,detailKey=null,blocked=false,scheduled=new Map(),payments=new Map(),lastDay='';
 const pageSize=25;
 const filters=el('div'),results=el('div');filters.className='design-actions';
 const q=el('input');q.type='search';q.maxLength=160;
 const customer=el('select'),branchSelect=el('select'),modeSelect=el('select'),currencySelect=el('select'),statusSelect=el('select');
 const specs=[[q,'بحث بالاسم أو الهاتف أو رقم الفاتورة'],[customer,'العميل'],[branchSelect,'الفرع'],[modeSelect,'نوع الذمة'],[currencySelect,'العملة'],[statusSelect,'الحالة']];
 for(const [control,label] of specs){const l=el('label',tr(label));l.append(control);filters.append(l)}
 function opts(select,options,value){const f=document.createDocumentFragment();for(const [id,label] of options)f.append(new Option(label,id));select.replaceChildren(f);select.value=value}
 function resetPages(){customerPage=debtPage=paymentPage=0;detailKey=null}
 q.oninput=()=>{query=q.value;resetPages();paint()};customer.onchange=()=>{customerId=customer.value;resetPages();paint()};branchSelect.onchange=()=>{branch=branchSelect.value;resetPages();paint()};modeSelect.onchange=()=>{mode=modeSelect.value;resetPages();paint()};currencySelect.onchange=()=>{c=currencySelect.value;resetPages();paint()};statusSelect.onchange=()=>{status=statusSelect.value;resetPages();paint()};
 function draftButton(t,fn){const n=button(t,fn,blocked);n.dataset.localDraft='1';return n}
 function pager(page,total,fn){return groupButtons(button('السابق',()=>fn(page-1),page<=0),el('span',String(page+1)+' / '+String(Math.max(1,Math.ceil(total/pageSize)))),button('التالي',()=>fn(page+1),(page+1)*pageSize>=total))}
 function statusOf(d){return d.remaining_minor===0?'settled':(scheduled.get(key(d.kind,d.id))||[]).some(i=>i.due_date<lastDay&&i.paid_minor+i.waived_minor<i.amount_minor)?'overdue':'open'}
 function branchName(d){return d.branch_id?d.branch_name:tr('المستودع الرئيسي')}
 function set(s){clear();if(!s||!ledgerFresh(s))return;data=s;customerIndex=new Map(s.customers.map(x=>[x.id,x]));for(const i of s.schedule){const k=key(i.kind,i.debt_id);if(!scheduled.has(k))scheduled.set(k,[]);scheduled.get(k).push(i)}for(const p of s.payments){const k=key(p.kind,p.debt_id);if(!payments.has(k))payments.set(k,[]);payments.get(k).push(p)}root.hidden=false;root.replaceChildren(el('h2',tr('سجلات العملاء والديون دون اتصال')),filters,results);paint()}
 function clear(){data=null;customerIndex.clear();scheduled.clear();payments.clear();customerId='';branch=mode=c=status='all';query='';q.value='';resetPages();customer.replaceChildren();branchSelect.replaceChildren();modeSelect.replaceChildren();currencySelect.replaceChildren();statusSelect.replaceChildren();results.replaceChildren();root.replaceChildren();root.hidden=true}
 function paint(){
  if(!data)return;if(!ledgerFresh(data)){clear();return}
  lastDay=today();root.firstChild.textContent=tr('سجلات العملاء والديون دون اتصال');
  for(const [control,label] of specs)control.parentNode.firstChild.nodeValue=tr(label);
  opts(customer,[['',tr('الكل')],...data.customers.map(x=>[x.id,x.name+' · '+(x.phone||'—')])],customerId);
  opts(branchSelect,[['all',tr('الكل')],...(data.role==='owner'||data.branch===null?[['main',tr('المستودع الرئيسي')]]:[]),...data.branches.map(x=>[x.id,x.name])],branch);
  opts(modeSelect,[['all',tr('الكل')],['receivable',direction('receivable')],...(data.actions.includes('payable_manage')?[['payable',direction('payable')]]:[]),['invoice',typeLabel('invoice')],['standalone',typeLabel('standalone')]],mode);
  opts(currencySelect,[['all',tr('الكل')],...['SYP','USD','EUR'].map(x=>[x,x])],c);
  opts(statusSelect,[['all',tr('الكل')],['open',labelStatus('open')],['overdue',labelStatus('overdue')],['settled',labelStatus('settled')]],status);
  const scope=data.role==='owner'?tr('جميع الفروع المصرح بها'):(data.branches.find(b=>b.id===data.branch)?.name||tr('المستودع الرئيسي'));
  const search=normal(query),directory=data.customers.filter(x=>(!customerId||customerId===x.id)&&matches(search,x.name,x.phone,x.id));
  const scoped=data.debts.filter(d=>(branch==='all'||(d.branch_id||'main')===branch)&&(mode==='all'||d.direction===mode||d.kind===mode)&&(c==='all'||d.currency===c));
  const debtRows=scoped.filter(d=>(!customerId||d.customer_id===customerId)&&(status==='all'||statusOf(d)===status)&&matches(search,d.party,d.phone,d.id,d.invoice_number,customerIndex.get(d.customer_id)?.name,customerIndex.get(d.customer_id)?.phone));
  const sections=[el('p',tr('نسخة قراءة فقط؛ لا تتغير الأرصدة قبل المزامنة.')+' '+tr('نسخة')+': '+data.capturedAt+' · '+scope),el('h3',tr('أرصدة النتائج حسب العملة')),el('p',summary(debtRows)),el('h3',tr('دليل العملاء'))];
  const shown=directory.slice(customerPage*pageSize,(customerPage+1)*pageSize);
  sections.push(table(['اسم العميل','الهاتف','المتبقي','الإجراء'],shown.map(x=>[x.name,x.phone,summary(scoped.filter(d=>d.customer_id===x.id)),groupButtons(button('كشف العميل',()=>{customerId=x.id;query='';q.value='';resetPages();paint()}),canDraft('customerEdit')?draftButton('تعديل بيانات العميل',()=>onDraft('customerEdit',{customer:x.id,oldName:x.name,oldPhone:x.phone,name:x.name,phone:x.phone})):null,canDraft('standaloneOpen')?draftButton('تسجيل رصيد مستقل',()=>onDraft('standaloneOpen',{customer:x.id,party:x.name,phone:x.phone,direction:'receivable'})):null,canDraft('credit')?draftButton('اختيار للبيع الآجل',()=>onCredit(x.id)):null)])),pager(customerPage,directory.length,p=>{customerPage=p;paint()}));
  sections.push(el('h3',tr('سجل الديون والأقساط')),table(['اسم الطرف','النوع','الفرع','رقم الفاتورة','أصل الدين','المتبقي','الحالة','الإجراء'],debtRows.slice(debtPage*pageSize,(debtPage+1)*pageSize).map(d=>[d.party,typeLabel(d.kind)+' · '+direction(d.direction),branchName(d),d.invoice_number??'—',money(d.principal_minor,d.currency),money(d.remaining_minor,d.currency),labelStatus(statusOf(d)),button('عرض التفاصيل',()=>{detailKey=key(d.kind,d.id);paymentPage=0;paint()})])),pager(debtPage,debtRows.length,p=>{debtPage=p;detailKey=null;paint()}));
  const d=debtRows.find(x=>key(x.kind,x.id)===detailKey);
  if(d){const k=key(d.kind,d.id),schedule=scheduled.get(k)||[],history=payments.get(k)||[],paymentKind=d.kind==='invoice'?'pay':'standalonePay';sections.push(el('h3',d.party+' · '+(d.invoice_number||d.id)),el('p',direction(d.direction)+' · '+branchName(d)+' · '+tr('المتبقي')+': '+money(d.remaining_minor,d.currency)),el('p',d.notes||''),el('p',tr('معرّف الدين')+': '+d.id));
   if(d.remaining_minor>0&&canDraft(paymentKind))sections.push(draftButton('حفظ مسودة دفعة',()=>onDraft(paymentKind,{debt:d.id,currency:d.currency})));
   sections.push(el('h4',tr('جدول الأقساط')),table(['القسط','تاريخ الاستحقاق','المبلغ','المدفوع','المسوّى','المتبقي','الحالة'],schedule.map(i=>[i.number,i.due_date,money(i.amount_minor,d.currency),money(i.paid_minor,d.currency),money(i.waived_minor,d.currency),money(i.amount_minor-i.paid_minor-i.waived_minor,d.currency),labelStatus(i.amount_minor===i.paid_minor+i.waived_minor?'settled':i.due_date<lastDay?'overdue':'open')])),el('h4',tr('سجل الدفعات')),table(['التاريخ','المبلغ','طريقة التسوية','البيان','مرجع السند'],history.slice(paymentPage*pageSize,(paymentPage+1)*pageSize).map(p=>[p.created_at,money(p.amount_minor,d.currency),p.is_deposit?tr('الدفعة الأولى'):tr(({cash:'نقدي',bank:'مصرفي'})[p.method]||p.method),p.memo||'—',p.id])),pager(paymentPage,history.length,p=>{paymentPage=p;paint()}));
  }
  results.replaceChildren(...sections);
 }
 return {set,clear,paint,controls(v){blocked=!!v;for(const b of root.querySelectorAll('[data-local-draft]'))b.disabled=blocked;},tick(){if(data&&(!ledgerFresh(data)||today()!==lastDay))paint()}};
}
