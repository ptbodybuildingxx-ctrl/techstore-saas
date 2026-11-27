import {tr} from '../design/i18n.mjs';
export const permissionLabels=Object.freeze({
 sell:'تسجيل البيع',stock_adjust:'تعديل المخزون',stock_transfer:'تحويل المخزون',product_create:'إضافة منتج',repair_transition:'تغيير حالة الصيانة',repair_evidence:'توثيق الصيانة',attendance:'تسجيل الدوام',catalog_read:'قراءة الكتالوج والأسعار',stock_history_read:'قراءة سجل المخزون',sales_read:'قراءة سجل المبيعات',repair_read:'قراءة طلبات الصيانة',product_edit:'تعديل بيانات المنتج',repair_task_finish:'إنجاز مهمة الصيانة',repair_create:'استلام طلب صيانة',product_price_edit:'تعديل أسعار المنتجات',customer_create:'إضافة عميل',debt_payment:'تسجيل دفعة دين',quote_create:'إنشاء عرض سعر',quote_read:'قراءة عروض الأسعار',receipt_read:'قراءة وطباعة الإيصالات',warranty_read:'قراءة سجل الكفالات',receivable_read:'قراءة العملاء والديون والأقساط',customer_edit:'تعديل بيانات العميل',credit_sale:'إصدار فاتورة آجلة',standalone_open:'فتح ذمة مستقلة',standalone_payment:'تسديد ذمة مستقلة',payable_manage:'إدارة الذمم الدائنة',procurement_read:'قراءة المشتريات والموردين',supplier_write:'إضافة وتعديل الموردين',purchase_write:'استلام مشتريات آجلة',notifications_read:'قراءة إشعارات العمل',customer_read:'قراءة دليل العملاء',debt_read:'قراءة سجلات الديون',installment_read:'قراءة جداول الأقساط',supplier_read:'قراءة دليل الموردين',purchase_read:'قراءة فواتير المشتريات',orders_read:'قراءة الطلبات الإلكترونية',orders_write:'إدارة الطلبات الإلكترونية',warranty_write:'إدارة مطالبات الكفالة',returns_read:'قراءة المرتجعات',returns_write:'تسجيل المرتجعات',used_read:'قراءة المستعمل',used_write:'إدارة المستعمل',loyalty_read:'قراءة سجل الولاء',invoice_repair:'إصدار فاتورة صيانة',receipt_write:'تسجيل سند قبض أو صرف',finance_read:'قراءة المحاسبة',finance_write:'تعديل المحاسبة',staff_admin:'إدارة الموظفين',store_admin:'إدارة المحل والمتجر',backup_admin:'إدارة النسخ الاحتياطي'
});
export const denialActions=Object.freeze(Object.keys(permissionLabels).slice(0,36));
// Central restrictions are distinct from the owner's local employee-denial list.
export const centralActionLabels=Object.freeze({
 ...Object.fromEntries(denialActions.filter(k=>!['repair_create','product_price_edit'].includes(k)).map(k=>['staff_'+k,permissionLabels[k]])),
 product_profile_edit:'تعديل ملف المنتج',product_price_change:'إضافة وتعديل وحذف سعر المنتج',customer_profile_edit:'تعديل ملف العميل',supplier_profile_edit:'تعديل ملف المورد',supplier_archive:'أرشفة المورد واستعادته',coupon_edit:'تعديل بيانات الكوبون',coupon_disable:'إيقاف وتفعيل الكوبون',repair_cancel:'إلغاء طلب الصيانة',
 all_catalog_read:"قراءة سجلات المنتجات لجميع الأدوار",
 all_sales_read:"قراءة سجلات المبيعات لجميع الأدوار",
 all_purchase_read:"قراءة سجلات المشتريات لجميع الأدوار",
 all_supplier_read:"قراءة سجلات الموردين لجميع الأدوار",
 all_customer_read:"قراءة سجلات العملاء لجميع الأدوار",
 all_debt_read:"قراءة سجلات الديون والأقساط لجميع الأدوار",
 all_repair_read:"قراءة سجلات الصيانة لجميع الأدوار",
 all_returns_read:"قراءة سجلات المرتجعات لجميع الأدوار",
 all_order_read:"قراءة سجلات الطلبات الإلكترونية لجميع الأدوار",
 all_warranty_read:"قراءة سجلات الكفالات لجميع الأدوار",
 all_coupon_read:"قراءة سجلات الكوبونات لجميع الأدوار",
 all_finance_read:"قراءة سجلات المحاسبة لجميع الأدوار",
 all_catalog_create:"إضافة المنتجات لجميع الأدوار",
 all_sales_create:"إنشاء المبيعات لجميع الأدوار",
 all_purchase_create:"تسجيل المشتريات لجميع الأدوار",
 all_supplier_create:"إضافة الموردين لجميع الأدوار",
 all_customer_create:"إضافة العملاء لجميع الأدوار",
 all_debt_create:"إنشاء الذمم لجميع الأدوار",
 all_repair_create:"استلام الصيانة لجميع الأدوار",
 all_returns_create:"تسجيل مرتجعات العملاء لجميع الأدوار",
 all_supplier_return_create:"تسجيل مرتجعات الموردين لجميع الأدوار",
 all_repair_refund_create:"تسجيل استرداد الصيانة لجميع الأدوار",
 all_warranty_create:"إنشاء مطالبة كفالة لجميع الأدوار",
 all_coupon_create:"إضافة الكوبونات لجميع الأدوار",
 all_finance_create:"تسجيل القيود المحاسبية لجميع الأدوار",
 all_order_edit:"تحديث الطلبات الإلكترونية لجميع الأدوار",
 all_warranty_edit:"تحديث مطالبات الكفالة لجميع الأدوار",
 all_repair_edit:"تحديث طلبات الصيانة لجميع الأدوار",
 all_catalog_delete:"حذف المنتجات القابلة للحذف لجميع الأدوار",
 all_customer_delete:"حذف العملاء القابلين للحذف لجميع الأدوار",
 all_supplier_delete:"حذف الموردين القابلين للحذف لجميع الأدوار",
 all_coupon_delete:"حذف الكوبونات القابلة للحذف لجميع الأدوار",
 all_stock_transfer_create:"إنشاء تحويلات المخزون لجميع الأدوار",
 all_stock_count_create:"إنشاء جرد المخزون لجميع الأدوار",
 all_quote_create:"إنشاء عروض الأسعار لجميع الأدوار",
 all_payroll_create:"إنشاء استحقاقات الرواتب لجميع الأدوار",
 all_standalone_create:"إنشاء الذمم المستقلة لجميع الأدوار",
 all_branch_create:"إنشاء الفروع لجميع الأدوار"
});
export const centralActionKeys=Object.freeze(Object.keys(centralActionLabels));
export function validCentralDenials(x){return Array.isArray(x)&&x.length<=centralActionKeys.length&&new Set(x).size===x.length&&x.every(k=>centralActionKeys.includes(k))}
const reasons={allowed:'متاحة',role:'خارج الدور أو الفرع',grant:'تحتاج منحة صريحة',license:'الترخيص غير نشط',denied:'ممنوعة',dependency:'صلاحية مرتبطة ممنوعة',inactive:'الحساب موقوف',central:'قيد مركزي للباقة'};
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
