import {tr} from './i18n.mjs';
// Presentation only. RPC authorization and RLS remain authoritative.
export const labels=Object.freeze({"overview":"نظرة عامة","shops":"المحلات","plans":"الاشتراكات والأسعار","infra":"البنية والتوزيع","billing":"الفوترة","recovery":"النسخ والتحديثات","account":"حساب المدير","sales":"المبيعات","inventory":"المخزون","customers":"العملاء والديون","returns":"المرتجعات","purchases":"المشتريات والموردون","repairs":"الصيانة والضمان","finance":"المحاسبة والتقارير","online":"المتجر والطلبات","staff":"الموظفون","settings":"الإعدادات والاشتراك"});
export const adminGroups=Object.freeze(["overview","shops","plans","infra","billing","recovery","account"]);
const roles=Object.freeze({"owner":["sales","inventory","customers","returns","purchases","repairs","finance","online","staff","settings"],"cashier":["sales"],"stock":["inventory"],"tech":["repairs"]});
export function tenantGroups(role){return Object.freeze([...(Object.hasOwn(roles,role)?roles[role]:[])]);}
const operations=Object.freeze({"حالة الاشتراك":"settings","الموردون":"purchases","المشتريات والمستحقات":"purchases","مرتجعات الموردين":"purchases","فواتير المشتريات متعددة المنتجات":"purchases","الموظفون":"staff","الرواتب والعمولات وسندات القبض والصرف":"finance","تقرير التدفقات النقدية حسب العملة":"finance","الصيانة":"repairs","فواتير الصيانة والضمان":"repairs","طلبات الضمان":"repairs","قطع الغيار ضمن الضمان":"repairs","تسويات فواتير الصيانة":"repairs","أسعار الصرف التاريخية":"finance","الدفع النقدي المختلط للسلة الحالية":"sales","المتجر الإلكتروني والطلبات":"online","الكوبونات والولاء":"online","مراجعات المنتجات":"online","الحملات التسويقية":"online","تقييم واستبدال الأجهزة":"sales","طلبات العملاء":"online","ميزان المراجعة التشغيلي — القيد المزدوج":"finance","تصنيف القيود والتسويات الضريبية":"finance","الضرائب الموثقة على المبيعات والصيانة":"finance","الميزانية والنتيجة التشغيلية بالعملة المختارة":"finance","إغلاق الفترات المحاسبية التشغيلية":"finance","تقرير الإيرادات والتكلفة التاريخية":"finance"});
export function operationGroup(title){if(!Object.hasOwn(operations,title))throw Error('Unmapped operation section: '+title);return operations[title];}
export function matchesGroup(value,group){return typeof value==='string'&&value.split(/\s+/).includes(group);}
export function createWorkspace(root,nav){
 let allowed=[],active=null,query='',available=[],drawerOpen=false,returnFocus=null;
 const doc=nav.ownerDocument,mobile=doc.defaultView.matchMedia('(max-width: 850px)');
 const make=(tag,cls)=>{const n=doc.createElement(tag);n.className=cls;return n};
 const bar=make('div','workspace-mobile-bar'),menuButton=make('button','workspace-menu-toggle'),activeLabel=make('strong','workspace-active-label'),backdrop=make('button','workspace-backdrop'),quick=make('nav','workspace-quick-nav');
 menuButton.type=backdrop.type='button';menuButton.setAttribute('aria-controls',nav.id);bar.append(menuButton,activeLabel);nav.before(bar,backdrop);root.after(quick);
 const icons={overview:'⌂',shops:'▦',plans:'◈',infra:'⚙',billing:'▤',recovery:'↻',account:'●',sales:'▣',inventory:'▦',customers:'♙',returns:'↶',purchases:'▧',repairs:'⚒',finance:'▥',online:'◎',staff:'♟',settings:'⚙'};
 const panels=()=>[...root.querySelectorAll('[data-workspace-group]')];
 function drawer(open,focus=false){
  drawerOpen=!!open&&mobile.matches&&available.length>0;
  nav.dataset.drawerOpen=String(drawerOpen);nav.inert=mobile.matches&&!drawerOpen;
  root.inert=drawerOpen;quick.inert=drawerOpen;bar.inert=drawerOpen;
  if(drawerOpen)nav.setAttribute('aria-label',tr('الأقسام'));else nav.removeAttribute('aria-label');
  menuButton.setAttribute('aria-expanded',String(drawerOpen));backdrop.hidden=!drawerOpen;
  if(focus){if(drawerOpen){returnFocus=doc.activeElement;nav.querySelector('input')?.focus()}else{const target=returnFocus?.isConnected&&!returnFocus.closest('[inert]')?returnFocus:menuButton;returnFocus=null;target.focus()}}
 }
 menuButton.onclick=()=>drawer(!drawerOpen,true);backdrop.onclick=()=>drawer(false,true);
 mobile.addEventListener('change',()=>drawer(false));
 doc.addEventListener('keydown',e=>{if(!drawerOpen)return;if(e.key==='Escape'){e.preventDefault();drawer(false,true);return}if(e.key!=='Tab')return;const targets=[...nav.querySelectorAll('button:not([disabled]),input:not([disabled])')].filter(n=>!n.hidden&&!n.closest('[hidden]'));if(!targets.length)return;const first=targets[0],last=targets.at(-1);if(e.shiftKey&&(doc.activeElement===first||!nav.contains(doc.activeElement))){e.preventDefault();last.focus()}else if(!e.shiftKey&&(doc.activeElement===last||!nav.contains(doc.activeElement))){e.preventDefault();first.focus()}});
 function item(key,compact=false){
  const b=make('button',compact?'workspace-quick-item':'workspace-nav-item');b.type='button';
  const icon=make('span','workspace-icon');icon.textContent=icons[key]||'•';icon.setAttribute('aria-hidden','true');
  const label=make('span','workspace-item-label');label.textContent=tr(labels[key]);b.append(icon,label);b.setAttribute('aria-pressed',String(active===key));if(active===key)b.setAttribute('aria-current','page');
  b.onclick=()=>{const wasOpen=drawerOpen;select(key);if(wasOpen)menuButton.focus()};return b;
 }
 function render(){
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
  menuButton.textContent='☰ '+tr('الأقسام');activeLabel.textContent=active?tr(labels[active]):'';backdrop.setAttribute('aria-label',tr('إغلاق القائمة'));quick.setAttribute('aria-label',tr('التنقل السريع'));
  const first=available.slice(0,4);quick.replaceChildren(...first.map(k=>item(k,true)));
  if(available.length>4){const more=make('button','workspace-quick-item');more.type='button';more.textContent='☰ '+tr('المزيد');more.onclick=()=>drawer(true,true);quick.append(more)}
  nav.hidden=bar.hidden=quick.hidden=!available.length;drawer(drawerOpen);
 }
 function select(key){if(allowed.includes(key)){active=key;drawerOpen=false;render();}}
 function sync(keys){allowed=[...keys].filter(key=>Object.hasOwn(labels,key));render();}
 function reset(){allowed=[];active=null;query='';drawerOpen=false;render();}
 doc.addEventListener('techstore-languagechange',render);
 return {select,sync,reset};
}
