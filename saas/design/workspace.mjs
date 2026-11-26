// Presentation only. RPC authorization and RLS remain authoritative.
export const labels=Object.freeze({"overview":"نظرة عامة","shops":"المحلات","plans":"الاشتراكات والأسعار","infra":"البنية والتوزيع","billing":"الفوترة","recovery":"النسخ والتحديثات","account":"حساب المدير","sales":"المبيعات","inventory":"المخزون","customers":"العملاء والديون","returns":"المرتجعات","purchases":"المشتريات والموردون","repairs":"الصيانة والضمان","finance":"المحاسبة والتقارير","online":"المتجر والطلبات","staff":"الموظفون","settings":"الإعدادات والاشتراك"});
export const adminGroups=Object.freeze(["overview","shops","plans","infra","billing","recovery","account"]);
const roles=Object.freeze({"owner":["sales","inventory","customers","returns","purchases","repairs","finance","online","staff","settings"],"cashier":["sales"],"stock":["inventory"],"tech":["repairs"]});
export function tenantGroups(role){return Object.freeze([...(Object.hasOwn(roles,role)?roles[role]:[])]);}
const operations=Object.freeze({"حالة الاشتراك":"settings","الموردون":"purchases","المشتريات والمستحقات":"purchases","مرتجعات الموردين":"purchases","فواتير المشتريات متعددة المنتجات":"purchases","الموظفون":"staff","تقرير التدفقات النقدية حسب العملة":"finance","الصيانة":"repairs","فواتير الصيانة والضمان":"repairs","طلبات الضمان":"repairs","قطع الغيار ضمن الضمان":"repairs","تسويات فواتير الصيانة":"repairs","أسعار الصرف التاريخية":"finance","الدفع النقدي المختلط للسلة الحالية":"sales","المتجر الإلكتروني والطلبات":"online","الكوبونات والولاء":"online","طلبات العملاء":"online","ميزان المراجعة التشغيلي — القيد المزدوج":"finance","تصنيف القيود والتسويات الضريبية":"finance","الضرائب الموثقة على المبيعات والصيانة":"finance","الميزانية والنتيجة التشغيلية بالعملة المختارة":"finance","إغلاق الفترات المحاسبية التشغيلية":"finance","تقرير الإيرادات والتكلفة التاريخية":"finance"});
export function operationGroup(title){if(!Object.hasOwn(operations,title))throw Error('Unmapped operation section: '+title);return operations[title];}
export function matchesGroup(value,group){return typeof value==='string'&&value.split(/\s+/).includes(group);}
export function createWorkspace(root,nav){
 let allowed=[],active=null;
 const panels=()=>[...root.querySelectorAll('[data-workspace-group]')];
 function render(){
  const available=allowed.filter(k=>panels().some(p=>!p.hidden&&!p.closest('[hidden]:not(#dashboard)')&&matchesGroup(p.dataset.workspaceGroup,k)));
  if(!available.includes(active))active=available[0]||null;
  root.dataset.workspaceActive=active||'';
  for(const panel of panels())panel.toggleAttribute('data-workspace-inactive',!matchesGroup(panel.dataset.workspaceGroup,active));
  for(const container of root.querySelectorAll('[data-workspace-container]')){
   const visible=[...container.querySelectorAll('[data-workspace-group]')].some(p=>!p.hidden&&matchesGroup(p.dataset.workspaceGroup,active));
   container.toggleAttribute('data-workspace-inactive',!visible);
  }
  nav.replaceChildren(...available.map(key=>{const b=nav.ownerDocument.createElement('button');b.type='button';b.textContent=labels[key];b.setAttribute('aria-pressed',String(active===key));b.onclick=()=>select(key);return b;}));
  nav.hidden=!available.length;
 }
 function select(key){if(allowed.includes(key)){active=key;render();}}
 function sync(keys){allowed=[...keys].filter(key=>Object.hasOwn(labels,key));render();}
 function reset(){allowed=[];active=null;render();}
 return {select,sync,reset};
}
