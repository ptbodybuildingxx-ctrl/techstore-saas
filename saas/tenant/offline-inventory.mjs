import {sealOfflineVault,openOfflineVault,validateCatalogProfile,validateSpecs} from '../design/theme.mjs';
import {tr} from '../design/i18n.mjs';
const uuid=v=>typeof v==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(v);
const scopeOf=x=>{if(!uuid(x.store)||!uuid(x.actor))throw Error('Invalid inventory scope');return 'inventory:'+x.store+':'+x.actor};
const activeKey=x=>scopeOf(x)+':active';
const dbName='techstore-offline-inventory-v1';
async function db(){return new Promise((resolve,reject)=>{const r=indexedDB.open(dbName,1);r.onupgradeneeded=()=>r.result.createObjectStore('vaults');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);r.onblocked=()=>reject(Error('Close other inventory tabs'))})}
async function access(mode,task){const d=await db();try{return await new Promise((resolve,reject)=>{const tx=d.transaction('vaults',mode),s=tx.objectStore('vaults');let value;const r=task(s);if(r)r.onsuccess=()=>{value=r.result};tx.oncomplete=()=>resolve(value);tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error||Error('Storage aborted'))})}finally{d.close()}}
const get=k=>access('readonly',s=>s.get(k)),put=(k,v)=>access('readwrite',s=>s.put(v,k)),del=k=>access('readwrite',s=>s.delete(k));

async function putChunked(key,value,pass){
 const data=new TextEncoder().encode(JSON.stringify(value)),parts=Math.ceil(data.length/500000);try{
  for(let i=0;i<parts;i++){const k=key+':chunk:'+i;await put(k,await sealOfflineVault({data:b64(data.subarray(i*500000,(i+1)*500000))},pass,k))}
  await put(key,await sealOfflineVault({format:'chunks-v1',parts,bytes:data.length},pass,key));
 }catch(e){try{await purgePrefix(key);await del(key)}catch{}throw e}
}
async function getChunked(key,pass){
 const head=await openOfflineVault(await get(key),pass,key);if(head?.format!=='chunks-v1')return head;
 if(!Number.isSafeInteger(head.parts)||!Number.isSafeInteger(head.bytes)||head.parts!==Math.ceil(head.bytes/500000)||head.bytes<1)throw Error('Invalid encrypted page');
 const data=new Uint8Array(head.bytes);let offset=0;
 for(let i=0;i<head.parts;i++){const k=key+':chunk:'+i,part=await openOfflineVault(await get(k),pass,k),a=atob(part.data);if(a.length>500000||offset+a.length>data.length)throw Error('Invalid page chunk');for(let j=0;j<a.length;j++)data[offset+j]=a.charCodeAt(j);offset+=a.length}
 if(offset!==data.length)throw Error('Incomplete encrypted page');return JSON.parse(new TextDecoder().decode(data))
}

