// Cold-start operational draft forms. Local role is a presentation hint, never permission.
const uuid=x=>typeof x==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(x);
const text=(v,max,optional=false)=>{if(typeof v!=='string'||v.trim().length>max||(!optional&&!v.trim()))throw Error('Invalid text');return v.trim()};
const id=v=>{if(!uuid(v))throw Error('Invalid reference');return v};
const money=(v,zero=false)=>{if(typeof v!=='string'||!/^\d{1,12}(?:\.\d{1,2})?$/.test(v))throw Error('Invalid amount');const [w,d='']=v.split('.'),n=Number(w)*100+Number(d.padEnd(2,'0'));if(!Number.isSafeInteger(n)||n<(zero?0:1)||n>100000000000000)throw Error('Invalid amount');return n};
const units=v=>{if(typeof v!=='string'||!/^\d{1,7}$/.test(v)||Number(v)<1||Number(v)>1000000)throw Error('Invalid units');return Number(v)};
const select=(v,choices)=>{if(!choices.includes(v))throw Error('Invalid choice');return v};
const field=(key,label,type='text',options)=>({key,label,type,options});
export const draftForms=Object.freeze({
 customer:{label:'إضافة عميل',fields:[field('name','اسم العميل'),field('phone','الهاتف (اختياري)','optional')]},
 customerEdit:{label:'تعديل بيانات العميل',fields:[field('customer','معرّف العميل'),field('oldName','الاسم السابق'),field('oldPhone','الهاتف السابق (اختياري)','optional'),field('name','اسم العميل'),field('phone','الهاتف (اختياري)','optional')]},
 pay:{label:'تحصيل دفعة دين فاتورة',fields:[field('debt','معرّف الدين'),field('currency','العملة','select',[['SYP','SYP'],['USD','USD'],['EUR','EUR']]),field('amount','المبلغ')]},
 standaloneOpen:{label:'تسجيل رصيد مستقل',fields:[field('customer','معرّف العميل (اختياري)','optional'),field('direction','نوع الذمة','select',[['receivable','لنا (ذمم مدينة)'],['payable','علينا (ذمم دائنة)']]),field('party','اسم الطرف'),field('phone','الهاتف (اختياري)','optional'),field('currency','العملة','select',[['SYP','SYP'],['USD','USD'],['EUR','EUR']]),field('amount','أصل الدين'),field('count','عدد الأقساط الشهرية','number'),field('due','تاريخ أول قسط','date'),field('notes','ملاحظات','optional')]},
 standalonePay:{label:'تسجيل دفعة مستقلة',fields:[field('debt','معرّف الدين'),field('amount','المبلغ بعملة الدين'),field('memo','ملاحظات الدفعة (اختياري)','optional')]},
 stockCount:{label:'الجرد الفعلي للمخزون',fields:[field('product','المنتج','countProduct'),field('actual','العدد الفعلي','countNumber'),field('reason','سبب الجرد ومرجعه')]},
 supplierProfile:{label:'إضافة مورد تفصيلي',fields:[field('name','اسم المورد'),field('contact','مرجع التواصل (اختياري)','optional'),field('phone','الهاتف','optional'),field('email','البريد الإلكتروني','optional'),field('address','العنوان','optional')]},
 procureReceipt:{label:'تسجيل شراء مع استحقاق',fields:[field('supplier','معرّف المورد'),field('product','معرّف المنتج','product'),field('units','الكمية','number'),field('cost','تكلفة القطعة'),field('paid','المبلغ المدفوع (0 للآجل)'),field('reference','مرجع الشراء'),field('due','تاريخ الاستحقاق (اختياري)','optional')]},
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
export function createColdDraft(snapshot,kind,v,requestId=crypto.randomUUID()){
 if((snapshot?.role!=='owner'&&!(snapshot?.role==='stock'&&kind==='stockCount'))||!uuid(snapshot.store)||!uuid(requestId)||!Object.hasOwn(draftForms,kind)||!['SYP','USD','EUR'].includes(snapshot.currency)||!(snapshot.branch===null||uuid(snapshot.branch)))throw Error('Invalid draft scope');
 const base={kind,store:snapshot.store,requestId},c=snapshot.currency,b=snapshot.branch;
 switch(kind){
 case 'customer':return {...base,name:text(v.name,160),phone:text(v.phone,60,true)};
 case 'customerEdit':return {...base,customer:id(v.customer),oldName:text(v.oldName,160),oldPhone:text(v.oldPhone,60,true),name:text(v.name,160),phone:text(v.phone,60,true)};
 case 'pay':return {...base,debt:id(v.debt),currency:select(v.currency,['SYP','USD','EUR']),amount:money(v.amount)};
 case 'standaloneOpen':{const direction=select(v.direction,['receivable','payable']),count=units(v.count),amount=money(v.amount),due=text(v.due,10);if(count>120||count>amount||direction==='payable'&&count!==1||!/^\d{4}-\d{2}-\d{2}$/.test(due)||!Number.isFinite(Date.parse(due))||due<'1900-01-01'||due>'2200-01-01')throw Error('Invalid standalone terms');return {...base,payload:{customer:v.customer?id(v.customer):null,branch:b,direction,party:text(v.party,160),phone:text(v.phone,60,true),currency:select(v.currency,['SYP','USD','EUR']),amount,count,due,notes:text(v.notes,300,true)}}}
 case 'standalonePay':return {...base,payload:{debt:id(v.debt),amount:money(v.amount),memo:text(v.memo,300,true)}};

 case 'stockCount':{const product=id(v.product),p=snapshot.countProducts?.find(x=>x.id===product);if(!p||typeof v.actual!=='string'||!/^\d{1,10}$/.test(v.actual)||Number(v.actual)>1000000000)throw Error('Invalid count');return {...base,branch:b,reason:text(v.reason,160),items:[{id:product,event:crypto.randomUUID(),expected:p.expected,actual:Number(v.actual)}]}}

 case 'supplierProfile':return {...base,id:null,name:text(v.name,160),contact:text(v.contact,160,true),phone:text(v.phone,80,true),email:text(v.email,160,true),address:text(v.address,300,true),archived:false};
 case 'procureReceipt':{const product=id(v.product),u=units(v.units),cost=money(v.cost),paid=money(v.paid,true),due=text(v.due,10,true);if(!snapshot.products.some(x=>x.id===product)||cost>100000000||paid>u*cost||due&&!/^\d{4}-\d{2}-\d{2}$/.test(due))throw Error('Invalid receipt');return {...base,branch:b,currency:c,supplier:id(v.supplier),reference:text(v.reference,300),lines:[{product_id:product,units:u,unit_cost_minor:cost}],paid,due:due||null,batch:false}}
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
