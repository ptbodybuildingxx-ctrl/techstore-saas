// Cold-start operational draft forms. Local role is a presentation hint, never permission.
const uuid=x=>typeof x==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(x);
const text=(v,max,optional=false)=>{if(typeof v!=='string'||v.trim().length>max||(!optional&&!v.trim()))throw Error('Invalid text');return v.trim()};
const id=v=>{if(!uuid(v))throw Error('Invalid reference');return v};
const money=(v,zero=false)=>{if(typeof v!=='string'||!/^\d{1,12}(?:\.\d{1,2})?$/.test(v))throw Error('Invalid amount');const [w,d='']=v.split('.'),n=Number(w)*100+Number(d.padEnd(2,'0'));if(!Number.isSafeInteger(n)||n<(zero?0:1)||n>100000000000000)throw Error('Invalid amount');return n};
const units=v=>{if(typeof v!=='string'||!/^\d{1,7}$/.test(v)||Number(v)<1||Number(v)>1000000)throw Error('Invalid units');return Number(v)};
const select=(v,choices)=>{if(!choices.includes(v))throw Error('Invalid choice');return v};
const field=(key,label,type='text',options)=>({key,label,type,options});
export const draftForms=Object.freeze({
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
 if(snapshot?.role!=='owner'||!uuid(snapshot.store)||!uuid(requestId)||!Object.hasOwn(draftForms,kind)||!['SYP','USD','EUR'].includes(snapshot.currency)||!(snapshot.branch===null||uuid(snapshot.branch)))throw Error('Invalid draft scope');
 const base={kind,store:snapshot.store,requestId},c=snapshot.currency,b=snapshot.branch;
 switch(kind){
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