const currencies=['SYP','USD','EUR'],tiers=['standard','member','silver','gold','vip','wholesale'];
function validRow(x){const c=x?.catalog;if(!Array.isArray(x?.originals)||x.originals.length>4||x.originals.some(o=>!uuid(o.id)||typeof o.alt!=='string'||typeof o.published!=='boolean'||typeof o.uploaded!=='boolean')||!uuid(c?.id)||typeof c.name!=='string'||typeof c.sku!=='string'||typeof c.listed!=='boolean'||!/^[a-f0-9]{64}$/.test(x.digest))throw Error('Invalid catalog record');validateCatalogProfile(c.profile);validateSpecs(c.specs);for(const [key,rows] of Object.entries({retail:x.retail,tiers:x.tiers,customers:x.customers,buyers:x.buyers})){if(rows===null&&['customers','buyers'].includes(key))continue;if(!Array.isArray(rows)||rows.some(p=>!currencies.includes(p.currency)||!Number.isSafeInteger(p.price)||p.price<1||p.price>100000000||key!=='retail'&&(!Number.isSafeInteger(p.min)||p.min<1||p.min>100||!(key==='tiers'?tiers.includes(p.subject):uuid(p.subject)))))throw Error('Invalid prices')}return x}
async function withLock(scope,fn){if(!navigator.locks?.request)throw Error('Exclusive storage unavailable');return navigator.locks.request(scope,fn)}
export async function captureOfflineInventory(scope,pass,fetchPage){
 const base=scopeOf(scope);return withLock(base,async()=>{
  const prior=await get(activeKey(scope));if(prior)await openOfflineVault(prior,pass,activeKey(scope));
  const generation=crypto.randomUUID(),prefix=base+':'+generation;let index=[],pages=0,total=0,after=null;const capturedAt=new Date().toISOString();
  const flush=async()=>{if(!index.length)return;await putChunked(prefix+':index:'+pages++,index,pass);index=[]};
  try{
   for(;;){const rows=await fetchPage(after);if(!Array.isArray(rows)||rows.length>5)throw Error('Invalid page');
    for(const raw of rows){const row=validRow(raw),id=row.catalog.id;if(after!==null&&id<=after)throw Error('Catalog cursor changed');after=id;await putChunked(prefix+':'+id,row,pass);index.push({id,name:row.catalog.name,sku:row.catalog.sku});total++;if(index.length>=200)await flush()}
    if(rows.length<5)break;
   }
   await flush();await put(activeKey(scope),await sealOfflineVault({generation,indexPages:pages,total,capturedAt},pass,activeKey(scope)));
  }catch(err){await purgePrefix(prefix).catch(()=>{});throw err}
  if(prior)try{const old=await openOfflineVault(prior,pass,activeKey(scope));await purgePrefix(base+':'+old.generation)}catch{}
  return total;
 });
}
export async function forgetOfflineInventory(scope){const base=scopeOf(scope);return withLock(base,()=>access('readwrite',s=>{const r=s.openCursor();r.onsuccess=()=>{const c=r.result;if(c){if(typeof c.key==='string'&&c.key.startsWith(base+':'))c.delete();c.continue()}}}))}
async function manifest(scope,pass){const raw=await get(activeKey(scope));if(!raw)return null;const m=await openOfflineVault(raw,pass,activeKey(scope));if(!uuid(m.generation)||!Number.isFinite(Date.parse(m.capturedAt)))throw Error('Invalid inventory manifest');if(!Array.isArray(m.ids)){if(!Number.isSafeInteger(m.indexPages)||m.indexPages<0||!Number.isSafeInteger(m.total)||m.total<0)throw Error('Invalid manifest pages');m.ids=[];for(let i=0;i<m.indexPages;i++){const rows=await getChunked(scopeOf(scope)+':'+m.generation+':index:'+i,pass);if(!Array.isArray(rows)||rows.length>200)throw Error('Invalid catalog index');m.ids.push(...rows)}if(m.ids.length!==m.total)throw Error('Incomplete catalog index')}if(m.ids.some(x=>!uuid(x.id)||typeof x.name!=='string'||typeof x.sku!=='string'))throw Error('Invalid inventory index');return m}
async function readItem(scope,pass,m,id){if(!m.ids.some(x=>x.id===id))throw Error('Unknown product');return validRow(await getChunked(scopeOf(scope)+':'+m.generation+':'+id,pass))}
const node=(tag,value)=>{const x=document.createElement(tag);if(value!==undefined)x.textContent=value;return x},button=(label,fn)=>{const b=node('button',tr(label));b.type='button';b.onclick=fn;return b},money=v=>{if(typeof v!=='string'||!/^\d{1,6}(?:\.\d{1,2})?$/.test(v))throw Error('Invalid price');const [a,b='']=v.split('.'),n=Number(a)*100+Number(b.padEnd(2,'0'));if(n<1||n>100000000)throw Error('Invalid price');return n};
function field(root,label,value='',type='text'){const l=node('label',tr(label)),i=node(type==='textarea'?'textarea':'input');if(type!=='textarea')i.type=type;if(type==='checkbox')i.checked=!!value;else if(type!=='file')i.value=value;l.append(i);root.append(l);return i}
function select(root,label,options){const l=node('label',tr(label)),i=node('select');for(const [v,t] of options)i.append(new Option(t,v));l.append(i);root.append(l);return i}
async function jpeg(file){if(!file||!['image/jpeg','image/png','image/webp'].includes(file.type)||file.size>10000000)throw Error('Choose a supported image');const bm=await createImageBitmap(file);try{if(bm.width>8000||bm.height>8000)throw Error('Image dimensions');const cv=document.createElement('canvas'),ctx=cv.getContext('2d');for(const size of [360,280,200,140]){const k=Math.min(1,size/Math.max(bm.width,bm.height));cv.width=Math.max(1,Math.round(bm.width*k));cv.height=Math.max(1,Math.round(bm.height*k));ctx.fillStyle='#fff';ctx.fillRect(0,0,cv.width,cv.height);ctx.drawImage(bm,0,0,cv.width,cv.height);const data=cv.toDataURL('image/jpeg',.65).split(',')[1];if(data?.startsWith('/9j/')&&data.length<=32000)return data}throw Error('Image compression failed')}finally{bm.close()}}

