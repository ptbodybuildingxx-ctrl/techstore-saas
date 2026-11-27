// Encrypted ordered operation drafts. Server is authoritative; never store auth credentials.
import {readLocalVault,writeLocalVault,localVaultPresent} from './offline-storage.mjs';
const permitted=new Set(['cashSale','supplier','supplierProfile','purchase','purchaseBatch','procureReceipt','procureDue','supplierPayment','supplierReturn','repair','transition','repairCheckout','warrantyOpen','warrantyPart','warrantyTransition','saleClaimOpen','saleClaimTransition','repairRefund','voucher','mixed','tradein','tradeinExecute','campaign','stockCount','customer','customerEdit','pay','credit','standaloneOpen','standalonePay','quote','costIntake','branchTransfer','cashMovement','payrollAdjustment','payrollPartial','payrollReverse','accountingAdjust','reviewedPrice','payrollFinal','payrollAdvance','payrollOffset','orderConfirm','orderCancel','orderFulfill','taxFiling','branchApproval','periodClose','catalogCreate','catalogRename','catalogEdit','retailPrice','tierPrice','customerPrice','buyerPrice','originalPublish','originalUpload','originalDelete']);
const uuid=x=>typeof x==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(x);
const key=(store,actor)=>{if(!uuid(store)||!uuid(actor))throw Error('Invalid offline identity');return 'techstore-operations-v1:'+store+':'+actor};
function assertDraft(x,store){if(!x||!permitted.has(x.kind)||x.store!==store||!uuid(x.requestId))throw Error('Operation cannot be stored offline');checkedDeps(x);const {dependencies,...payload}=x,bytes=new TextEncoder().encode(JSON.stringify(payload)).length;if(bytes>(x.kind==='catalogEdit'?300000:90000)||new TextEncoder().encode(JSON.stringify(dependencies||[])).length>50000)throw Error('Operation exceeds server payload capacity')}
async function locked(scope,fn){if(!navigator.locks?.request)throw Error('Exclusive offline storage unavailable');return navigator.locks.request(scope,{mode:'exclusive'},fn)}
async function read(scope,pass,store,actor){const v=await readLocalVault(scope,pass);if(v===null)return [];if(v.version!==1||v.store!==store||v.actor!==actor||!Array.isArray(v.entries))throw Error('Invalid offline queue');const seen=new Set();for(const e of v.entries){assertDraft(e.operation,store);if(!Number.isFinite(Date.parse(e.createdAt))||seen.has(e.operation.requestId))throw Error('Invalid queued entry');if(e.attemptedAt!==undefined&&(e.operation.dependencies||!Number.isFinite(Date.parse(e.attemptedAt))))throw Error('Invalid attempt timestamp');if(e.failure!==undefined&&(!e.attemptedAt||!['authorization','conflict','unconfirmed'].includes(e.failure)))throw Error('Invalid failure status');seen.add(e.operation.requestId)}return v.entries}
async function write(scope,pass,store,actor,entries){await writeLocalVault(scope,pass,{version:1,store,actor,entries},{present:entries.length>0})}
export function queuePresent(store,actor){try{return localVaultPresent(key(store,actor))}catch{return true}}
export function canQueue(operation){return permitted.has(operation?.kind)}
export async function addQueuedOperation({store,actor,pass,operation,attempted=false}){const scope=key(store,actor);assertDraft(operation,store);if(typeof attempted!=='boolean')throw Error('Invalid delivery marker');return locked(scope,async()=>{const entries=await read(scope,pass,store,actor),existing=entries.find(e=>e.operation.requestId===operation.requestId);if(existing){if(JSON.stringify(existing.operation)!==JSON.stringify(operation))throw Error('Conflicting request');if(attempted&&!existing.attemptedAt){existing.attemptedAt=new Date().toISOString();existing.failure='unconfirmed';await write(scope,pass,store,actor,entries)}return entries.length}if(attempted&&operation.dependencies?.length)throw Error('Attempted operations cannot have unresolved dependencies');if(operation.dependencies?.some(a=>a.request===operation.requestId))throw Error('Invalid prerequisite');entries.push({createdAt:new Date().toISOString(),operation:structuredClone(operation),...(attempted?{attemptedAt:new Date().toISOString(),failure:'unconfirmed'}:{})});await write(scope,pass,store,actor,entries);return entries.length})}
export async function listPendingProducts({store,actor,pass,currency}){const scope=key(store,actor);return locked(scope,async()=>{const entries=await read(scope,pass,store,actor);return entries.filter(e=>e.operation.kind==='catalogCreate'&&!e.attemptedAt&&e.operation.currency===currency).map(e=>{const p=e.operation;return {id:p.requestId,name:p.name,sku:p.sku,price:p.price,localCreation:true}}).filter(p=>uuid(p.id)&&typeof p.name==='string'&&typeof p.sku==='string'&&Number.isSafeInteger(p.price)&&p.price>=1&&p.price<=100000000)})}
export function attachSaleProductDependencies(operation,productIds){const op=structuredClone(operation),sale=op.kind==='credit'?op.sale:op,prefix=op.kind==='credit'?'sale.':'',ids=new Set(productIds),dependencies=[...(op.dependencies||[])];if(!['cashSale','mixed','credit'].includes(op.kind)||!Array.isArray(sale?.lines)||!Array.isArray(sale?.invoice?.lines))throw Error('Invalid linked sale');for(const [path,lines] of [['lines',sale.lines],['invoice.lines',sale.invoice.lines]])for(let i=0;i<lines.length;i++){const request=lines[i].product_id;if(ids.has(request))dependencies.push({field:prefix+path+'.'+i+'.product_id',entity:'product',request})}if(dependencies.length)op.dependencies=dependencies;checkedDeps(op);return op}
export async function inspectQueuedOperations({store,actor,pass}){const scope=key(store,actor);return locked(scope,async()=>{const entries=await read(scope,pass,store,actor);return entries.map(e=>({id:e.operation.requestId,kind:e.operation.kind,createdAt:e.createdAt,attemptedAt:e.attemptedAt??null,failure:e.failure??null,dependencies:e.operation.dependencies?.length||0}))})}
// Only the newest draft can be discarded; an attempted operation may already exist on the server.
export async function discardUnsentTail({store,actor,pass,requestId}){const scope=key(store,actor);if(!uuid(requestId))throw Error('Invalid request');return locked(scope,async()=>{const entries=await read(scope,pass,store,actor),tail=entries.at(-1);if(!tail||tail.operation.requestId!==requestId||tail.attemptedAt!==undefined)throw Error('Only the latest never-attempted draft may be removed');await write(scope,pass,store,actor,entries.slice(0,-1));return entries.length})}
export async function discardUnsentGroup({store,actor,pass,requestId,approve}){
 const scope=key(store,actor);if(!uuid(requestId)||typeof approve!=='function')throw Error('Invalid discard reference');return locked(scope,async()=>{
  const entries=await read(scope,pass,store,actor),target=entries.find(e=>e.operation.requestId===requestId);
  if(!target||target.attemptedAt)throw Error('Attempted or missing draft');
  const removed=new Set([requestId]);let changed=true;
  while(changed){changed=false;for(const e of entries)if(!removed.has(e.operation.requestId)&&e.operation.dependencies?.some(a=>removed.has(a.request))){removed.add(e.operation.requestId);changed=true}}
  const group=entries.filter(e=>removed.has(e.operation.requestId));
  if(group.some(e=>e.attemptedAt))throw Error('Attempted dependent must be resolved on server');
  const list=group.map(e=>({id:e.operation.requestId,kind:e.operation.kind}));
  if(!await approve(list))return [];
  await write(scope,pass,store,actor,entries.filter(e=>!removed.has(e.operation.requestId)));return list
 });
}
export async function reviewQueuedOperation({store,actor,pass,requestId}){const scope=key(store,actor);if(!uuid(requestId))throw Error('Invalid request');return locked(scope,async()=>{const entry=(await read(scope,pass,store,actor)).find(e=>e.operation.requestId===requestId);if(!entry)throw Error('Missing draft');return structuredClone(entry.operation)})}
export async function replayQueuedOperations({store,actor,pass,send,approve,prepare=async x=>x,limit=Number.MAX_SAFE_INTEGER}){const scope=key(store,actor);return locked(scope,async()=>{const entries=await read(scope,pass,store,actor);let confirmed=0;while(entries.length&&confirmed<limit){const e=entries[0];if(!e.attemptedAt&&e.operation.dependencies?.length){try{const next=await prepare(structuredClone(e.operation));assertDraft(next,store);if(next.requestId!==e.operation.requestId||next.kind!==e.operation.kind||next.dependencies)throw Error('Invalid prepared dependency');e.operation=next;await write(scope,pass,store,actor,entries)}catch{return {confirmed,remaining:entries.length,blocked:{id:e.operation.requestId,kind:e.operation.kind,failure:'dependency'}}}}if(!await approve({id:e.operation.requestId,kind:e.operation.kind,createdAt:e.createdAt,operation:structuredClone(e.operation)}))break;e.attemptedAt=new Date().toISOString();e.failure='unconfirmed';await write(scope,pass,store,actor,entries);try{await send(structuredClone(e.operation))}catch(err){e.failure=err?.status===401||err?.status===403?'authorization':err?.status===409?'conflict':'unconfirmed';await write(scope,pass,store,actor,entries);return {confirmed,remaining:entries.length,blocked:{id:e.operation.requestId,kind:e.operation.kind,failure:e.failure}}}await write(scope,pass,store,actor,entries.slice(1));entries.shift();confirmed++}return {confirmed,remaining:entries.length}})}

