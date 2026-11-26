import {tr} from '../design/i18n.mjs';
export const permissionLabels=Object.freeze({
 sell:'تسجيل البيع',stock_adjust:'تعديل المخزون',stock_transfer:'تحويل المخزون',product_create:'إضافة منتج',repair_transition:'تغيير حالة الصيانة',repair_evidence:'توثيق الصيانة',attendance:'تسجيل الدوام',catalog_read:'قراءة الكتالوج والأسعار',stock_history_read:'قراءة سجل المخزون',sales_read:'قراءة سجل المبيعات',repair_read:'قراءة طلبات الصيانة',product_edit:'تعديل بيانات المنتج',repair_task_finish:'إنجاز مهمة الصيانة',repair_create:'استلام طلب صيانة',product_price_edit:'تعديل أسعار المنتجات',customer_create:'إضافة عميل',debt_payment:'تسجيل دفعة دين',quote_create:'إنشاء عرض سعر',quote_read:'قراءة عروض الأسعار',receipt_read:'قراءة وطباعة الإيصالات',warranty_read:'قراءة سجل الكفالات',receivable_read:'قراءة العملاء والديون والأقساط',customer_edit:'تعديل بيانات العميل',credit_sale:'إصدار فاتورة آجلة',standalone_open:'فتح ذمة مستقلة',standalone_payment:'تسديد ذمة مستقلة',payable_manage:'إدارة الذمم الدائنة',procurement_read:'قراءة المشتريات والموردين',supplier_write:'إضافة وتعديل الموردين',purchase_write:'استلام مشتريات آجلة',notifications_read:'قراءة إشعارات العمل',orders_read:'قراءة الطلبات الإلكترونية',orders_write:'إدارة الطلبات الإلكترونية',warranty_write:'إدارة مطالبات الكفالة',returns_read:'قراءة المرتجعات',returns_write:'تسجيل المرتجعات',used_read:'قراءة المستعمل',used_write:'إدارة المستعمل',loyalty_read:'قراءة سجل الولاء',invoice_repair:'إصدار فاتورة صيانة',receipt_write:'تسجيل سند قبض أو صرف',finance_read:'قراءة المحاسبة',finance_write:'تعديل المحاسبة',staff_admin:'إدارة الموظفين',store_admin:'إدارة المحل والمتجر',backup_admin:'إدارة النسخ الاحتياطي'
});
export const denialActions=Object.freeze(Object.keys(permissionLabels).slice(0,31));
const reasons={allowed:'متاحة',role:'خارج الدور أو الفرع',grant:'تحتاج منحة صريحة',license:'الترخيص غير نشط',denied:'ممنوعة',dependency:'صلاحية مرتبطة ممنوعة',inactive:'الحساب موقوف'};
export function validateAccessMatrix(r,user){
 if(!r||r.user!==user||!['owner','cashier','stock','tech'].includes(r.role)||typeof r.active!=='boolean'||!(r.branch===null||typeof r.branch==='string')||!Array.isArray(r.denials)||new Set(r.denials).size!==r.denials.length||r.denials.some(a=>!denialActions.includes(a))||!Array.isArray(r.operations)||r.operations.length!==Object.keys(permissionLabels).length||new Set(r.operations.map(x=>x.action)).size!==r.operations.length||r.operations.some(x=>!Object.hasOwn(permissionLabels,x.action)||typeof x.editable!=='boolean'||typeof x.denied!=='boolean'||typeof x.effective!=='boolean'||!Object.hasOwn(reasons,x.reason)||x.denied!==r.denials.includes(x.action)))throw Error('Invalid permission matrix');
 return r;
}
export function createStaffPermissionsPanel({api,store,area,node,table,run,write,active}){
 let selected=null,generation=0;
 async function load(user){
  const token=++generation;selected=null;area.replaceChildren(node('p',tr('تحميل صلاحيات الموظف')));
  const state=await api.staffAccessMatrix(store,user);if(token!==generation||!active())return;
  selected=state;render(state);
 }
 function render(state){
  const desired=new Set(state.denials),status=node('p',''),save=node('button',tr('حفظ جميع القيود'));save.type='button';
  const dirty=()=>state.denials.length!==desired.size||state.denials.some(a=>!desired.has(a));
  const controls=[];
  const rows=state.operations.map(o=>{
   const cell=node('div','');
   if(write&&o.editable){const label=node('label',''),input=node('input');input.type='checkbox';input.checked=o.denied;label.append(input,node('span',tr('منع')));input.onchange=()=>{if(input.checked)desired.add(o.action);else desired.delete(o.action);status.textContent=dirty()?tr('تغييرات غير محفوظة'):'';save.dataset.permissionDenied=String(!dirty());save.disabled=!dirty()};cell.append(label);controls.push(input)}
   else cell.textContent=o.denied?tr('ممنوعة'):'—';
   return [tr(permissionLabels[o.action]),tr(reasons[o.reason]),cell];
  });
  save.dataset.permissionDenied='true';save.disabled=true;
  save.onclick=()=>run(async()=>{if(!active()||selected!==state||!dirty())return;for(const x of controls)x.disabled=true;try{const next=await api.staffAccessSave(store,state,[...desired]);if(!active()||selected!==state)return;selected=next;render(next);area.prepend(node('p',tr('تم حفظ الصلاحيات')))}finally{for(const x of controls)x.disabled=false}});
  area.replaceChildren(node('p',tr('الدور')+': '+tr(({owner:'المالك',cashier:'كاشير',stock:'مخزون',tech:'فني'})[state.role])+' — '+tr(state.active?'نشط':'موقوف')),node('p',tr('الحالة الفعلية قبل الحفظ. إزالة المنع لا تمنح صلاحيات خارج الدور أو الفرع أو المنح الصريحة.')),table(['العملية','الحالة الفعلية','قيد الموظف'],rows));
  if(write&&state.operations.some(o=>o.editable))area.append(save,status);
 }
 return {load};
}