// Separate encrypted chunks for pending high-resolution files. Forgetting the catalog
// snapshot never deletes pending upload bytes. Each chunk has scope-bound AES-GCM.
const originalBase=(scope,req)=>{if(!uuid(req))throw Error('Invalid image reference');return 'original:'+scopeOf(scope)+':'+req};
const sha=async data=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',data)),x=>x.toString(16).padStart(2,'0')).join('');
async function encodeHighResolution(file){if(!file||!['image/jpeg','image/png','image/webp'].includes(file.type)||file.size>10000000)throw Error('Invalid original');const bm=await createImageBitmap(file);try{if(bm.width>8000||bm.height>8000)throw Error('Image dimensions');const cv=document.createElement('canvas'),ratio=Math.min(1,1600/Math.max(bm.width,bm.height));cv.width=Math.max(1,Math.round(bm.width*ratio));cv.height=Math.max(1,Math.round(bm.height*ratio));const c=cv.getContext('2d');c.fillStyle='#fff';c.fillRect(0,0,cv.width,cv.height);c.drawImage(bm,0,0,cv.width,cv.height);for(const q of [.9,.8,.65]){const b=await new Promise(r=>cv.toBlob(r,'image/jpeg',q));if(b&&b.size>=12&&b.size<=2000000)return new Uint8Array(await b.arrayBuffer())}throw Error('Original too large')}finally{bm.close()}}
function b64(bytes){let s='';for(let i=0;i<bytes.length;i+=16384)s+=String.fromCharCode(...bytes.subarray(i,i+16384));return btoa(s)}
export async function stageOriginal(scope,pass,product,file,alt,requestId){
 if(!uuid(product)||!uuid(requestId)||typeof alt!=='string'||!alt.trim()||alt.trim().length>100)throw Error('Invalid image metadata');
 const bytes=await encodeHighResolution(file),digest=await sha(bytes),base=originalBase(scope,requestId),chunks=Math.ceil(bytes.length/500000);
 return withLock(base,async()=>{if(await get(base+':manifest'))throw Error('Existing file draft');const written=[];try{for(let i=0;i<chunks;i++){const k=base+':'+i;await put(k,await sealOfflineVault({data:b64(bytes.subarray(i*500000,(i+1)*500000))},pass,k));written.push(k)}const k=base+':manifest';await put(k,await sealOfflineVault({chunks,bytes:bytes.length,digest,product,alt:alt.trim()},pass,k));return {kind:'originalUpload',store:scope.store,product,requestId,bytes:bytes.length,digest,alt:alt.trim()}}catch(err){for(const k of written)try{await del(k)}catch{}throw err}});
}
async function loadOriginal(scope,pass,x){const base=originalBase(scope,x.requestId),k=base+':manifest',m=await openOfflineVault(await get(k),pass,k);if(m.product!==x.product||m.alt!==x.alt||m.bytes!==x.bytes||m.digest!==x.digest||!Number.isInteger(m.chunks)||m.chunks<1||m.chunks>4)throw Error('Image draft mismatch');const out=new Uint8Array(m.bytes);let offset=0;for(let i=0;i<m.chunks;i++){const k=base+':'+i,c=await openOfflineVault(await get(k),pass,k),a=atob(c.data);if(a.length>500000||offset+a.length>out.length)throw Error('Invalid chunk');for(let j=0;j<a.length;j++)out[offset+j]=a.charCodeAt(j);offset+=a.length}if(offset!==out.length||await sha(out)!==x.digest)throw Error('Image checksum mismatch');return out}
export async function forgetOriginalDraft(scope,requestId){const base=originalBase(scope,requestId);return withLock(base,async()=>{for(const k of ['manifest','0','1','2','3'])await del(base+':'+k)})}
export async function sendOfflineOriginal(api,scope,pass,device,x){
 if(x.kind==='originalDelete'){const r=await api.offlineOriginalDeleteBegin(scope.store,device,x);if(r.status==='conflict'){const e=Error('Image changed');e.status=409;throw e}if(r.status==='confirmed')return r;if(r.uploaded)await api.deleteReservedOriginal(scope.store,r);const done=await api.offlineOriginalDeleteFinish(scope.store,device,x);if(done.status!=='confirmed')throw Error('Image deletion unconfirmed');return done}
 const reserved=await api.offlineOriginalReserve(scope.store,device,x);if(reserved.status==='confirmed'){await forgetOriginalDraft(scope,x.requestId).catch(()=>{});return reserved}
 const bytes=await loadOriginal(scope,pass,x);
 if(!reserved.uploaded){await api.offlineDeviceRequire(scope.store,device);await api.uploadProductOriginal(scope.store,reserved,new Blob([bytes],{type:'image/jpeg'}))}
 // A retry never overwrites an existing object. Compare the authenticated read-back.
 await api.offlineDeviceRequire(scope.store,device);const actual=await api.readProductOriginal(scope.store,reserved);
 if(actual.byteLength!==x.bytes||await sha(actual)!==x.digest)throw Error('Original differs; review manually');
 const r=await api.offlineOriginalFinish(scope.store,device,x);await forgetOriginalDraft(scope,x.requestId).catch(()=>{});return r
}