// Only the attempted head count can be abandoned, and only after server cancellation or confirmation.
export async function resolveAttemptedCount({store,actor,pass,cancel,approve}){const scope=key(store,actor);return locked(scope,async()=>{const entries=await read(scope,pass,store,actor),head=entries[0];if(!head||head.operation.kind!=='stockCount'||!head.attemptedAt)throw Error('No attempted count at queue head');if(!await approve(structuredClone(head.operation)))return null;const result=await cancel(structuredClone(head.operation));if(!['confirmed','cancelled'].includes(result))throw Error('Count status unknown');await write(scope,pass,store,actor,entries.slice(1));return result})}

// Only the attempted head can be resolved; the server must confirm its exact payload or record an explicit terminal decision.
export async function resolveAttemptedReceivable({store,actor,pass,resolve}){
 const scope=key(store,actor);return locked(scope,async()=>{
  const entries=await read(scope,pass,store,actor),head=entries[0];
  if(!head||!head.attemptedAt||(!['customer','customerEdit','pay','credit','standaloneOpen','standalonePay'].includes(head.operation.kind)&&!((head.operation.kind==='cashSale'&&head.operation.localPricing)||(head.operation.kind==='mixed'&&head.operation.invoice))))throw Error('No attempted receivable at queue head');
  const result=await resolve(structuredClone(head.operation));if(result===null)return null;
  if(!['confirmed','cancelled','conflict_acknowledged'].includes(result))throw Error('Receivable still unresolved');
  await write(scope,pass,store,actor,entries.slice(1));return result;
 });
}

