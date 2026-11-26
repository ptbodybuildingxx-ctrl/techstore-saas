import {tr,currentLanguage} from './i18n.mjs';
import {workspaceGuide,explainWorkspaceLocally} from './generative-assistant.mjs';
// Presentation only. RPC authorization and RLS remain authoritative.
export const labels=Object.freeze({"overview":"نظرة عامة","shops":"المحلات","plans":"الاشتراكات والأسعار","infra":"البنية والتوزيع","billing":"الفوترة","recovery":"النسخ والتحديثات","account":"حساب المدير","sales":"المبيعات","inventory":"المخزون","customers":"العملاء والديون","returns":"المرتجعات","purchases":"المشتريات والموردون","repairs":"الصيانة والضمان","finance":"المحاسبة والتقارير","online":"المتجر والطلبات","staff":"الموظفون","settings":"الإعدادات والاشتراك"});
export const adminGroups=Object.freeze(["overview","shops","plans","infra","billing","recovery","account"]);
const roles=Object.freeze({"owner":["sales","inventory","customers","returns","purchases","repairs","finance","online","staff","settings"],"cashier":["sales"],"stock":["inventory"],"tech":["repairs"]});
export function tenantGroups(role,procurement=false){return Object.freeze([...(Object.hasOwn(roles,role)?roles[role]:[]),...(role==='stock'&&procurement?['purchases']:[])]);}
const operations=Object.freeze({"حالة الاشتراك":"settings","الموردون":"purchases","المشتريات والمستحقات":"purchases","مرتجعات الموردين":"purchases","فواتير المشتريات متعددة المنتجات":"purchases","الموظفون":"staff","الرواتب والعمولات وسندات القبض والصرف":"finance","تقرير التدفقات النقدية حسب العملة":"finance","الصيانة":"repairs","فواتير الصيانة والضمان":"repairs","طلبات الضمان":"repairs","قطع الغيار ضمن الضمان":"repairs","تسويات فواتير الصيانة":"repairs","أسعار الصرف التاريخية":"finance","الدفع النقدي المختلط للسلة الحالية":"sales","المتجر الإلكتروني والطلبات":"online","الكوبونات والولاء":"online","مراجعات المنتجات":"online","الحملات التسويقية":"online","تقييم واستبدال الأجهزة":"sales","طلبات العملاء":"online","ميزان المراجعة التشغيلي — القيد المزدوج":"finance","تصنيف القيود والتسويات الضريبية":"finance","الضرائب الموثقة على المبيعات والصيانة":"finance","الميزانية والنتيجة التشغيلية بالعملة المختارة":"finance","إغلاق الفترات المحاسبية التشغيلية":"finance","تقرير الإيرادات والتكلفة التاريخية":"finance"});
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
 const icons={overview:'⌂',shops:'▦',plans:'◈',infra:'⚙',billing:'▤',recovery:'↻',account:'●',sales:'▣',inventory:'▦',customers:'♙',returns:'↶',purchases:'▧',repairs:'⚒',finance:'▥',online:'◎',staff:'♟',settings:'⚙'};
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
  const icon=make('span','workspace-icon');icon.textContent=icons[key]||'•';icon.setAttribute('aria-hidden','true');
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
