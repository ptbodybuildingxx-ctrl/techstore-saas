import {tr,currentLanguage} from './i18n.mjs';
import {workspaceGuide,explainWorkspaceLocally} from './generative-assistant.mjs';
// Presentation only. RPC authorization and RLS remain authoritative.
export const labels=Object.freeze({"overview":"نظرة عامة","shops":"المحلات","plans":"الاشتراكات والأسعار","infra":"البنية والتوزيع","billing":"الفوترة","recovery":"النسخ والتحديثات","account":"حساب المدير","sales":"المبيعات","inventory":"المخزون","customers":"العملاء والديون","returns":"المرتجعات","purchases":"المشتريات والموردون","repairs":"الصيانة والضمان","finance":"المحاسبة والتقارير","online":"المتجر والطلبات","staff":"الموظفون","settings":"الإعدادات والاشتراك"});
export const adminGroups=Object.freeze(["overview","shops","plans","infra","billing","recovery","account"]);
const roles=Object.freeze({"owner":["sales","inventory","customers","returns","purchases","repairs","finance","online","staff","settings"],"cashier":["sales"],"stock":["inventory"],"tech":["repairs"]});
export function tenantGroups(role,procurement=false,receivables=false){return Object.freeze([...(Object.hasOwn(roles,role)?roles[role]:[]),...(role==='stock'&&procurement?['purchases']:[]),...(role==='cashier'&&receivables?['customers']:[])]);}
const operations=Object.freeze({"حالة الاشتراك":"settings","الموردون":"purchases","المشتريات والمستحقات":"purchases","مرتجعات الموردين":"purchases","فواتير المشتريات متعددة المنتجات":"purchases","الموظفون":"staff","الرواتب والعمولات وسندات القبض والصرف":"finance","تقرير التدفقات النقدية حسب العملة":"finance","الصيانة":"repairs","فواتير الصيانة والضمان":"repairs","مطالبات كفالة المنتجات":"sales","طلبات الضمان":"repairs","قطع الغيار ضمن الضمان":"repairs","تسويات فواتير الصيانة":"repairs","أسعار الصرف التاريخية":"finance","الدفع النقدي المختلط للسلة الحالية":"sales","المتجر الإلكتروني والطلبات":"online","الكوبونات والولاء":"online","مراجعات المنتجات":"online","الحملات التسويقية":"online","تقييم واستبدال الأجهزة":"sales","طلبات العملاء":"online","ميزان المراجعة التشغيلي — القيد المزدوج":"finance","تصنيف القيود والتسويات الضريبية":"finance","الضرائب الموثقة على المبيعات والصيانة":"finance","الميزانية والنتيجة التشغيلية بالعملة المختارة":"finance","إغلاق الفترات المحاسبية التشغيلية":"finance","تقرير الإيرادات والتكلفة التاريخية":"finance"});
export function operationGroup(title){if(!Object.hasOwn(operations,title))throw Error('Unmapped operation section: '+title);return operations[title];}
export function matchesGroup(value,group){return typeof value==='string'&&value.split(/\s+/).includes(group);}
export function effectiveWorkspaceLayout(mode,narrow){return mode==='mobile'||mode!=='desktop'&&narrow?'mobile':'desktop'}
// SVG geometry from the original TechStore Aurora navigation; constructed as DOM nodes.
const auroraIcons=Object.freeze({"overview":[["rect",{"x":"3","y":"3","width":"7","height":"7","rx":"1.5"}],["rect",{"x":"14","y":"3","width":"7","height":"7","rx":"1.5"}],["rect",{"x":"3","y":"14","width":"7","height":"7","rx":"1.5"}],["rect",{"x":"14","y":"14","width":"7","height":"7","rx":"1.5"}]],"shops":[["path",{"d":"M3 9l2-5h14l2 5v3a3 3 0 0 1-6 0 3 3 0 0 1-6 0 3 3 0 0 1-6 0zM5 15v6h14v-6M10 21v-5h4v5"}]],"plans":[["path",{"d":"M3 3h8l10 10-8 8L3 11z"}],["circle",{"cx":"7","cy":"7","r":"1.5"}]],"infra":[["rect",{"x":"3","y":"3","width":"18","height":"18","rx":"2"}],["path",{"d":"M3 8h18m-12 0v13"}]],"billing":[["rect",{"x":"3","y":"5","width":"18","height":"14","rx":"3"}],["path",{"d":"M3 10h18M7 15h4"}]],"recovery":[["path",{"d":"M3 12a9 9 0 1 0 3-7L3 8m0-5v5h5M12 7v5l4 2"}]],"account":[["circle",{"cx":"12","cy":"8","r":"4"}],["path",{"d":"M4 21v-2a8 8 0 0 1 16 0v2"}]],"sales":[["rect",{"x":"3","y":"5","width":"18","height":"11","rx":"2"}],["path",{"d":"M7 20h10m-5-4v4M7 9h10"}]],"inventory":[["path",{"d":"M3 5v14m4-14v14m3-14v14m4-14v14m3-14v14m4-14v14"}]],"customers":[["circle",{"cx":"9","cy":"8","r":"3"}],["path",{"d":"M3 21v-3a6 6 0 0 1 12 0v3m2-16a3 3 0 0 1 0 6m1 4a5 5 0 0 1 3 5"}]],"returns":[["path",{"d":"M9 5 3 11l6 6M3 11h11a6 6 0 0 1 6 6v3"}]],"purchases":[["path",{"d":"M3 8l9-5 9 5v11l-9 3-9-3zM3 8l9 4 9-4M12 12v10"}]],"repairs":[["path",{"d":"m14 6 4-4 4 4-4 4-3-1-9 12-3-3 10-10z"}]],"finance":[["path",{"d":"M3 3v18h18M7 17v-5m5 5V8m5 9V5"}]],"online":[["path",{"d":"M3 9l2-5h14l2 5v3a3 3 0 0 1-6 0 3 3 0 0 1-6 0 3 3 0 0 1-6 0zM5 15v6h14v-6M10 21v-5h4v5"}]],"staff":[["circle",{"cx":"9","cy":"8","r":"3"}],["path",{"d":"M3 21v-3a6 6 0 0 1 12 0v3m2-16a3 3 0 0 1 0 6m1 4a5 5 0 0 1 3 5"}]],"settings":[["rect",{"x":"5","y":"3","width":"14","height":"18","rx":"2"}],["path",{"d":"m8 12 3 3 5-6"}]]});
const navGroups=Object.freeze([
 ['نظرة عامة',['overview']],
 ['إدارة المنصة',['shops','plans','billing']],
 ['البنية والتوزيع',['infra','recovery']],
 ['المبيعات والعملاء',['sales','customers']],
 ['المخزون والمشتريات',['inventory','purchases','returns']],
 ['الإدارة المالية',['finance']],
 ['الصيانة',['repairs']],
 ['المتجر والتسويق',['online']],
 ['الحساب والأمان',['staff','settings','account']]
]);
function workspaceIcon(doc,key){
 const wrapper=doc.createElement('span');wrapper.className='workspace-icon';wrapper.setAttribute('aria-hidden','true');
 const ns='http://www.w3.org/2000/svg',svg=doc.createElementNS(ns,'svg');
 for(const [k,v] of Object.entries({viewBox:'0 0 24 24',fill:'none',stroke:'currentColor','stroke-width':'1.65','stroke-linecap':'round','stroke-linejoin':'round',focusable:'false'}))svg.setAttribute(k,v);
 for(const [tag,attrs] of auroraIcons[key]||auroraIcons.overview){const shape=doc.createElementNS(ns,tag);for(const [k,v] of Object.entries(attrs))shape.setAttribute(k,v);svg.append(shape)}
 wrapper.append(svg);return wrapper
}
export function createWorkspace(root,nav){
 let allowed=[],active=null,query='',available=[],drawerOpen=false,returnFocus=null,guideEpoch=0,guideAbort=null;
 const doc=nav.ownerDocument,mobile=doc.defaultView.matchMedia('(max-width: 860px)');
 let mode='auto';try{const saved=doc.defaultView.localStorage.getItem('techstore-workspace-layout');if(['auto','desktop','mobile'].includes(saved))mode=saved}catch{}
 const isMobile=()=>effectiveWorkspaceLayout(mode,mobile.matches)==='mobile';
 const make=(tag,cls)=>{const n=doc.createElement(tag);n.className=cls;return n};
 const bar=make('div','workspace-mobile-bar'),menuButton=make('button','workspace-menu-toggle'),activeLabel=make('strong','workspace-active-label'),backdrop=make('button','workspace-backdrop'),quick=make('nav','workspace-quick-nav');
 menuButton.type=backdrop.type='button';backdrop.tabIndex=-1;menuButton.setAttribute('aria-controls',nav.id);bar.append(menuButton,activeLabel);nav.before(bar,backdrop);root.after(quick);
 const modeLabel=make('label','workspace-layout-control'),modeText=make('span',''),modeSelect=make('select','workspace-layout-mode');modeLabel.append(modeText,modeSelect);doc.querySelector('header')?.append(modeLabel);
 function applyMode(){doc.documentElement.dataset.workspaceLayout=effectiveWorkspaceLayout(mode,mobile.matches);modeText.textContent=tr('طريقة العرض');modeSelect.replaceChildren(...[['auto','تلقائي'],['desktop','حاسوب'],['mobile','موبايل']].map(([v,t])=>{const n=make('option','');n.value=v;n.textContent=tr(t);return n}));modeSelect.value=mode}
 modeSelect.onchange=()=>{mode=modeSelect.value;if(!['auto','desktop','mobile'].includes(mode))mode='auto';try{doc.defaultView.localStorage.setItem('techstore-workspace-layout',mode)}catch{}applyMode();drawer(false)};applyMode();
 // Local display preferences never overwrite a tenant's saved or published theme.
 const win=doc.defaultView,html=doc.documentElement,header=doc.querySelector('header');
 const themeButton=make('button','workspace-theme-toggle');themeButton.type='button';header?.append(themeButton);
 let appearance='light';try{if(win.localStorage.getItem('techstore-workspace-appearance')==='dark')appearance='dark'}catch{}
 const updateAppearance=()=>{const custom=html.dataset.design==='on';html.dataset.workspaceAppearance=appearance;themeButton.hidden=custom;themeButton.setAttribute('aria-pressed',String(appearance==='dark'));themeButton.textContent=appearance==='dark'?'☀ '+tr('الوضع الفاتح'):'☾ '+tr('الوضع الداكن');themeButton.setAttribute('aria-label',tr(appearance==='dark'?'الوضع الفاتح':'الوضع الداكن'))};
 themeButton.onclick=()=>{if(html.dataset.design==='on')return;appearance=appearance==='dark'?'light':'dark';try{win.localStorage.setItem('techstore-workspace-appearance',appearance)}catch{}updateAppearance()};
 const appearanceObserver=new win.MutationObserver(updateAppearance);appearanceObserver.observe(html,{attributes:true,attributeFilter:['data-design']});updateAppearance();
 const connection=make('div','workspace-connection');connection.setAttribute('role','status');connection.setAttribute('aria-live','polite');header?.after(connection);
 const updateConnection=()=>{const online=win.navigator.onLine;connection.dataset.offline=String(!online);connection.textContent=tr(online?'متصل بالإنترنت':'غير متصل — توفر العمليات يعتمد على وضع العمل دون اتصال')};
 win.addEventListener('online',updateConnection);win.addEventListener('offline',updateConnection);updateConnection();
 const pageHead=make('div','workspace-page-head'),pageCaption=make('span','workspace-page-caption'),pageTitle=make('h2','workspace-page-title');pageHead.append(pageCaption,pageTitle);root.prepend(pageHead);
 const panels=()=>[...root.querySelectorAll('[data-workspace-group]')];
 function drawer(open,focus=false){
  const wasOpen=drawerOpen,next=!!open&&isMobile()&&available.length>0;
  if(next&&!wasOpen)returnFocus=doc.activeElement;
  drawerOpen=next;
  nav.dataset.drawerOpen=String(drawerOpen);nav.inert=isMobile()&&!drawerOpen;
  root.inert=drawerOpen;quick.inert=drawerOpen;bar.inert=drawerOpen;
  if(drawerOpen)nav.setAttribute('aria-label',tr('الأقسام'));else nav.removeAttribute('aria-label');
  menuButton.setAttribute('aria-expanded',String(drawerOpen));backdrop.hidden=!drawerOpen;
  if(focus){if(drawerOpen){nav.querySelector('input')?.focus()}else{const target=returnFocus?.isConnected&&!returnFocus.closest('[inert]')?returnFocus:menuButton;returnFocus=null;target.focus()}}
 }
 menuButton.onclick=()=>drawer(!drawerOpen,true);backdrop.onclick=()=>drawer(false,true);
 mobile.addEventListener('change',()=>{applyMode();drawer(false)});
 doc.addEventListener('keydown',e=>{if(!drawerOpen)return;if(e.key==='Escape'){e.preventDefault();drawer(false,true);return}if(e.key!=='Tab')return;const targets=[...nav.querySelectorAll('button:not([disabled]),input:not([disabled]),summary,select:not([disabled])')].filter(n=>!n.hidden&&!n.closest('[hidden]'));if(!targets.length)return;const first=targets[0],last=targets.at(-1);if(e.shiftKey&&(doc.activeElement===first||!nav.contains(doc.activeElement))){e.preventDefault();last.focus()}else if(!e.shiftKey&&(doc.activeElement===last||!nav.contains(doc.activeElement))){e.preventDefault();first.focus()}});
 function item(key,compact=false){
  const b=make('button',compact?'workspace-quick-item':'workspace-nav-item');b.type='button';
  const icon=workspaceIcon(doc,key);
  const label=make('span','workspace-item-label');label.textContent=tr(labels[key]);b.append(icon,label);b.setAttribute('aria-pressed',String(active===key));if(active===key)b.setAttribute('aria-current','page');
  b.onclick=()=>{const wasOpen=drawerOpen;select(key);if(wasOpen)menuButton.focus();else (compact?quick:nav).querySelector('[aria-current=page]')?.focus({preventScroll:true})};return b;
 }
 function render(){
  guideEpoch++;guideAbort?.abort();guideAbort=null;
  applyMode();
  available=allowed.filter(k=>panels().some(p=>!p.hidden&&!p.closest('[hidden]:not(#dashboard)')&&matchesGroup(p.dataset.workspaceGroup,k)));
  if(!available.includes(active))active=available[0]||null;
  root.dataset.workspaceActive=active||'';
  for(const panel of panels())panel.toggleAttribute('data-workspace-inactive',!matchesGroup(panel.dataset.workspaceGroup,active));
  for(const container of root.querySelectorAll('[data-workspace-container]')){
   const visible=[...container.querySelectorAll('[data-workspace-group]')].some(p=>!p.hidden&&matchesGroup(p.dataset.workspaceGroup,active));
   container.toggleAttribute('data-workspace-inactive',!visible);
  }
  const search=make('input','workspace-search');search.type='search';search.placeholder=tr('ابحث في الأقسام');search.setAttribute('aria-label',tr('بحث في الأقسام'));search.value=query;
  const heading=make('div','workspace-drawer-heading'),title=make('strong',''),close=make('button','workspace-drawer-close');
  title.textContent=tr('الأقسام');close.type='button';close.textContent='×';close.setAttribute('aria-label',tr('إغلاق القائمة'));close.onclick=()=>drawer(false,true);heading.append(title,close);
  const searchLabel=make('label','workspace-search-label'),searchTitle=make('span','');searchTitle.textContent=tr('بحث في الأقسام');searchLabel.append(searchTitle,search);search.autocomplete='off';
  const grouped=make('div','workspace-nav-groups'),entries=[];
  for(const [caption,keys] of navGroups){const visible=keys.filter(k=>available.includes(k));if(!visible.length)continue;const section=make('section','workspace-nav-group'),h=make('h2','');h.textContent=tr(caption);section.append(h);const buttons=visible.map(k=>[k,item(k)]);section.append(...buttons.map(x=>x[1]));grouped.append(section);entries.push({section,caption,buttons})}
  const empty=make('p','workspace-search-empty');empty.textContent=tr('لا توجد أقسام مطابقة');
  const filter=()=>{query=search.value;const q=query.trim().toLocaleLowerCase();let total=0;for(const {section,caption,buttons} of entries){let count=0;for(const [k,b] of buttons){b.hidden=!([labels[k],tr(labels[k]),caption,tr(caption)].some(label=>label.toLocaleLowerCase().includes(q)));if(!b.hidden)count++}section.hidden=!count;total+=count}empty.hidden=total>0||!q};
  search.oninput=filter;nav.replaceChildren(heading,searchLabel,grouped,empty);filter();
  pageHead.hidden=!active;pageCaption.textContent=active?tr(navGroups.find(([,keys])=>keys.includes(active))?.[0]||'الأقسام'):'';pageTitle.textContent=active?tr(labels[active]):'';
  updateAppearance();updateConnection();
  if(active){const section=active,language=currentLanguage(),guide=make('details','workspace-guide'),summary=make('summary',''),output=make('p',''),ask=make('button','workspace-guide-action');summary.textContent=tr('مساعد القسم');output.textContent=workspaceGuide(section,language);output.setAttribute('role','status');ask.type='button';ask.textContent=tr('شرح محلي ذكي');guide.append(summary,output,ask);nav.append(guide);ask.onclick=async()=>{if(ask.disabled)return;const generation=guideEpoch,controller=new AbortController();guideAbort=controller;ask.disabled=true;const signal=AbortSignal.any([controller.signal,AbortSignal.timeout(20000)]);try{const result=await explainWorkspaceLocally(section,{language,signal});if(generation!==guideEpoch||!guide.isConnected)return;output.textContent=result.text+(result.generated?' — '+tr('شرح توليدي؛ راجع البيانات الأصلية.'): ' — '+tr('النموذج المحلي غير متاح؛ إرشاد ثابت.'));}catch{if(generation===guideEpoch&&guide.isConnected)output.textContent=workspaceGuide(section,language)+' — '+tr('النموذج المحلي غير متاح؛ إرشاد ثابت.')}finally{if(generation===guideEpoch){ask.disabled=false;guideAbort=null}}}}
  menuButton.textContent='☰ '+tr('الأقسام');activeLabel.textContent=active?tr(labels[active]):'';backdrop.setAttribute('aria-label',tr('إغلاق القائمة'));quick.setAttribute('aria-label',tr('التنقل السريع'));
  const preferred=allowed.includes('sales')?['sales','inventory','finance','online']:['overview','shops','plans','recovery'];const first=[...new Set([...preferred.filter(k=>available.includes(k)),...available])].slice(0,4);quick.replaceChildren(...first.map(k=>item(k,true)));
  if(available.length>4){const more=make('button','workspace-quick-item');more.type='button';more.textContent='☰ '+tr('المزيد');more.onclick=()=>drawer(true,true);quick.append(more)}
  nav.hidden=bar.hidden=quick.hidden=!available.length;drawer(drawerOpen);
 }
 function select(key){if(available.includes(key)){active=key;drawerOpen=false;query='';render();root.ownerDocument.defaultView.scrollTo({top:0,behavior:'instant'});}}
 function sync(keys){allowed=[...keys].filter(key=>Object.hasOwn(labels,key));render();}
 function reset(){allowed=[];active=null;query='';drawerOpen=false;render();}
 doc.addEventListener('techstore-languagechange',render);
 return {select,sync,reset};
}