// Explicit dispatcher: fixed payload and request reference, never arbitrary RPC names.
// Methods below already validate server confirmations and enforce current store permissions.
export async function sendQueuedOperation(api,store,x,device,sendOriginal){
 assertDraft(x,store);if(x.dependencies)throw Error('Unresolved dependency');
 if(['originalUpload','originalDelete'].includes(x.kind)){if(typeof sendOriginal!=='function')throw Error('Image storage unavailable');return sendOriginal(x)}
 if(['reviewedPrice','payrollFinal','payrollAdvance','payrollOffset','orderConfirm','orderCancel','orderFulfill','taxFiling','branchApproval','periodClose','catalogCreate','catalogRename','catalogEdit','retailPrice','tierPrice','customerPrice','buyerPrice','originalPublish'].includes(x.kind)){
 const result=await api.offlineReviewedWrite(store,device,x);if(result.status==='conflict'){const e=Error('Reviewed value changed');e.status=409;throw e}return result;
 }
 return api.withOfflineReplay(store,device,x.requestId,()=>sendLegacy(api,store,x));
}
async function sendLegacy(api,store,x){
 switch(x.kind){
 case 'cashSale':return api.recordSale(x);
 case 'stockCount':return api.countCommit(store,{branch:x.branch,request:x.requestId,reason:x.reason,items:x.items});
 case 'customer':case 'customerEdit':case 'pay':case 'credit':case 'standaloneOpen':case 'standalonePay':return api.receivableOperation(store,x);
 case 'quote':return api.createQuote(store,{...x,request:x.requestId});
 case 'costIntake':return api.receiveCostedStock(store,x);
 case 'branchTransfer':return api.branchTransfer(store,{...x,request:x.requestId});
 case 'cashMovement':return api.recordCash(store,{...x,kind:x.cashKind});
 case 'payrollAdjustment':return api.payrollAdjustment(store,{...x,id:x.requestId,kind:x.adjustment});
 case 'payrollPartial':return api.payrollPartial(store,{id:x.payroll,request:x.requestId,amount:x.amount,confirm:x.confirm});
 case 'payrollReverse':return api.payrollReverse(store,{id:x.requestId,original:x.original,reason:x.reason});
 default:return api.operation(store,x);
 }
}

