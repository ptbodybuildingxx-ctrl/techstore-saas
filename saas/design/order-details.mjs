// Shared owner/customer rendering and strict validation of order detail responses.
import {tr,currentLanguage} from './i18n.mjs';
const id=x=>typeof x==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(x);
const amount=x=>Number.isSafeInteger(x)&&x>=0&&x<=100000000000000;
const date=x=>typeof x==='string'&&Number.isFinite(Date.parse(x));
const states={pending:'بانتظار المحل',confirmed:'مؤكد من المحل',dispatched:'تم إرسال الطلب',fulfilled:'تم التسليم',cancelled:'ملغى',requested:'طلب توصيل',delivered:'تم التسليم'};
export const shopOrderState=r=>tr(states[r.state==='pending'?(r.delivery_state==='dispatched'?'dispatched':r.confirmed?'confirmed':r.delivery_state||'pending'):r.state]||r.state);
export function validateShopOrder(r,order,channel){
 if(!r||r.id!==order||r.channel!==channel||!['online','guest'].includes(channel)||!['SYP','USD','EUR'].includes(r.currency)||!['pending','fulfilled','cancelled'].includes(r.state)||typeof r.confirmed!=='boolean'||!['pickup','delivery'].includes(r.delivery_method)||!(r.delivery_state===null||['requested','dispatched','delivered','cancelled'].includes(r.delivery_state))||!date(r.created_at)||!(r.finished_at===null||date(r.finished_at))||!(r.sale_id===null||id(r.sale_id))||![r.address,r.phone,r.tracking_reference].every(x=>x===null||typeof x==='string')||![r.total_minor,r.gross_minor,r.discount_minor].every(amount)||r.gross_minor-r.discount_minor!==r.total_minor||!Array.isArray(r.items)||r.items.length<1||r.items.length>50||!Array.isArray(r.history)||r.history.length>20)throw Error('Invalid order details');
 if(r.items.some(x=>!id(x.product_id)||typeof x.name!=='string'||typeof x.sku!=='string'||typeof x.snapshot!=='boolean'||!Number.isInteger(x.units)||x.units<1||x.units>100||!amount(x.unit_minor)||x.unit_minor<1||!amount(x.net_minor)||x.net_minor<1||x.net_minor>x.unit_minor)||new Set(r.items.map(x=>x.product_id)).size!==r.items.length||r.items.reduce((s,x)=>s+x.units*x.unit_minor,0)!==r.gross_minor||r.items.reduce((s,x)=>s+x.units*x.net_minor,0)!==r.total_minor||r.history.some(x=>!['pending','confirmed','dispatched','fulfilled','cancelled'].includes(x.event)||!date(x.created_at)))throw Error('Invalid order lines or history');
 if(r.phone_verified_now!==undefined&&typeof r.phone_verified_now!=='boolean'||r.carrier!==undefined&&r.carrier!==null&&(typeof r.carrier.name!=='string'||r.carrier.name.length>100||!date(r.carrier.recorded_at)))throw Error('Invalid delivery information');
 return r
}
export function renderShopOrder(root,r,{money,action=null}={}){
 const n=(tag,text='')=>{const el=document.createElement(tag);el.textContent=text;return el};
 const when=x=>x?new Date(x).toLocaleString(currentLanguage()==='en'?'en-GB':'ar-SY',{timeZone:'Asia/Damascus'}):'—';
 const pair=(label,value)=>n('p',tr(label)+': '+String(value??'—'));
 root.replaceChildren(n('h3',tr('تفاصيل الطلب')),pair('معرّف الطلب',r.id),pair('الحالة',shopOrderState(r)),pair('التاريخ',when(r.created_at)),pair('طريقة الاستلام',tr(r.delivery_method==='delivery'?'توصيل يدوي':'استلام من المحل')));
 if(r.customer_name)root.append(pair('اسم العميل',r.customer_name));
 if(r.address)root.append(pair('عنوان التوصيل',r.address));
 if(r.phone)root.append(pair('الهاتف',r.phone));
 if(r.phone_verified_now!==undefined)root.append(pair('مطابقة الهاتف المؤكد حالياً',tr(r.phone_verified_now?'مطابق للهاتف المؤكد في الحساب':'غير مؤكد أو غير مطابق')));
 if(r.carrier)root.append(pair('شركة الشحن',r.carrier.name),pair('وقت توثيق التسليم للشحن',when(r.carrier.recorded_at)),n('p',tr('بيانات الشحن موثقة من المحل وليست تحديثاً آلياً من شركة الشحن.')));
 if(r.tracking_reference)root.append(pair('مرجع التتبع',r.tracking_reference));
 if(r.finished_at)root.append(pair('وقت إغلاق الطلب',when(r.finished_at)));
 const wrap=n('div'),table=n('table'),head=n('thead'),hr=n('tr'),body=n('tbody');wrap.className='scroll';
 for(const label of ['المنتج','الرمز','الكمية','السعر قبل الخصم','سعر الوحدة النهائي','الإجمالي'])hr.append(n('th',tr(label)));
 head.append(hr);table.append(head,body);wrap.append(table);
 for(const x of r.items){const row=n('tr');for(const v of [x.name+(x.snapshot?'':' — '+tr('اسم حالي، طلب تاريخي')),x.sku,x.units,money(x.unit_minor,r.currency),money(x.net_minor,r.currency),money(x.net_minor*x.units,r.currency)])row.append(n('td',String(v)));body.append(row)}
 root.append(wrap,pair('الإجمالي قبل الخصم',money(r.gross_minor,r.currency)),pair('الخصم',money(r.discount_minor,r.currency)),pair('الإجمالي',money(r.total_minor,r.currency)),n('h4',tr('سجل حالات الطلب')));
 if(r.history.length){if(!r.history.some(e=>e.event==='pending'))root.append(n('p',tr('لم يتم تسجيل جميع الحالات التاريخية قبل هذا التحديث.')));const list=n('ol');for(const e of r.history)list.append(n('li',tr(states[e.event])+' — '+when(e.created_at)));root.append(list)}else root.append(n('p',tr('طلب تاريخي؛ لا يوجد سجل حالات محفوظ قبل هذا التحديث.')));
 if(r.state==='pending'&&r.delivery_state!=='dispatched')root.append(n('p',tr('تأكيد المحل لا يحجز البضاعة ولا يثبت دفعاً. يعاد التحقق من السعر والمخزون عند التسليم أو الإرسال.')));
 if(action)root.append(action);
}
