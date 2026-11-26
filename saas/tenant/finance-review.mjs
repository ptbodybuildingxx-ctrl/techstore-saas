import {tr} from '../design/i18n.mjs';
const types=[['all','الكل'],['sale','فاتورة بيع'],['repair','فاتورة صيانة'],['sale_return','مرتجع بيع'],['repair_refund','مرتجع صيانة'],['purchase','فاتورة شراء'],['supplier_return','مرتجع مورد']];
const regimes=[['consumption_expenditure','رسم الإنفاق الاستهلاكي'],['sales_tax','ضريبة المبيعات'],['exempt','إعفاء موثق'],['outside_scope','خارج النطاق']];
const treatments=[['pending_review','بانتظار المحاسب'],['not_applicable','لا توجد ضريبة مدخلات'],['nonrecoverable_in_cost','ضريبة غير قابلة للخصم ضمن التكلفة المسجلة'],['potential_credit','خصم محتمل غير مرحّل']];
const title=(pairs,k)=>tr(pairs.find(x=>x[0]===k)?.[1]||k);
const day=()=>new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Damascus',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
function helpers({api,node,run,store,active,write,blocked}){
 const requests=new Map();
 const text=(tag,s)=>node(tag,tr(s));
 const button=(label,fn)=>{const b=text('button',label);b.type='button';b.onclick=()=>run(fn);return b};
 const record=async(kind,data)=>{if(!write||!active()||!navigator.onLine||blocked())throw Error('Online owner confirmation required');const key=JSON.stringify([kind,data]);if(!requests.has(key))requests.set(key,crypto.randomUUID());const r=await api.financeWrite(store,kind,{...data,req:requests.get(key)});requests.delete(key);return r};
 const status=(area,id)=>{if(active())area.replaceChildren(text('p','تم الحفظ'),node('code',id))};
 return {text,button,record,status}
}
export function createBranchFinanceReview(opts){
 const {api,node,form,table,money,store,active,write}=opts,{text,button,record,status}=helpers(opts);
 const panel=node('div'),result=node('div'),notice=node('div'),decision=node('div');
 panel.append(text('h3','اعتماد الأرصدة ونتائج الفروع'),text('p','اعتماد الافتتاح يتم في يوم دمشق قبل أي حركة محاسبية، بعد مطابقة الجرد والنقد والذمم. لا ينشئ أرصدة وهمية ولا يعد إقراراً قانونياً.'));
 if(write)panel.append(form([['proof','مرجع الجرد والمطابقة','text']],'اعتماد افتتاح اليوم',async v=>{if(!confirm(tr('أؤكد مطابقة النقد والجرد والذمم والمستندات.')))return;status(notice,await record('anchor',{proof:v.proof.trim(),confirmed:true}))}),form([['debt','معرّف الدين المستقل الافتتاحي','text'],['proof','مرجع المستند المحاسبي','text']],'تصنيف الدين الافتتاحي ضمن رأس المال',async v=>{if(!confirm(tr('أؤكد أن الدين رصيد افتتاحي موثق وليس إيراداً أو مصروفاً للفترة.')))return;status(notice,await record('debt',{debt:v.debt.trim(),proof:v.proof.trim()}))}));
 panel.append(notice);
 async function review(from,to){const r=await api.financeReview(store,from,to);if(!active())return;const checks=[['مطابقة الافتتاح',r.opening_matched],['مطابقة الدفاتر الحالية',r.reconciled],['توازن التحويلات الداخلية',r.clearing_balanced],['تكاليف مجهولة',r.unknown_costs],['حسابات غير مصنفة',r.unclassified_accounts],['قيود دون تحديد الموقع',r.unmapped_pairs],['وحدات نقل مجهولة التكلفة',r.unknown_transfer_units],['مخرجات ضريبية غير مصنفة',r.tax.output_unclassified],['مدخلات ضريبية تحتاج مراجعة',r.tax.input_unclassified],['قيود ضريبية خارج الفترة',r.tax.late_output_postings]];
 const value=x=>typeof x==='boolean'?tr(x?'نعم':'لا'):String(x);
 result.replaceChildren(text('p',r.ready?'النتيجة قابلة للاعتماد الإداري':'نتيجة أولية: توجد شروط اعتماد غير محققة'),node('p',from+' — '+to),table(['شرط المطابقة','الحالة'],checks.map(([k,v])=>[tr(k),value(v)])),table(['الفرع','العملة','الإيراد الصافي','تكلفة البضاعة والخدمات','المصروفات','ضريبة الدخل المثبتة','النتيجة قبل الضريبة','النتيجة بعد الضريبة المثبتة','رصيد تسوية العملات'],r.rows.map(x=>[x.branch_id===null?tr('المركزي / غير الموزع'):x.name,x.currency,...['revenue','cost','expenses','income_tax','before_tax','after_recorded_tax','fx_clearing'].map(k=>money(String(x[k]).replace(/\.0+$/,''),x.currency))])),text('p','النتائج مستقلة لكل عملة، وتبقى المصروفات المشتركة في المركزي إلى حين توزيعها. تسوية العملات ليست ربحاً محققاً.'));
 if(r.approval)result.append(text('p',r.matches_approval?'مطابق لآخر اعتماد':'تغيرت البيانات منذ آخر اعتماد'),node('p',r.approval_reference+' — '+r.approval));
 decision.replaceChildren();
 if(write&&r.ready&&!r.matches_approval)decision.append(form([['proof','مرجع مراجعة المحاسب','text']],'اعتماد النتيجة الإدارية',async v=>{if(!confirm(tr('أؤكد مراجعة الضرائب وتوزيع المصروفات المشتركة وعدم اعتبار النتيجة إقراراً قانونياً.')))return;status(notice,await record('approve',{d1:from,d2:to,previous:r.approval,proof:v.proof.trim(),confirmed:true}));await review(from,to)}));
 }
 const f=form([['from','من تاريخ دمشق','date'],['to','إلى تاريخ دمشق','date']],'مراجعة نتائج الفروع',v=>review(v.from,v.to));for(const i of f.querySelectorAll('input[type=date]'))i.value=day();
 panel.append(f,result,decision);return panel
}
export function createSyTaxPanel(opts){
 const {api,node,form,table,money,minor,store,active,write}=opts,{text,button,record,status}=helpers(opts);
 const panel=node('div'),profileArea=node('div'),queue=node('div'),editor=node('div'),notice=node('div');let query=null,offset=0;
 panel.append(text('h3','ملفات الضرائب السورية والمستندات'),text('p','لا توجد نسبة افتراضية. اختر ملفاً مطابقاً للتشريع النافذ وتاريخ الفاتورة. التصنيف لفاتورة متجانسة شاملة للضريبة؛ المدخلات توثيق فقط ولا تخصم تلقائياً.'));
 async function profiles(){const rows=await api.syTaxProfiles(store);if(active())profileArea.replaceChildren(table(['الاسم','النظام الضريبي','النسبة','نافذ من','نافذ إلى','المرجع القانوني'],rows.map(x=>[x.label,title(regimes,x.regime),(x.rate_bps/100).toFixed(2)+'%',x.effective_from,x.effective_to||'—',x.legal_reference])));return rows}
 panel.append(button('عرض الملفات الضريبية',profiles),profileArea);
 if(write)panel.append(form([['label','اسم الملف الضريبي','text'],['regime','النظام الضريبي','select',regimes],['rate','النسبة %','text'],['from','نافذ من','date'],['to','نافذ إلى (اختياري YYYY-MM-DD)','optional'],['legal','المرجع القانوني','text']],'إضافة ملف ضريبي موثق',async v=>{const rate=minor(v.rate.trim(),true);if(rate>10000||v.to&&!/^\d{4}-\d{2}-\d{2}$/.test(v.to))throw Error('Invalid rate or date');if(!confirm(tr('أؤكد المرجع القانوني والنسبة وتاريخ النفاذ.')))return;status(notice,await record('profile',{label:v.label.trim(),regime:v.regime,rate,valid_from:v.from,valid_to:v.to||null,legal:v.legal.trim()}));await profiles()}));
 async function edit(x){editor.replaceChildren(node('h4',title(types,x.kind)+' — '+x.source_id),node('p',money(x.gross_minor,x.currency)));
 if(['purchase','supplier_return'].includes(x.kind)){const f=form([['amount','ضريبة المدخلات المثبتة بالمستند','text'],['treatment','معالجة المدخلات','select',treatments],['proof','مرجع المستند الضريبي','text'],['legal','المرجع القانوني','text']],'حفظ مراجعة المدخلات',async v=>{if(!confirm(tr('هذا توثيق للمدخلات فقط ولا ينشئ خصماً ضريبياً أو قيداً مالياً.')))return;status(notice,await record('input',{k:x.kind,source:x.source_id,expected_previous:x.input_revision||null,amount:minor(v.amount.trim(),true),treatment:v.treatment,proof:v.proof.trim(),legal:v.legal.trim()}));await load()});if(x.input_tax!==null&&x.input_tax!==undefined){f.elements.amount.value=money(x.input_tax,x.currency).split(' ')[0];f.elements.treatment.value=x.treatment;f.elements.proof.value=x.input_document_ref||'';f.elements.legal.value=x.input_legal_reference||''}editor.append(f);return}
 const returns=['sale_return','repair_refund'].includes(x.kind),rows=returns?[]:await profiles();if(!active())return;
 if(!returns&&!rows.length){editor.append(text('p','أضف ملفاً ضريبياً موثقاً أولاً.'));return}
 const preview=node('div');const fields=returns?[]:[['profile','الملف الضريبي','select',rows.map(p=>[p.id,p.label+' — '+(p.rate_bps/100).toFixed(2)+'%'])]];
 const f=form([...fields,['proof','مرجع المستند الضريبي','text']],'مراجعة احتساب الضريبة',async v=>{const p=await api.syTaxPreview(store,x.kind,x.source_id,returns?null:v.profile);if(!active())return;preview.replaceChildren(node('p',p.profile_label+' — '+p.legal_reference),node('p',tr('الضريبة المحتسبة')+': '+money(p.tax_minor,p.currency)),button('تأكيد تسجيل الضريبة',async()=>{if(!confirm(tr('أؤكد تصنيف المستند وفق الملف القانوني المختار.')))return;status(notice,await record('output',{k:x.kind,source:x.source_id,profile:p.profile_id,expected:p.tax_minor,proof:v.proof.trim()}));await load()}))});editor.append(f,preview)
 }
 async function load(){if(!query)return;const r=await api.syTaxQueue(store,query.from,query.to,query.kind,query.missing==='yes',offset);if(!active())return;editor.replaceChildren();queue.replaceChildren(table(['النوع','المستند','الفرع','التاريخ','الإجمالي','الملف الضريبي','ضريبة المخرجات','ضريبة المدخلات','الحالة','إجراء'],r.rows.map(x=>[title(types,x.kind),x.source_id,x.branch_id===null?tr('المركزي / غير الموزع'):x.branch_name,x.occurred_at.slice(0,10),money(x.gross_minor,x.currency),x.profile_label||'—',x.output_tax===null?'—':money(x.output_tax,x.currency),x.input_tax===null?'—':money(x.input_tax,x.currency),x.unresolved?tr('تحتاج مراجعة'):x.treatment?title(treatments,x.treatment):tr('مصنف'),write&&(x.unresolved||['purchase','supplier_return'].includes(x.kind))?button('مراجعة المستند',()=>edit(x)):'—'])));
 if(offset>0)queue.append(button('السابق',async()=>{offset-=50;await load()}));if(r.more)queue.append(button('التالي',async()=>{offset+=50;await load()}))
 }
 const search=form([['from','من تاريخ دمشق','date'],['to','إلى تاريخ دمشق','date'],['kind','نوع المستند','select',types],['missing','غير المصنف فقط','select',[['yes','نعم'],['no','لا']]]],'عرض المستندات الضريبية',async v=>{query=v;offset=0;await load()});for(const i of search.querySelectorAll('input[type=date]'))i.value=day();
 panel.append(search,notice,queue,editor);return panel
}
