// Native, already-installed browser model only. No cloud fallback, download or user data.
const kinds=new Set(['cpu','board','ram','gpu','storage','psu','case','socket','form','power']);
const options=language=>{if(!['ar','en'].includes(language))throw Error('Unsupported language');return {expectedInputs:[{type:'text',languages:[language]}],expectedOutputs:[{type:'text',languages:[language]}]}};
export async function localModelReady(model=globalThis.LanguageModel,language='en'){
 if(typeof model?.availability!=='function'||typeof model?.create!=='function')return false;
 try{return await model.availability(options(language))==='available'}catch{return false}
}
export async function explainBuildLocally(checks,{model=globalThis.LanguageModel,language='en',signal=AbortSignal.timeout(20000)}={}){
 if(!checks||!['warnings','unknown','missing'].every(k=>Array.isArray(checks[k])&&checks[k].length<=24))throw Error('Invalid build check');
 // Only allowlisted component/check identifiers, no names, descriptions, identifiers, amounts or user questions.
 const clean=x=>typeof x==='string'&&kinds.has(x)?x:'other';
 const facts=Object.fromEntries(['warnings','unknown','missing'].map(k=>[k,checks[k].map(clean)]));
 if(!await localModelReady(model,language))return null;
 signal.throwIfAborted();
 let session;
 try{
  session=await model.create({...options(language),signal,initialPrompts:[{role:'system',content:language==='ar'?'اشرح نتائج فحوص توافق الحاسوب المحدودة بالعربية في أقل من 100 كلمة. لا تخترع منتجات أو أسعاراً أو تدّعي التوافق الكامل. يجب التحقق من مواصفات الشركة المصنعة.':'Explain these deterministic PC compatibility checks in English in at most 100 words. Do not invent products or prices or claim full compatibility. Manufacturer verification is required.'}]});
  const result=await session.prompt((language==='ar'?'اشرح نتائج الفحوص التالية: ':'Explain these check results: ')+JSON.stringify(facts),{signal});
  if(typeof result!=='string'||!result.trim())return null;
  return result.trim().slice(0,1200);
 }finally{session?.destroy()}
}

const guides=Object.freeze({
 overview:['راجع مؤشرات التشغيل والتنبيهات والحالة قبل اتخاذ قرار.','Review operational indicators, alerts and status before making a decision.'],
 shops:['راجع المحل المخصص والمالك وحالة الترخيص قبل أي تغيير.','Review the selected shop, owner and license before changing anything.'],
 plans:['راجع الاستحقاقات والأسعار؛ لا تفعل خدمة مدفوعة دون اعتماد.','Review entitlements and pricing; do not enable paid services without approval.'],
 infra:['راجع حالة التوزيع والاتصال؛ لا تنقل بيانات حية دون خطة استعادة.','Review infrastructure and connectivity; do not move live data without a recovery plan.'],
 billing:['راجع الفوترة وحالة الدفع؛ لا تعتبر الدفعة مؤكدة قبل اعتماد الخادم.','Review billing and payment status; do not treat a payment as confirmed before server verification.'],
 recovery:['راجع سجل النسخ، تحقق من التشفير واختبر الاستعادة المعزولة قبل النشر.','Review backups, verify encryption and test isolated restoration before release.'],
 account:['راجع الأجهزة والمصادقة الثنائية؛ لا تشارك رموز التحقق أو كلمات المرور.','Review devices and two-factor authentication; never share verification codes or passwords.'],
 sales:['اختر الفرع والعملة، راجع الكميات والأسعار ثم أكد الدفع الفعلي.','Select branch and currency, review quantities and prices, then confirm actual payment.'],
 inventory:['راجع موقع المخزون والكميات والتكلفة؛ سجل حركة موثقة لا حذفاً للرصيد.','Review stock location, quantities and cost; record a documented movement rather than deleting balances.'],
 customers:['راجع هوية العميل والذمم قبل تأكيد تسوية أو دفعة.','Review customer identity and receivables before confirming a settlement or payment.'],
 returns:['اربط المرتجع بالفاتورة الأصلية وراجع الكمية والمبلغ قبل التأكيد.','Link the return to the original invoice and review quantity and amount before confirmation.'],
 purchases:['اختر المورد والفرع والعملة وراجع تكلفة الشراء والمدفوع والمتبقي.','Select supplier, branch and currency; review purchase cost, amount paid and balance.'],
 repairs:['اربط العميل بالطلب، وثق موافقته، وراجع التكلفة والمهام قبل التسليم.','Link the customer to the ticket, document approval, and review cost and tasks before delivery.'],
 finance:['راجع الفترة والعملة وتطابق القيود؛ لا تعتمد ربحاً نهائياً من أرصدة غير مدققة.','Review reporting period, currency and journal reconciliation; do not certify profit from unaudited balances.'],
 online:['راجع المنتجات المنشورة والأسعار والطلبات قبل تأكيد التنفيذ.','Review published products, prices and orders before confirming fulfillment.'],
 staff:['راجع دور الموظف وفرعه ومستحقاته وصلاحياته قبل اعتماد التسوية.','Review employee role, branch, entitlements and permissions before confirming a settlement.'],
 settings:['راجع الاشتراك وإعدادات المحل؛ تحقق من أثر التعديل قبل الحفظ.','Review subscription and shop settings; verify the effect before saving.']
});
export function workspaceGuide(section,language='ar'){
 if(!Object.hasOwn(guides,section)||!['ar','en'].includes(language))throw Error('Invalid guide');
 return guides[section][language==='ar'?0:1];
}
export async function explainWorkspaceLocally(section,{language='ar',model=globalThis.LanguageModel,signal=AbortSignal.timeout(20000)}={}){
 const fact=workspaceGuide(section,language);
 if(!await localModelReady(model,language))return {text:fact,generated:false};
 signal.throwIfAborted();
 let session;
 try{
  session=await model.create({...options(language),signal,initialPrompts:[{role:'system',content:language==='ar'?'اشرح الإرشاد المقدم فقط بالعربية في ثلاث خطوات قصيرة. لا تخترع وظائف أو بيانات أو صلاحيات ولا تنفذ عمليات.':'Explain only the supplied workflow guidance in three short English steps. Do not invent features, data or permissions or execute actions.'}]});
  const result=await session.prompt(fact,{signal});
  return typeof result==='string'&&result.trim()?{text:result.trim().slice(0,1200),generated:true}:{text:fact,generated:false};
 }finally{session?.destroy()}
}