// A terminal conflict receipt is the only way to remove these attempted drafts.
// The caller explicitly acknowledges the mismatch and must create a new reviewed request.
export async function resolveReviewedConflict({store,actor,pass,resolve,approve}){
 const scope=key(store,actor);return locked(scope,async()=>{
 const entries=await read(scope,pass,store,actor),head=entries[0];
 if(!head?.attemptedAt||head.failure!=='conflict'||!['reviewedPrice','payrollFinal','orderConfirm','orderCancel','orderFulfill','taxFiling','branchApproval','periodClose','catalogCreate','catalogRename'].includes(head.operation.kind))throw Error('No recorded reviewed conflict');
 const result=await resolve(structuredClone(head.operation));
 if(result?.status!=='conflict'||result.requestId!==head.operation.requestId)throw Error('Conflict not confirmed');
 if(!await approve(result,structuredClone(head.operation)))return false;
 await write(scope,pass,store,actor,entries.slice(1));return true;
 });
}

// Typed dependency slots. Nested paths are generated locally, not arbitrary property paths.
// A prerequisite is useful for same-record transitions where no replacement ID is needed.
const dependencyFields={
 repair:{customer:'customer'},transition:{repair:'repair'},repairCheckout:{repair:'repair'},repairRefund:{invoice:'repairInvoice'},warrantyOpen:{invoice:'repairInvoice'},warrantyPart:{claim:'warrantyClaim',product:'product'},warrantyTransition:{claim:'warrantyClaim'},saleClaimOpen:{sale:'sale',product:'product'},saleClaimTransition:{claim:'saleClaim'},
 purchase:{supplier:'supplier',product:'product'},purchaseBatch:{supplier:'supplier'},procureReceipt:{supplier:'supplier'},supplierPayment:{purchase:'purchase'},procureDue:{purchase:'purchase'},supplierReturn:{purchase:'purchase'},tradein:{customer:'customer'},tradeinExecute:{id:'tradein',usedProduct:'product'},
 customerEdit:{customer:'customer'},pay:{debt:'invoiceDebt'},credit:{'terms.customer':'customer'},standaloneOpen:{'payload.customer':'customer'},standalonePay:{'payload.debt':'standaloneDebt'},payrollOffset:{advance:'advance'},payrollReverse:{original:'payrollAdjustment'},
 catalogRename:{product:'product'},reviewedPrice:{product:'product'},costIntake:{product:'product'},branchTransfer:{product:'product'},branchApproval:{previous:'branchApproval'},taxFiling:{previous:'taxFiling'},
 catalogEdit:{product:'product'},retailPrice:{product:'product'},tierPrice:{product:'product'},customerPrice:{product:'product',subject:'customer'},originalPublish:{asset:'original'},originalDelete:{asset:'original'}
};
function allowedDependency(kind,field,entity){if(field==='$after')return entity==='operation';if(dependencyFields[kind]?.[field]===entity)return true;if(entity!=='product')return false;if(['procureReceipt','purchaseBatch','repairCheckout','quote','tradeinExecute'].includes(kind)&&/^lines\.(?:0|[1-9]\d?)\.product_id$/.test(field))return true;if(['cashSale','mixed'].includes(kind))return /^(?:invoice\.)?lines\.(?:0|[1-9]\d?)\.product_id$/.test(field);return kind==='credit'&&/^sale\.(?:invoice\.)?lines\.(?:0|[1-9]\d?)\.product_id$/.test(field)}
const inputPaths={standaloneOpen:{customer:'payload.customer'},standalonePay:{debt:'payload.debt'},procureReceipt:{product:'lines.0.product_id'}};
const draftKind=k=>k==='purchaseBatch'?'procureReceipt':k;
export function canLinkProduct(kind){return allowedDependency(draftKind(kind),inputPaths[kind]?.product||'product','product')}
function checkedDeps(x){
 const list=x.dependencies;if(list===undefined)return [];if(!Array.isArray(list)||!list.length||list.length>240)throw Error('Invalid dependencies');
 const seen=new Set();for(const a of list){if(!a||typeof a.field!=='string'||!uuid(a.request)||a.request===x.requestId||!allowedDependency(x.kind,a.field,a.entity))throw Error('Invalid dependency');const key=a.field==='$after'?'$after:'+a.request:a.field;if(seen.has(key))throw Error('Duplicate dependency');seen.add(key)}
 return list
}
export function attachDependencies(kind,values,make){
 const v={...values},dependencies=[],target=draftKind(kind);
 for(const [key,value] of Object.entries(v)){
  if(key==='afterRequest'){if(value?.trim()){for(const request of value.trim().split(/\s*,\s*/)){if(!uuid(request))throw Error('Invalid prerequisite');dependencies.push({field:'$after',entity:'operation',request})}}delete v[key];continue}
  const field=inputPaths[kind]?.[key]||key;if(typeof value!=='string'||!value.startsWith('@')||key==='lines')continue;
  const entity=dependencyFields[target]?.[field]||(field==='lines.0.product_id'?'product':null);if(!entity||!allowedDependency(target,field,entity))continue;
  const request=value.slice(1);if(!uuid(request))throw Error('Invalid parent request');v[key]=request;dependencies.push({field,entity,request});
 }
 if(['purchaseBatch','repairCheckout','quote','tradeinExecute'].includes(kind)&&typeof v.lines==='string'){
  v.lines=v.lines.trim().split(/\r?\n/).filter(s=>s.trim()).map((line,i)=>{const a=line.split(',');if(a[0]?.trim().startsWith('@')){const request=a[0].trim().slice(1);if(!uuid(request)||i>99)throw Error('Invalid product dependency');dependencies.push({field:'lines.'+i+'.product_id',entity:'product',request});a[0]=request}return a.join(',')}).join('\n')
 }
 const x=make(v,dependencies),out=dependencies.length?{...x,dependencies}:x;checkedDeps(out);return out;
}
export async function resolveDependencies(x,lookup){
 const y=structuredClone(x),deps=checkedDeps(y),resolved=new Map(),productRemap=new Map();
 if(!deps.length)throw Error('Missing dependencies');
 for(const a of deps){const lookupKey=a.entity+':'+a.request,id=resolved.has(lookupKey)?resolved.get(lookupKey):await lookup(a.request,a.entity);resolved.set(lookupKey,id);if(!uuid(id))throw Error('Parent not confirmed');if(a.field==='$after')continue;
  const parts=a.field.split('.');let node=y;for(const k of parts.slice(0,-1)){if(!node||typeof node!=='object'||!Object.hasOwn(node,k))throw Error('Invalid dependency slot');node=node[k]}const key=parts.at(-1);if(!node||!Object.hasOwn(node,key)||node[key]!==a.request)throw Error('Invalid dependency placeholder');node[key]=id;if(a.entity==='product')productRemap.set(a.request,id);
 }
 if(['cashSale','mixed','credit'].includes(y.kind)){const sale=y.kind==='credit'?y.sale:y,ids=new Set(sale.lines.map(l=>l.product_id));if(ids.size!==sale.lines.length||sale.invoice&&(sale.invoice.lines.length!==ids.size||new Set(sale.invoice.lines.map(l=>l.product_id)).size!==ids.size||sale.invoice.lines.some(l=>!ids.has(l.product_id))))throw Error('Resolved sale contains duplicate or mismatched products');if(sale.localPricing&&productRemap.size){const prices=sale.localPricing.prices;if(!prices||typeof prices!=='object'||Array.isArray(prices)||Object.keys(prices).length!==ids.size)throw Error('Invalid local price keys');const entries=Object.entries(prices).map(([id,price])=>[productRemap.get(id)||id,price]);if(new Set(entries.map(([id])=>id)).size!==ids.size||entries.some(([id,price])=>!ids.has(id)||!Number.isSafeInteger(price)||price<1||price>100000000))throw Error('Invalid resolved prices');sale.localPricing.prices=Object.fromEntries(entries)}}
 delete y.dependencies;return y;
}
// Add a prerequisite to any never-sent draft. Reject forward links in the same FIFO
// queue; external-device parent IDs are allowed but must have a confirmed server receipt.
export async function addQueuedPrerequisite({store,actor,pass,requestId,parent}){
 const scope=key(store,actor);if(!uuid(requestId)||!uuid(parent)||requestId===parent)throw Error('Invalid prerequisite');return locked(scope,async()=>{
  const entries=await read(scope,pass,store,actor),index=entries.findIndex(e=>e.operation.requestId===requestId),parentIndex=entries.findIndex(e=>e.operation.requestId===parent);
  if(index<0||entries[index].attemptedAt||parentIndex>=index)throw Error('Only earlier or external confirmed prerequisite allowed');
  const op=entries[index].operation,dependencies=[...(op.dependencies||[])];if(dependencies.some(a=>a.field==='$after'&&a.request===parent))return entries.length;
  op.dependencies=[...dependencies,{field:'$after',entity:'operation',request:parent}];assertDraft(op,store);await write(scope,pass,store,actor,entries);return entries.length
 });
}
// A receipt from this approved installation may acknowledge a terminal rejection.
// It does not assert that a pre-gateway manual operation never existed.
export async function acknowledgeTerminal({store,actor,pass,receipt,approve}){
 const scope=key(store,actor);return locked(scope,async()=>{
  const entries=await read(scope,pass,store,actor),head=entries[0];
  if(!head?.attemptedAt||head.failure!=='conflict')throw Error('No exact rejected attempt');
  const r=await receipt(head.operation.requestId);
  if(r?.requestId!==head.operation.requestId||r.status!=='conflict')throw Error('No terminal conflict receipt');
  if(!await approve(r,structuredClone(head.operation)))return false;
  await write(scope,pass,store,actor,entries.slice(1));return true;
 });
}
