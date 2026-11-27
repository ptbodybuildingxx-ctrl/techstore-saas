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
 const auroraPaths={home:'<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',shop:'<path d="M3 9l2-5h14l2 5v3a3 3 0 0 1-6 0 3 3 0 0 1-6 0 3 3 0 0 1-6 0zM5 15v6h14v-6M10 21v-5h4v5"/>',cart:'<path d="M2 4h3l3 12h11l3-9H6"/><circle cx="9" cy="20" r="1"/><circle cx="18" cy="20" r="1"/>',account:'<circle cx="12" cy="8" r="4"/><path d="M4 21v-2a8 8 0 0 1 16 0v2"/>',advisor:'<path d="m12 2 2.6 6.4L21 11l-6.4 2.6L12 20l-2.6-6.4L3 11l6.4-2.6zM20 2v4m-2-2h4"/>',orders:'<path d="M7 3h10l3 3v15H4V3zM8 9h8M8 13h8M8 17h5"/>',suppliers:'<path d="M3 6h11v13H3zM14 10h4l3 4v5h-7"/><circle cx="7" cy="19" r="2"/><circle cx="18" cy="19" r="2"/>',purchases:'<path d="M3 8l9-5 9 5v11l-9 3-9-3zM3 8l9 4 9-4M12 12v10"/>',debts:'<rect x="3" y="5" width="18" height="14" rx="3"/><path d="M3 10h18M7 15h4"/>',installments:'<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M7 3v4m10-4v4M3 10h18m-13 5h3m3 0h3"/>',inventory:'<path d="M3 5v14m4-14v14m3-14v14m4-14v14m3-14v14m4-14v14"/>',used:'<path d="M20 7H6l4-4M4 17h14l-4 4M6 7l-3 3m15 7 3-3"/>',returns:'<path d="M9 5 3 11l6 6M3 11h11a6 6 0 0 1 6 6v3"/>',repairs:'<path d="m14 6 4-4 4 4-4 4-3-1-9 12-3-3 10-10z"/>',offers:'<path d="M3 3h8l10 10-8 8L3 11z"/><circle cx="7" cy="7" r="1.5"/>',coupons:'<path d="M3 6h18v4a2 2 0 1 0 0 4v4H3v-4a2 2 0 1 0 0-4zM12 7v2m0 2v2m0 2v2"/>',media:'<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8" cy="8" r="2"/><path d="m3 18 6-6 4 4 4-5 4 5"/>',builder:'<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 8h18m-12 0v13"/>',versions:'<path d="M3 12a9 9 0 1 0 3-7L3 8m0-5v5h5M12 7v5l4 2"/>',users:'<circle cx="9" cy="8" r="3"/><path d="M3 21v-3a6 6 0 0 1 12 0v3m2-16a3 3 0 0 1 0 6m1 4a5 5 0 0 1 3 5"/>',report:'<path d="M3 3v18h18M7 17v-5m5 5V8m5 9V5"/>',audit:'<rect x="5" y="3" width="14" height="18" rx="2"/><path d="m8 12 3 3 5-6"/>',pos:'<rect x="3" y="5" width="18" height="11" rx="2"/><path d="M7 20h10m-5-4v4M7 9h10"/>',warranty:'<path d="m12 2 9 4v6c0 5-9 10-9 10S3 17 3 12V6zM8 12l3 3 5-6"/>',signin:'<path d="M13 3h7v18h-7M3 12h12m-4-4 4 4-4 4"/>'};
 const icons=Object.freeze({overview:'home',shops:'shop',plans:'offers',infra:'builder',billing:'debts',recovery:'versions',account:'account',sales:'pos',inventory:'inventory',customers:'users',returns:'returns',purchases:'purchases',repairs:'repairs',finance:'report',online:'shop',staff:'users',settings:'audit'});
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
 doc.addEventListener('keydown',e=>{if(!drawerOpen)return;if(e.key==='Escape'){e.preventDefault();drawer(false,true);return}if(e.key!=='Tab')return;const targets=[...nav.querySelectorAll('button:not([disabled]),input:not([disabled])')].filter(n=>!n.hidden&&!n.closest('[hidden]'));if(!targets.length)return;const first=targets[0],last=targets.at(-1);if(e.shiftKey&&(doc.activeElement===first||!nav.contains(doc.activeElement))){e.preventDefault();last.focus()}else if(!e.shiftKey&&(doc.activeElement===last||!nav.contains(doc.activeElement))){e.preventDefault();first.focus()}});
 function item(key,compact=false){
  const b=make('button',compact?'workspace-quick-item':'workspace-nav-item');b.type='button';
  const icon=make('span','workspace-icon');icon.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round">'+(auroraPaths[icons[key]]||auroraPaths.orders)+'</svg>';icon.setAttribute('aria-hidden','true');
  const label=make('span','workspace-item-label');label.textContent=tr(labels[key]);b.append(icon,label);b.setAttribute('aria-pressed',String(active===key));if(active===key)b.setAttribute('aria-current','page');
  b.onclick=()=>{const wasOpen=drawerOpen;select(key);if(wasOpen)menuButton.focus()};return b;
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
  const buttons=available.map(key=>item(key));
  const filter=()=>{query=search.value;for(const [i,b] of buttons.entries())b.hidden=![labels[available[i]],tr(labels[available[i]])].some(label=>label.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()))};search.oninput=filter;nav.replaceChildren(heading,search,...buttons);filter();
  if(active){const section=active,language=currentLanguage(),guide=make('details','workspace-guide'),summary=make('summary',''),output=make('p',''),ask=make('button','workspace-guide-action');summary.textContent=tr('مساعد القسم');output.textContent=workspaceGuide(section,language);output.setAttribute('role','status');ask.type='button';ask.textContent=tr('شرح محلي ذكي');guide.append(summary,output,ask);nav.append(guide);ask.onclick=async()=>{if(ask.disabled)return;const generation=guideEpoch,controller=new AbortController();guideAbort=controller;ask.disabled=true;const signal=AbortSignal.any([controller.signal,AbortSignal.timeout(20000)]);try{const result=await explainWorkspaceLocally(section,{language,signal});if(generation!==guideEpoch||!guide.isConnected)return;output.textContent=result.text+(result.generated?' — '+tr('شرح توليدي؛ راجع البيانات الأصلية.'): ' — '+tr('النموذج المحلي غير متاح؛ إرشاد ثابت.'));}catch{if(generation===guideEpoch&&guide.isConnected)output.textContent=workspaceGuide(section,language)+' — '+tr('النموذج المحلي غير متاح؛ إرشاد ثابت.')}finally{if(generation===guideEpoch){ask.disabled=false;guideAbort=null}}}}
  menuButton.textContent='☰ '+tr('الأقسام');activeLabel.textContent=active?tr(labels[active]):'';backdrop.setAttribute('aria-label',tr('إغلاق القائمة'));quick.setAttribute('aria-label',tr('التنقل السريع'));
  const preferred=allowed.includes('sales')?['sales','inventory','finance','online']:['overview','shops','plans','recovery'];const first=[...new Set([...preferred.filter(k=>available.includes(k)),...available])].slice(0,4);quick.replaceChildren(...first.map(k=>item(k,true)));
  if(available.length>4){const more=make('button','workspace-quick-item');more.type='button';more.textContent='☰ '+tr('المزيد');more.onclick=()=>drawer(true,true);quick.append(more)}
  nav.hidden=bar.hidden=quick.hidden=!available.length;drawer(drawerOpen);
 }
 function select(key){if(allowed.includes(key)){active=key;drawerOpen=false;render();}}
 function sync(keys){allowed=[...keys].filter(key=>Object.hasOwn(labels,key));render();}
 function reset(){allowed=[];active=null;query='';drawerOpen=false;render();}
 doc.addEventListener('techstore-languagechange',render);
 return {select,sync,reset};
}