export function mountOfflineInventory({root,context,save,message}){
 let generation=0,selected=null,working=false,originalPending=null;
 const clear=()=>{generation++;selected=null;originalPending=null;root.replaceChildren();root.hidden=true};
 const open=(snapshot,pass)=>{clear();if(snapshot.role!=='owner')return;const token=generation;root.hidden=false;const title=node('h2',tr('تفاصيل المخزون المحلية')),status=node('p',''),search=field(root,'بحث المنتجات'),list=node('select'),editor=node('div');root.prepend(title);root.append(status,list,editor);let m=null;
  const fail=()=>message('تعذر فتح أو حفظ تفاصيل المخزون');
  let pageIndex=0;const update=()=>{if(!m)return;const query=search.value.toLowerCase(),rows=m.ids.filter(x=>(x.name+' '+x.sku).toLowerCase().includes(query));pageIndex=Math.max(0,Math.min(pageIndex,Math.ceil(rows.length/200)-1));list.replaceChildren(...rows.slice(pageIndex*200,pageIndex*200+200).map(x=>new Option(x.name+' — '+x.sku,x.id)));status.textContent=m.capturedAt+' — '+rows.length+' / '+m.ids.length+' — '+(pageIndex+1)+' / '+Math.max(1,Math.ceil(rows.length/200))};root.insertBefore(button('السابق',()=>{pageIndex--;update()}),editor);root.insertBefore(button('التالي',()=>{pageIndex++;update()}),editor);search.oninput=()=>{pageIndex=0;update()};
  const active=()=>{const ctx=context();return token===generation&&ctx&&ctx.snapshot.store===snapshot.store&&ctx.snapshot.actor===snapshot.actor&&m&&Date.now()-Date.parse(m.capturedAt)<=86400000&&Date.now()-Date.parse(m.capturedAt)>=-60000&&!working};
  const guarded=fn=>async()=>{if(!active())return;working=true;try{await fn()}catch{fail()}finally{working=false}};
  const submit=async op=>{if(token!==generation||!context()||!confirm(tr('حفظ مسودة غير معتمدة؟')))return;const count=await save({store:snapshot.store,requestId:crypto.randomUUID(),product:selected.catalog.id,...op});message('تم الحفظ محلياً',': '+count)};
  const show=()=>{editor.replaceChildren();const x=selected,c=x.catalog;editor.append(node('h3',c.name));const f=node('div'),name=field(f,'اسم المنتج',c.name),sku=field(f,'SKU',c.sku),listed=field(f,'عرض المنتج في المتجر',c.listed,'checkbox'),profile=structuredClone(c.profile),fields={};for(const k of ['name_en','type','brand','category','model','variant','description','video'])fields[k]=field(f,k,profile[k],k==='description'?'textarea':'text');const specs=field(f,'المواصفات: JSON',JSON.stringify(c.specs,null,2),'textarea'),photos=node('div'),file=field(f,'إضافة صورة مصغرة','','file');file.accept='image/jpeg,image/png,image/webp';const renderPhotos=()=>{photos.replaceChildren(...profile.photos.map((p,i)=>{const a=node('div'),im=node('img');im.src='data:image/jpeg;base64,'+p;im.width=100;im.alt='Product';a.append(im,button('إزالة',()=>{if(active()){profile.photos.splice(i,1);renderPhotos()}}));return a}))};renderPhotos();f.append(photos,button('إضافة الصورة',guarded(async()=>{if(profile.photos.length>=4)throw Error('Four images maximum');profile.photos.push(await jpeg(file.files[0]));file.value='';renderPhotos()})),button('حفظ تعديل المنتج',guarded(async()=>{for(const k of Object.keys(fields))profile[k]=fields[k].value.trim();const sp=JSON.parse(specs.value);validateSpecs(sp);validateCatalogProfile(profile);if(!name.value.trim()||name.value.length>160||!sku.value.trim()||sku.value.length>80)throw Error('Invalid product');await submit({kind:'catalogEdit',digest:x.digest,desired:{name:name.value.trim(),sku:sku.value.trim(),listed:listed.checked,profile,specs:sp}})})));editor.append(f,node('h3',tr('الأسعار الخاصة والعملات')));
   const prices=node('div'),kind=select(prices,'نوع السعر',[['retailPrice','Retail'],['tierPrice','Tier'],...(x.customers!==null?[['customerPrice','Customer']]:[]),...(x.buyers!==null?[['buyerPrice','Online buyer']]:[])]),currency=select(prices,'العملة',currencies.map(c=>[c,c])),subject=field(prices,'معرّف العميل / الفئة'),price=field(prices,'السعر'),min=field(prices,'الحد الأدنى للكمية','1'),enabled=field(prices,'تفعيل السعر',true,'checkbox'),prior=node('p'),rows=()=>({retailPrice:x.retail,tierPrice:x.tiers,customerPrice:x.customers,buyerPrice:x.buyers}[kind.value]||[]),find=()=>rows().find(p=>p.currency===currency.value&&(kind.value==='retailPrice'||p.subject===subject.value.trim())),refresh=()=>{const p=find();prior.textContent=p?String(p.price/100)+' / '+String(p.min??'—'):tr('لا يوجد سعر محفوظ');price.value=p?String(p.price/100):'';min.value=String(p?.min||1);enabled.checked=true;enabled.disabled=kind.value==='retailPrice';subject.disabled=kind.value==='retailPrice';min.disabled=kind.value==='retailPrice'};kind.onchange=currency.onchange=subject.onchange=refresh;prices.append(prior,button('حفظ السعر',guarded(async()=>{const k=kind.value,sub=subject.value.trim(),p=find();if(k==='tierPrice'&&!tiers.includes(sub)||['customerPrice','buyerPrice'].includes(k)&&!uuid(sub))throw Error('Invalid subject');const prior=p?{price:p.price,...(k==='retailPrice'?{}:{min:p.min})}:null;const n=Number(min.value);if(k!=='retailPrice'&&enabled.checked&&(!Number.isSafeInteger(n)||n<1||n>100))throw Error('Invalid minimum');const desired=enabled.checked?{price:money(price.value),...(k==='retailPrice'?{}:{min:n})}:null;await submit({kind:k,currency:currency.value,subject:k==='retailPrice'?null:sub,expected:prior,desired})})));
   const table=node('div');for(const [key,arr] of Object.entries({Retail:x.retail,Tier:x.tiers,Customer:x.customers,Buyer:x.buyers})){if(arr===null)continue;table.append(node('h4',key));for(const p of arr)table.append(node('p',[p.subject,p.currency,p.price/100,p.min].filter(v=>v!==undefined).join(' — ')))}refresh();editor.append(prices,table,node('h3',tr('الصور عالية الدقة')));const originalArea=node('div'),originalFile=field(originalArea,'ملف صورة عالي الدقة','','file'),originalAlt=field(originalArea,'وصف الصورة');originalFile.accept='image/jpeg,image/png,image/webp';for(const a of x.originals){const line=node('p',a.alt+' — '+(a.uploaded?(a.published?'منشورة':'خاصة'):'بانتظار الرفع'));if(a.uploaded)line.append(button(a.published?'إلغاء نشر الصورة':'نشر الصورة',guarded(()=>submit({kind:'originalPublish',asset:a.id,expected:a.published,enabled:!a.published}))));line.append(button('حذف الصورة الأصلية',guarded(async()=>{if(!confirm(tr('حذف الملف الأصلي نهائياً بعد المزامنة؟')))return;await submit({kind:'originalDelete',asset:a.id,alt:a.alt,published:a.published,uploaded:a.uploaded,confirm:true})})));originalArea.append(line)}originalArea.append(button('حفظ ملف الصورة المشفر',guarded(async()=>{if(originalPending&&originalPending.product!==selected.catalog.id)throw Error('Retry pending image first');if(!originalPending){if(!confirm(tr('حفظ الصورة كمسودة خاصة؟')))return;originalPending=await stageOriginal(snapshot,pass,selected.catalog.id,originalFile.files[0],originalAlt.value,crypto.randomUUID())}if(token!==generation||!context())throw Error('Workspace changed');const count=await save(originalPending);originalPending=null;originalFile.value='';originalAlt.value='';message('تم الحفظ محلياً',': '+count)})));editor.append(originalArea);
  };
  root.insertBefore(button('فتح تفاصيل المنتج',guarded(async()=>{if(!list.value)return;selected=await readItem(snapshot,pass,m,list.value);if(token===generation)show()})),editor);
  manifest(snapshot,pass).then(v=>{if(token!==generation)return;m=v;if(v)update();else status.textContent=tr('جهز تفاصيل المخزون أثناء الاتصال أولاً')}).catch(fail);
 };
 return {open,clear};
}

