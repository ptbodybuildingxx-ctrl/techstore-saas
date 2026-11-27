import {ledgerFresh} from './offline-receivables.mjs';
// Cold-start operational draft forms. Local role is a presentation hint, never permission.
const uuid=x=>typeof x==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(x);
const text=(v,max,optional=false)=>{if(typeof v!=='string'||v.trim().length>max||(!optional&&!v.trim()))throw Error('Invalid text');return v.trim()};
const id=v=>{if(!uuid(v))throw Error('Invalid reference');return v};
const money=(v,zero=false)=>{if(typeof v!=='string'||!/^\d{1,12}(?:\.\d{1,2})?$/.test(v))throw Error('Invalid amount');const [w,d='']=v.split('.'),n=Number(w)*100+Number(d.padEnd(2,'0'));if(!Number.isSafeInteger(n)||n<(zero?0:1)||n>100000000000000)throw Error('Invalid amount');return n};
const units=v=>{if(typeof v!=='string'||!/^\d{1,7}$/.test(v)||Number(v)<1||Number(v)>1000000)throw Error('Invalid units');return Number(v)};
const select=(v,choices)=>{if(!choices.includes(v))throw Error('Invalid choice');return v};
const field=(key,label,type='text',options)=>({key,label,type,options});
function productLines(snapshot,raw,{cost=false,optional=false,max=100}={}){
 if(typeof raw!=='string'||raw.length>14000)throw Error('Invalid lines');
 if(!raw.trim()&&optional)return [];
 const rows=raw.trim().split(/\r?\n/).filter(s=>s.trim()).map(s=>{
 const [product,quantity,price,...extra]=s.split(',').map(x=>x.trim());
 const product_id=id(product),p=snapshot.products.find(x=>x.id===product_id),u=units(quantity);
 if(!p||extra.length||(cost?price===undefined:price!==undefined)||(!cost&&u>10000))throw Error('Invalid line');
 const value=cost?money(price):p.price;if(value>100000000)throw Error('Invalid price');
 return {product_id,units:u,[cost?'unit_cost_minor':'expected_price_minor']:value};
 });
 if(!rows.length||rows.length>max||new Set(rows.map(x=>x.product_id.toLowerCase())).size!==rows.length||rows.reduce((n,x)=>n+BigInt(x.units)*BigInt(cost?x.unit_cost_minor:x.expected_price_minor),0n)>100000000000000n)throw Error('Invalid lines total');
 return rows;
}
const day=v=>{if(typeof v!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(v)||!Number.isFinite(Date.parse(v))||new Date(v+'T00:00:00Z').toISOString().slice(0,10)!==v)throw Error('Invalid date');return v};
export const draftForms=Object.freeze({
 reviewedPrice:{label:'تعديل سعر منتج مع مقارنة السعر السابق',fields:[field('product','المنتج','product'),field('price','السعر الجديد')]},
 payrollFinal:{label:'التسوية النهائية للراتب',fields:[field('payroll','معرّف مسير الراتب'),field('expected','المبلغ المتبقي الذي تم صرفه'),field('confirmed','تأكيد الصرف الفعلي','select',[['no','لا'],['yes','نعم']])]},
 payrollAdvance:{label:'سلفة موظف',fields:[field('user','معرّف الموظف'),field('amount','المبلغ'),field('reference','مرجع السلفة'),field('confirmed','تأكيد الصرف الفعلي','select',[['no','لا'],['yes','نعم']])]},
 payrollOffset:{label:'تسوية سلفة مع الراتب',fields:[field('payroll','معرّف مسير الراتب'),field('advance','معرّف السلفة'),field('amount','المبلغ')]},
 orderConfirm:{label:'مسودة تأكيد طلب متجر',fields:[field('order','معرّف الطلب'),field('channel','قناة الطلب','select',[['online','حساب عميل'],['guest','ضيف']])]},
 branchApproval:{label:'مسودة اعتماد النتيجة المالية المراجعة',fields:[field('from','من','date'),field('to','إلى','date'),field('previous','مرجع الاعتماد السابق (اختياري)','optional'),field('digest','بصمة المراجعة المالية'),field('proof','مرجع مراجعة المحاسب'),field('confirmed','تأكيد المراجعة','select',[['no','لا'],['yes','نعم']])]},
 taxFiling:{label:'مسودة توثيق الإقرار الضريبي الخارجي',fields:[field('taxKind','نوع الضريبة','select',[['income','ضريبة الدخل'],['indirect','ضريبة غير مباشرة']]),field('from','من','date'),field('to','إلى','date'),field('previous','مرجع الإقرار السابق (اختياري)','optional'),field('digest','بصمة مراجعة التسوية'),field('filedOn','تاريخ الإقرار الخارجي','date'),field('authority','الجهة'),field('reference','مرجع الإقرار'),field('legal','المرجع القانوني'),field('declared','المبلغ المصرح به'),field('explanation','التوضيح (اختياري)','optional'),field('confirmed','تأكيد الإقرار الخارجي الفعلي','select',[['no','لا'],['yes','نعم']])]},

 purchaseBatch:{label:'فواتير المشتريات متعددة المنتجات',fields:[field('supplier','معرّف المورد'),field('reference','مرجع الشراء'),field('lines','معرّف المنتج,الكمية,تكلفة الوحدة؛ سطر لكل منتج','multiline'),field('paid','المبلغ المدفوع (0 للآجل)'),field('due','تاريخ الاستحقاق (اختياري)','optional')]},
 repairCheckout:{label:'إصدار فاتورة صيانة',fields:[field('repair','معرّف الصيانة الجاهزة'),field('service','أجرة الخدمة (0 مسموح)'),field('lines','معرّف المنتج,الكمية؛ سطر لكل قطعة (اختياري)','optionalMultiline'),field('warranty','أيام الضمان (0–730)','countNumber')]},
 quote:{label:'عروض الأسعار',fields:[field('customer','اسم العميل'),field('until','صالح حتى','date'),field('lines','معرّف المنتج,الكمية؛ سطر لكل منتج','multiline')]},
 costIntake:{label:'إدخال المخزون بالتكلفة',fields:[field('product','المنتج','product'),field('units','الكمية','number'),field('cost','تكلفة القطعة'),field('note','مرجع الشراء')]},
 branchTransfer:{label:'نقل المخزون',fields:[field('product','المنتج','product'),field('source','معرّف فرع المصدر (فارغ للمستودع الرئيسي)','optional'),field('target','معرّف فرع الوجهة (فارغ للمستودع الرئيسي)','optional'),field('units','الكمية','number')]},
 cashMovement:{label:'تسجيل حركة نقدية',fields:[field('cashKind','نوع الحركة','select',[['funding','تمويل'],['expense','مصروف'],['exchange','صرف عملة']]),field('amount','المبلغ'),field('targetCurrency','العملة المستلمة عند الصرف','select',[['','—'],['SYP','SYP'],['USD','USD'],['EUR','EUR']]),field('targetAmount','المبلغ المستلم عند الصرف (اختياري)','optional'),field('note','البيان'),field('confirmed','تأكيد الحركة النقدية الفعلية','select',[['no','لا'],['yes','نعم']])]},
 payrollAdjustment:{label:'إضافات وحسميات الرواتب',fields:[field('payroll','معرّف مسير الراتب'),field('adjustment','نوع التسوية','select',[['bonus','مكافأة'],['deduction','حسم']]),field('amount','المبلغ'),field('reason','السبب')]},
 payrollPartial:{label:'دفعة راتب جزئية',fields:[field('payroll','معرّف مسير الراتب'),field('amount','المبلغ بعملة الراتب'),field('confirmed','تأكيد الصرف الفعلي','select',[['no','لا'],['yes','نعم']])]},
 payrollReverse:{label:'عكس إضافة أو حسم راتب',fields:[field('original','معرّف التسوية الأصلية'),field('reason','السبب')]},
 accountingAdjust:{label:'تسجيل قيد موثق',fields:[field('adjustment','نوع القيد','select',[['funding_equity','تمويل رأس المال'],['funding_loan','تمويل قرض'],['stock_equity','مخزون رأس المال'],['expense_rent','إيجار'],['expense_payroll','رواتب'],['expense_utilities','خدمات'],['expense_other','مصروف آخر'],['expense_tax_payment','سداد ضريبة الدخل'],['expense_indirect_tax_payment','سداد ضريبة غير مباشرة'],['expense_loan_payment','سداد قرض'],['expense_capital_withdrawal','مسحوبات رأس المال']]),field('source','مرجع الحركة'),field('amount','المبلغ'),field('reference','رقم المستند'),field('note','البيان')]},

 customer:{label:'إضافة عميل',fields:[field('name','اسم العميل'),field('phone','الهاتف (اختياري)','optional')]},
 customerEdit:{label:'تعديل بيانات العميل',fields:[field('customer','معرّف العميل'),field('oldName','الاسم السابق'),field('oldPhone','الهاتف السابق (اختياري)','optional'),field('name','اسم العميل'),field('phone','الهاتف (اختياري)','optional')]},
 pay:{label:'تحصيل دفعة دين فاتورة',fields:[field('debt','معرّف الدين'),field('currency','العملة','select',[['SYP','SYP'],['USD','USD'],['EUR','EUR']]),field('amount','المبلغ')]},
 standaloneOpen:{label:'تسجيل رصيد مستقل',fields:[field('customer','معرّف العميل (اختياري)','optional'),field('direction','نوع الذمة','select',[['receivable','لنا (ذمم مدينة)'],['payable','علينا (ذمم دائنة)']]),field('party','اسم الطرف'),field('phone','الهاتف (اختياري)','optional'),field('currency','العملة','select',[['SYP','SYP'],['USD','USD'],['EUR','EUR']]),field('amount','أصل الدين'),field('count','عدد الأقساط الشهرية','number'),field('due','تاريخ أول قسط','date'),field('notes','ملاحظات','optional')]},
 standalonePay:{label:'تسجيل دفعة مستقلة',fields:[field('debt','معرّف الدين'),field('amount','المبلغ بعملة الدين'),field('memo','ملاحظات الدفعة (اختياري)','optional')]},
 stockCount:{label:'الجرد الفعلي للمخزون',fields:[field('product','المنتج','countProduct'),field('actual','العدد الفعلي','countNumber'),field('reason','سبب الجرد ومرجعه')]},
 supplierProfile:{label:'إضافة مورد تفصيلي',fields:[field('name','اسم المورد'),field('contact','مرجع التواصل (اختياري)','optional'),field('phone','الهاتف','optional'),field('email','البريد الإلكتروني','optional'),field('address','العنوان','optional')]},
 procureReceipt:{label:'تسجيل شراء مع استحقاق',fields:[field('supplier','معرّف المورد'),field('product','معرّف المنتج','product'),field('units','الكمية','number'),field('cost','تكلفة القطعة'),field('paid','المبلغ المدفوع (0 للآجل)'),field('reference','مرجع الشراء'),field('due','تاريخ الاستحقاق (اختياري)','optional')]},
 procureDue:{label:'تاريخ استحقاق الشراء',fields:[field('purchase','معرّف الشراء'),field('due','تاريخ الاستحقاق (اختياري)','optional')]},
 tradein:{label:'تقييم واستبدال الأجهزة',fields:[field('customer','معرّف العميل'),field('device','الجهاز'),field('serial','الرقم التسلسلي (اختياري)','optional'),field('note','ملاحظات'),field('amount','المبلغ')]},
 saleClaimOpen:{label:'فتح مطالبة كفالة منتج',fields:[field('sale','معرّف فاتورة البيع'),field('product','المنتج','product'),field('units','الكمية','number'),field('reason','السبب')]},
 saleClaimTransition:{label:'حفظ متابعة المطالبة',fields:[field('claim','معرّف المطالبة'),field('next','الحالة','select',[['accepted','قبول'],['rejected','رفض'],['resolved','إغلاق بعد المعالجة']]),field('note','البيان')]},
 supplier:{label:'إضافة مورد',fields:[field('name','اسم المورد'),field('contact','مرجع التواصل (اختياري)','optional')]},
 purchase:{label:'تسجيل شراء',fields:[field('supplier','معرّف المورد'),field('product','معرّف المنتج','product'),field('units','الكمية','number'),field('cost','تكلفة القطعة'),field('paid','المبلغ المدفوع (0 للآجل)'),field('note','مرجع الشراء')]},
 supplierPayment:{label:'سداد مورد',fields:[field('purchase','معرّف الشراء'),field('amount','الدفعة')]},
 repair:{label:'استلام جهاز',fields:[field('customer','معرّف العميل'),field('device','الجهاز'),field('imei','IMEI (اختياري)','optional'),field('fault','العطل')]},
 transition:{label:'تحديث الصيانة',fields:[field('repair','معرّف الطلب'),field('next','الحالة','select',[['diagnosing','قيد الفحص'],['repairing','قيد الإصلاح'],['ready','جاهز للتسليم'],['cancelled','ملغى']]),field('note','ملاحظات')]},
 supplierReturn:{label:'تسجيل مرتجع المورد',fields:[field('purchase','معرّف الشراء'),field('units','الكمية','number'),field('reason','سبب المرتجع'),field('refund','تأكيد قبض النقد إن استحق','select',[['no','لم أقبض نقداً'],['yes','أؤكد قبض المبلغ المستحق']])]},
 warrantyTransition:{label:'تحديث الضمان',fields:[field('claim','معرّف الطلب'),field('next','الحالة','select',[['accepted','قبول'],['rejected','رفض'],['resolved','إغلاق بعد المعالجة']]),field('note','البيان')]},
 warrantyPart:{label:'تسجيل قطعة ضمان',fields:[field('claim','معرّف مطالبة الضمان المقبولة'),field('product','معرّف القطعة','product'),field('units','الكمية','number'),field('reason','السبب')]},
 repairRefund:{label:'تسجيل الاسترداد',fields:[field('invoice','معرّف الفاتورة'),field('amount','المبلغ بعملة الفاتورة'),field('reason','سبب الاسترداد'),field('confirmed','تأكيد رد النقد للعميل','select',[['no','لم يتم الرد'],['yes','تم رد المبلغ']])]},
 warrantyOpen:{label:'طلب ضمان',fields:[field('invoice','معرّف الفاتورة'),field('reason','السبب')]},
 voucher:{label:'تسجيل سند',fields:[field('voucherKind','نوع السند','select',[['salary','راتب'],['commission','عمولة'],['bonus','مكافأة'],['rent','إيجار'],['utilities','خدمات'],['other','أخرى'],['receipt','قبض']]),field('party','الطرف أو الموظف'),field('reference','مرجع السند'),field('amount','المبلغ')]},
 campaign:{label:'حفظ مسودة حملة',fields:[field('title','عنوان الحملة'),field('body','نص العرض'),field('from','من','date'),field('to','إلى','date')]}
});
const receivableDraftActions=Object.freeze({customer:'customer_create',customerEdit:'customer_edit',pay:'debt_payment',standaloneOpen:'standalone_open',standalonePay:'standalone_payment',credit:'credit_sale'});
export function coldDraftAllowed(snapshot,kind){
 if(!snapshot)return false;
 if(kind==='stockCount')return ['owner','stock'].includes(snapshot.role)&&!!snapshot.countProducts?.length;
 if(snapshot.ledger&&Object.hasOwn(receivableDraftActions,kind))return ledgerFresh(snapshot.ledger)&&snapshot.receivableActions?.includes('read')&&snapshot.receivableActions.includes(receivableDraftActions[kind]);
 if(snapshot.role==='owner'){if(['costIntake','cashMovement'].includes(kind)&&snapshot.branch!==null)return false;if(['purchaseBatch','quote','costIntake','branchTransfer'].includes(kind)&&!snapshot.products.length)return false;return true;}
 return snapshot.role==='cashier'&&Array.isArray(snapshot.receivableActions)&&snapshot.receivableActions.includes('read')&&Object.hasOwn(receivableDraftActions,kind)&&snapshot.receivableActions.includes(receivableDraftActions[kind]);
}
export function coldPayablesAllowed(snapshot){return snapshot?.role==='owner'||(snapshot?.role==='cashier'&&snapshot.receivableActions?.includes('payable_manage'))}
export function createColdDraft(snapshot,kind,v,requestId=crypto.randomUUID()){
 if(!coldDraftAllowed(snapshot,kind)||!uuid(snapshot.store)||!uuid(requestId)||!Object.hasOwn(draftForms,kind)||!['SYP','USD','EUR'].includes(snapshot.currency)||!(snapshot.branch===null||uuid(snapshot.branch)))throw Error('Invalid draft scope');
 const base={kind,store:snapshot.store,requestId},c=snapshot.currency,b=snapshot.branch;
 switch(kind){
 case 'reviewedPrice':{const product=id(v.product),p=snapshot.products.find(x=>x.id===product),price=money(v.price);if(!p||price>100000000||price===p.price)throw Error('Invalid price change');return {...base,product,currency:c,expected:p.price,price}}
 case 'payrollFinal':if(v.confirmed!=='yes')throw Error('Confirm actual payment');return {...base,payroll:id(v.payroll),expected:money(v.expected,true),currency:c,confirm:true};
 case 'payrollAdvance':if(v.confirmed!=='yes')throw Error('Confirm actual advance');return {...base,user:id(v.user),branch:b,currency:c,amount:money(v.amount),reference:text(v.reference,160),confirm:true};
 case 'payrollOffset':return {...base,payroll:id(v.payroll),advance:id(v.advance),amount:money(v.amount)};
 case 'orderConfirm':return {...base,order:id(v.order),channel:select(v.channel,['online','guest'])};
 case 'branchApproval':case 'taxFiling':{
 const from=day(v.from),to=day(v.to),digest=text(v.digest,64);if(from>to||!(/^[a-f0-9]{64}$/).test(digest)||v.confirmed!=='yes')throw Error('Reviewed evidence required');
 const common={...base,from,to,previous:v.previous?id(v.previous):null,digest,confirm:true};
 if(kind==='branchApproval')return {...common,proof:text(v.proof,160)};
 return {...common,taxKind:select(v.taxKind,['income','indirect']),currency:c,filedOn:day(v.filedOn),authority:text(v.authority,120),reference:text(v.reference,160),legal:text(v.legal,200),declared:money(v.declared,true),explanation:text(v.explanation,500,true)};
 }
 case 'purchaseBatch':{const lines=productLines(snapshot,v.lines,{cost:true}),paid=money(v.paid,true),total=lines.reduce((n,x)=>n+x.units*x.unit_cost_minor,0);if(paid>total)throw Error('Invalid paid amount');return {...base,kind:'procureReceipt',branch:b,currency:c,supplier:id(v.supplier),reference:text(v.reference,160),lines,paid,due:v.due?day(v.due):null,batch:true}}
 case 'repairCheckout':{const warranty=Number(v.warranty);if(!/^\d{1,3}$/.test(v.warranty)||warranty>730)throw Error('Invalid warranty');return {...base,repair:id(v.repair),currency:c,service:money(v.service,true),lines:productLines(snapshot,v.lines,{optional:true,max:50}),warranty}}
 case 'quote':return {...base,currency:c,customer:text(v.customer,160),until:day(v.until),lines:productLines(snapshot,v.lines)};
 case 'costIntake':{const product=id(v.product),cost=money(v.cost,true);if(b!==null||!snapshot.products.some(x=>x.id===product)||cost>100000000)throw Error('Main warehouse intake only');return {...base,product,currency:c,units:units(v.units),cost,note:text(v.note,300)}}
 case 'branchTransfer':{const product=id(v.product),source=v.source?id(v.source):null,target=v.target?id(v.target):null;if(source===target||!snapshot.products.some(x=>x.id===product))throw Error('Invalid transfer');return {...base,product,source,target,units:units(v.units)}}
 case 'cashMovement':{if(b!==null||v.confirmed!=='yes')throw Error('Main treasury and actual confirmation required');const cashKind=select(v.cashKind,['funding','expense','exchange']),exchange=cashKind==='exchange',targetCurrency=exchange?select(v.targetCurrency,['USD','SYP','EUR']):null;if(exchange?targetCurrency===c:!!(v.targetCurrency||v.targetAmount))throw Error('Invalid currency');return {...base,cashKind,currency:c,amount:money(v.amount),note:text(v.note,300),targetCurrency,targetAmount:exchange?money(v.targetAmount):null}}
 case 'payrollAdjustment':return {...base,payroll:id(v.payroll),adjustment:select(v.adjustment,['bonus','deduction']),amount:money(v.amount),reason:text(v.reason,160)};
 case 'payrollPartial':if(v.confirmed!=='yes')throw Error('Confirm actual disbursement');return {...base,payroll:id(v.payroll),amount:money(v.amount),confirm:true};
 case 'payrollReverse':return {...base,original:id(v.original),reason:text(v.reason,160)};
 case 'accountingAdjust':return {...base,adjustment:select(v.adjustment,draftForms.accountingAdjust.fields[0].options.map(x=>x[0])),source:id(v.source),currency:c,amount:money(v.amount),reference:text(v.reference,160),note:text(v.note,300)};
 case 'customer':return {...base,name:text(v.name,160),phone:text(v.phone,60,true)};
 case 'customerEdit':{const customer=id(v.customer),oldName=text(v.oldName,160),oldPhone=text(v.oldPhone,60,true);if(snapshot.ledger&&!snapshot.ledger.customers.some(x=>x.id===customer&&x.name===oldName&&x.phone===oldPhone))throw Error('Customer not in snapshot');return {...base,customer,oldName,oldPhone,name:text(v.name,160),phone:text(v.phone,60,true)}}
 case 'pay':{const debt=id(v.debt),currency=select(v.currency,['SYP','USD','EUR']),amount=money(v.amount);if(snapshot.ledger&&!snapshot.ledger.debts.some(d=>d.kind==='invoice'&&d.id===debt&&d.currency===currency&&amount<=d.remaining_minor))throw Error('Payment exceeds captured debt or reference not found');return {...base,debt,currency,amount}}
 case 'standaloneOpen':{const direction=select(v.direction,['receivable','payable']),count=units(v.count),amount=money(v.amount),due=text(v.due,10);if(count>120||count>amount||direction==='payable'&&(!coldPayablesAllowed(snapshot)||count!==1)||!/^\d{4}-\d{2}-\d{2}$/.test(due)||!Number.isFinite(Date.parse(due))||due<'1900-01-01'||due>'2200-01-01')throw Error('Invalid standalone terms');const customer=v.customer?id(v.customer):null,party=text(v.party,160),phone=text(v.phone,60,true);if(customer&&snapshot.ledger&&!snapshot.ledger.customers.some(x=>x.id===customer&&x.name===party&&x.phone===phone))throw Error('Customer not in snapshot');return {...base,payload:{customer,branch:b,direction,party,phone,currency:select(v.currency,['SYP','USD','EUR']),amount,count,due,notes:text(v.notes,300,true)}}}
 case 'standalonePay':{const debt=id(v.debt),amount=money(v.amount);if(snapshot.ledger&&!snapshot.ledger.debts.some(d=>d.kind==='standalone'&&d.id===debt&&amount<=d.remaining_minor&&(d.direction==='receivable'||coldPayablesAllowed(snapshot))))throw Error('Payment exceeds captured debt or reference not found');return {...base,payload:{debt,amount,memo:text(v.memo,300,true)}}}

 case 'stockCount':{const product=id(v.product),p=snapshot.countProducts?.find(x=>x.id===product);if(!p||typeof v.actual!=='string'||!/^\d{1,10}$/.test(v.actual)||Number(v.actual)>1000000000)throw Error('Invalid count');return {...base,branch:b,reason:text(v.reason,160),items:[{id:product,event:crypto.randomUUID(),expected:p.expected,actual:Number(v.actual)}]}}

 case 'supplierProfile':return {...base,id:null,name:text(v.name,160),contact:text(v.contact,160,true),phone:text(v.phone,80,true),email:text(v.email,160,true),address:text(v.address,300,true),archived:false};
 case 'procureReceipt':{const product=id(v.product),u=units(v.units),cost=money(v.cost),paid=money(v.paid,true),due=text(v.due,10,true);if(!snapshot.products.some(x=>x.id===product)||cost>100000000||paid>u*cost||due&&!/^\d{4}-\d{2}-\d{2}$/.test(due))throw Error('Invalid receipt');return {...base,branch:b,currency:c,supplier:id(v.supplier),reference:text(v.reference,300),lines:[{product_id:product,units:u,unit_cost_minor:cost}],paid,due:due||null,batch:false}}
 case 'procureDue':{const due=text(v.due,10,true);if(due&&(!/^\d{4}-\d{2}-\d{2}$/.test(due)||!Number.isFinite(Date.parse(due))))throw Error('Invalid due date');return {...base,purchase:id(v.purchase),due:due||null}}
 case 'tradein':return {...base,branch:b,currency:c,customer:id(v.customer),device:text(v.device,160),serial:text(v.serial,80,true),note:text(v.note,300),amount:money(v.amount)};
 case 'saleClaimOpen':{const product=id(v.product),u=units(v.units);if(u>10000||!snapshot.products.some(x=>x.id===product))throw Error('Invalid claim');return {...base,sale:id(v.sale),product,units:u,reason:text(v.reason,300)}}
 case 'saleClaimTransition':return {...base,claim:id(v.claim),next:select(v.next,['accepted','rejected','resolved']),note:text(v.note,300)};
 case 'supplier':return {...base,name:text(v.name,160),contact:text(v.contact,160,true)};
 case 'purchase':{const product=id(v.product),u=units(v.units),cost=money(v.cost),paid=money(v.paid,true);if(!snapshot.products.some(x=>x.id===product)||cost>100000000||paid>u*cost)throw Error('Invalid purchase');return {...base,branch:b,currency:c,supplier:id(v.supplier),product,units:u,cost,paid,note:text(v.note,300)}}
 case 'supplierPayment':return {...base,purchase:id(v.purchase),currency:c,amount:money(v.amount)};
 case 'repair':{const imei=text(v.imei,15,true);if(imei&&!/^\d{15}$/.test(imei))throw Error('Invalid IMEI');return {...base,branch:b,customer:id(v.customer),device:text(v.device,160),imei:imei||null,fault:text(v.fault,300)}}
 case 'transition':return {...base,repair:id(v.repair),next:select(v.next,['diagnosing','repairing','ready','cancelled']),note:text(v.note,300)};
 case 'supplierReturn':return {...base,purchase:id(v.purchase),units:units(v.units),reason:text(v.reason,300),confirmRefund:select(v.refund,['no','yes'])==='yes'};
 case 'warrantyTransition':return {...base,claim:id(v.claim),next:select(v.next,['accepted','rejected','resolved']),note:text(v.note,300)};
 case 'warrantyPart':{const product=id(v.product);if(!snapshot.products.some(x=>x.id===product))throw Error('Unknown product');return {...base,claim:id(v.claim),product,units:units(v.units),reason:text(v.reason,300)}}
 case 'repairRefund':if(v.confirmed!=='yes')throw Error('Confirm actual refund');return {...base,invoice:id(v.invoice),amount:money(v.amount),reason:text(v.reason,300),confirm:true};
 case 'warrantyOpen':return {...base,invoice:id(v.invoice),reason:text(v.reason,300)};
 case 'voucher':return {...base,branch:b,currency:c,voucherKind:select(v.voucherKind,['salary','commission','bonus','rent','utilities','other','receipt']),party:text(v.party,160),reference:text(v.reference,160),amount:money(v.amount)};
 case 'campaign':if(![v.from,v.to].every(x=>typeof x==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(x)&&Number.isFinite(Date.parse(x)))||v.from>v.to)throw Error('Invalid dates');return {...base,title:text(v.title,120),body:text(v.body,600),from:v.from,to:v.to};
 default:throw Error('Unsupported operation');
 }
}
