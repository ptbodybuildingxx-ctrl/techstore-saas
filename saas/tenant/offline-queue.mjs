// Encrypted ordered operation drafts. Server is authoritative; never store auth credentials.
import {sealOfflineVault,openOfflineVault} from '../design/theme.mjs';
const permitted=new Set(['cashSale','supplier','supplierProfile','purchase','purchaseBatch','procureReceipt','procureDue','supplierPayment','supplierReturn','repair','transition','repairCheckout','warrantyOpen','warrantyPart','warrantyTransition','saleClaimOpen','saleClaimTransition','repairRefund','voucher','mixed','tradein','tradeinExecute','campaign','stockCount','customer','customerEdit','pay','credit','standaloneOpen','standalonePay','quote','costIntake','branchTransfer','cashMovement','payrollAdjustment','payrollPartial','payrollReverse','accountingAdjust','reviewedPrice','payrollFinal','payrollAdvance','payrollOffset','orderConfirm','taxFiling','branchApproval']);
const uuid=x=>typeof x==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(x);
const key=(store,actor)=>{if(!uuid(store)||!uuid(actor))throw Error('Invalid offline identity');return 'techstore-operations-v1:'+store+':'+actor};
function assertDraft(x,store){if(!x||!permitted.has(x.kind)||x.store!==store||!uuid(x.requestId)||JSON.stringify(x).length>18000)throw Error('Operation cannot be stored offline')}
async function locked(scope,fn){if(!navigator.locks?.request)throw Error('Exclusive offline storage unavailable');return navigator.locks.request(scope,{mode:'exclusive'},fn)}
async function read(scope,pass,store,actor){const raw=localStorage.getItem(scope);if(raw===null)return [];const v=await openOfflineVault(raw,pass,scope);if(v.version!==1||v.store!==store||v.actor!==actor||!Array.isArray(v.entries)||v.entries.length>30)throw Error('Invalid offline queue');const seen=new Set();for(const e of v.entries){assertDraft(e.operation,store);if(!Number.isFinite(Date.parse(e.createdAt))||seen.has(e.operation.requestId))throw Error('Invalid queued entry');if(e.attemptedAt!==undefined&&!Number.isFinite(Date.parse(e.attemptedAt)))throw Error('Invalid attempt timestamp');if(e.failure!==undefined&&(!e.attemptedAt||!['authorization','conflict','unconfirmed'].includes(e.failure)))throw Error('Invalid failure status');seen.add(e.operation.requestId)}return v.entries}
async function write(scope,pass,store,actor,entries){if(!entries.length){localStorage.removeItem(scope);return}const raw=await sealOfflineVault({version:1,store,actor,entries},pass,scope);localStorage.setItem(scope,raw)}
export function queuePresent(store,actor){try{return !!localStorage.getItem(key(store,actor))}catch{return false}}
export function canQueue(operation){return permitted.has(operation?.kind)}
export async function addQueuedOperation({store,actor,pass,operation,attempted=false}){const scope=key(store,actor);assertDraft(operation,store);if(typeof attempted!=='boolean')throw Error('Invalid delivery marker');return locked(scope,async()=>{const entries=await read(scope,pass,store,actor),existing=entries.find(e=>e.operation.requestId===operation.requestId);if(existing){if(JSON.stringify(existing.operation)!==JSON.stringify(operation))throw Error('Conflicting request');if(attempted&&!existing.attemptedAt){existing.attemptedAt=new Date().toISOString();existing.failure='unconfirmed';await write(scope,pass,store,actor,entries)}return entries.length}if(entries.length>=30)throw Error('Offline queue full');entries.push({createdAt:new Date().toISOString(),operation:structuredClone(operation),...(attempted?{attemptedAt:new Date().toISOString(),failure:'unconfirmed'}:{})});await write(scope,pass,store,actor,entries);return entries.length})}
export async function inspectQueuedOperations({store,actor,pass}){const scope=key(store,actor);return locked(scope,async()=>{const entries=await read(scope,pass,store,actor);return entries.map(e=>({id:e.operation.requestId,kind:e.operation.kind,createdAt:e.createdAt,attemptedAt:e.attemptedAt??null,failure:e.failure??null}))})}
// Only the newest draft can be discarded; an attempted operation may already exist on the server.
export async function discardUnsentTail({store,actor,pass,requestId}){const scope=key(store,actor);if(!uuid(requestId))throw Error('Invalid request');return locked(scope,async()=>{const entries=await read(scope,pass,store,actor),tail=entries.at(-1);if(!tail||tail.operation.requestId!==requestId||tail.attemptedAt!==undefined)throw Error('Only the latest never-attempted draft may be removed');await write(scope,pass,store,actor,entries.slice(0,-1));return entries.length})}
export async function reviewQueuedOperation({store,actor,pass,requestId}){const scope=key(store,actor);if(!uuid(requestId))throw Error('Invalid request');return locked(scope,async()=>{const entry=(await read(scope,pass,store,actor)).find(e=>e.operation.requestId===requestId);if(!entry)throw Error('Missing draft');return structuredClone(entry.operation)})}
export async function replayQueuedOperations({store,actor,pass,send,approve,limit=30}){const scope=key(store,actor);return locked(scope,async()=>{const entries=await read(scope,pass,store,actor);let confirmed=0;while(entries.length&&confirmed<limit){const e=entries[0];if(!await approve({id:e.operation.requestId,kind:e.operation.kind,createdAt:e.createdAt,operation:structuredClone(e.operation)}))break;e.attemptedAt=new Date().toISOString();e.failure='unconfirmed';await write(scope,pass,store,actor,entries);try{await send(structuredClone(e.operation))}catch(err){e.failure=err?.status===401||err?.status===403?'authorization':err?.status===409?'conflict':'unconfirmed';await write(scope,pass,store,actor,entries);return {confirmed,remaining:entries.length,blocked:{id:e.operation.requestId,kind:e.operation.kind,failure:e.failure}}}await write(scope,pass,store,actor,entries.slice(1));entries.shift();confirmed++}return {confirmed,remaining:entries.length}})}

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
export async function sendQueuedOperation(api,store,x,device){
 assertDraft(x,store);
 switch(x.kind){
 case 'reviewedPrice':case 'payrollFinal':case 'payrollAdvance':case 'payrollOffset':case 'orderConfirm':case 'taxFiling':case 'branchApproval':{
 const result=await api.offlineReviewedWrite(store,device,x);if(result.status==='conflict'){const e=Error('Reviewed value changed');e.status=409;throw e}return result;
 }
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
 if(!head?.attemptedAt||head.failure!=='conflict'||!['reviewedPrice','payrollFinal','orderConfirm'].includes(head.operation.kind))throw Error('No recorded reviewed conflict');
 const result=await resolve(structuredClone(head.operation));
 if(result?.status!=='conflict'||result.requestId!==head.operation.requestId)throw Error('Conflict not confirmed');
 if(!await approve(result,structuredClone(head.operation)))return false;
 await write(scope,pass,store,actor,entries.slice(1));return true;
 });
}