const recordsBase=x=>'records:'+scopeOf(x),recordsKey=x=>recordsBase(x)+':active';
async function purgePrefix(prefix){return access('readwrite',s=>{const r=s.openCursor();r.onsuccess=()=>{const c=r.result;if(c){if(typeof c.key==='string'&&c.key.startsWith(prefix+':'))c.delete();c.continue()}}})}
export async function forgetOfflineRecords(scope){return withLock(recordsBase(scope),()=>purgePrefix(recordsBase(scope)))}
export async function captureOfflineRecords(scope,pass,loadManifest,loadPage){
 const base=recordsBase(scope);return withLock(base,async()=>{
  const prior=await get(recordsKey(scope));if(prior)await openOfflineVault(prior,pass,recordsKey(scope));
  const e=await loadManifest();if(e?.store!==scope.store||!Number.isFinite(Date.parse(e.captured_at))||!Array.isArray(e.tables)||new Set(e.tables).size!==e.tables.length)throw Error('Invalid records manifest');
  const generation=crypto.randomUUID(),prefix=base+':'+generation,tables=[];let total=0;
  try{
   for(const name of e.tables){if(!/^(public\.mt_[a-z_]+|tenant_private\.[a-z_]+)$/.test(name))throw Error('Invalid relation');let pages=0,count=0,cursor=null;
    for(;;){const p=await loadPage(name,cursor);if(p?.store!==scope.store||p.table!==name||!Array.isArray(p.rows)||p.rows.length>25||typeof p.done!=='boolean'||p.rows.some(row=>!row||row.store_id!==scope.store))throw Error('Invalid records page');
     if(p.rows.length){await putChunked(prefix+':'+name+':'+pages++,p.rows,pass);count+=p.rows.length;total+=p.rows.length}
     if(p.done)break;if(!p.rows.length||!Array.isArray(p.cursor)||JSON.stringify(p.cursor)===JSON.stringify(cursor))throw Error('Invalid records cursor');cursor=p.cursor;
    }tables.push({name,rows:count,pages});
   }
   await put(recordsKey(scope),await sealOfflineVault({generation,capturedAt:e.captured_at,completedAt:new Date().toISOString(),tables,total},pass,recordsKey(scope)));
  }catch(err){await purgePrefix(prefix).catch(()=>{});throw err}
  if(prior)try{const old=await openOfflineVault(prior,pass,recordsKey(scope));await purgePrefix(base+':'+old.generation)}catch{}
  return total;
 });
}
export function mountOfflineRecords({root,message}){
 let generation=0;const clear=()=>{generation++;root.replaceChildren();root.hidden=true};
 const open=(scope,pass)=>{clear();if(scope.role!=='owner')return;const token=generation;root.hidden=false;const status=node('p',''),table=node('select'),page=node('select'),view=node('pre','');root.append(node('h2',tr('السجلات التشغيلية المحلية')),node('p',tr('نسخة للقراءة فقط وليست سجلاً مالياً معتمداً.')),status,table,page,view);
  const read=async()=>{view.textContent='';if(!m||token!==generation)return;const t=m.tables.find(x=>x.name===table.value),n=Number(page.value);if(!t||!Number.isInteger(n)||n<0||n>=t.pages)return;try{const key=recordsBase(scope)+':'+m.generation+':'+t.name+':'+n,rows=await getChunked(key,pass);if(token!==generation||table.value!==t.name||Number(page.value)!==n)return;view.textContent=JSON.stringify(rows,null,2)}catch{message('تعذر فتح السجلات المحلية')}};
  let m=null;const choose=()=>{view.textContent='';const t=m?.tables.find(x=>x.name===table.value);page.replaceChildren(...Array.from({length:t?.pages||0},(_,i)=>new Option(String(i+1),String(i))));read()};table.onchange=choose;page.onchange=read;
  get(recordsKey(scope)).then(raw=>raw?openOfflineVault(raw,pass,recordsKey(scope)):null).then(v=>{if(token!==generation)return;if(!v){status.textContent=tr('جهز السجلات أثناء الاتصال أولاً');return}if(!uuid(v.generation)||!Array.isArray(v.tables)||!Number.isFinite(Date.parse(v.capturedAt)))throw Error('Invalid snapshot');m=v;status.textContent=v.capturedAt+(v.completedAt?' — '+v.completedAt:'')+' — '+v.total+' / '+tr('سجل');table.replaceChildren(...v.tables.map(t=>new Option(t.name+' ('+t.rows+')',t.name)));choose()}).catch(()=>{if(token===generation)message('تعذر فتح السجلات المحلية')});
 };
 return {open,clear}
}
