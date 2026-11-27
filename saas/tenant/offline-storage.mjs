// Capacity-limited encrypted local vault. The small localStorage marker is only a
// synchronous discovery hint, never a credential or the authoritative data.
import {sealOfflineVault,openOfflineVault} from '../design/theme.mjs';
const database='techstore-offline-vault-v3',marker='indexeddb-v3',chunkBytes=500000;
async function db(){return new Promise((resolve,reject)=>{const r=indexedDB.open(database,1);r.onupgradeneeded=()=>r.result.createObjectStore('vault');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);r.onblocked=()=>reject(Error('Close other offline tabs'))})}
async function request(mode,task){const conn=await db();try{return await new Promise((resolve,reject)=>{const tx=conn.transaction('vault',mode),s=tx.objectStore('vault');let value;const r=task(s);if(r)r.onsuccess=()=>{value=r.result};tx.oncomplete=()=>resolve(value);tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error||Error('Vault transaction aborted'))})}finally{conn.close()}}
const get=k=>request('readonly',s=>s.get(k)),put=(k,v)=>request('readwrite',s=>s.put(v,k)),del=k=>request('readwrite',s=>s.delete(k));
const active=scope=>scope+':active';
const generationKey=(scope,g)=>scope+':generation:'+g;
const uuid=v=>typeof v==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(v);
function encode(bytes){let s='';for(let i=0;i<bytes.length;i+=16384)s+=String.fromCharCode(...bytes.subarray(i,i+16384));return btoa(s)}
async function purge(prefix){return request('readwrite',s=>{const r=s.openCursor();r.onsuccess=()=>{const c=r.result;if(c){if(typeof c.key==='string'&&c.key.startsWith(prefix+':'))c.delete();c.continue()}}})}
async function load(scope,pass,head){
 if(!head||!uuid(head.generation)||typeof head.envelope!=='string')throw Error('Missing local vault');
 const base=generationKey(scope,head.generation),manifest=await openOfflineVault(head.envelope,pass,base+':manifest');
 if(manifest.format!==3||!Number.isSafeInteger(manifest.bytes)||manifest.bytes<1||manifest.parts!==Math.ceil(manifest.bytes/chunkBytes))throw Error('Invalid vault manifest');
 const bytes=new Uint8Array(manifest.bytes);let offset=0;
 for(let i=0;i<manifest.parts;i++){const k=base+':'+i,part=await openOfflineVault(await get(k),pass,k),a=atob(part.data);if(a.length>chunkBytes||offset+a.length>bytes.length)throw Error('Invalid vault chunk');for(let j=0;j<a.length;j++)bytes[offset+j]=a.charCodeAt(j);offset+=a.length}
 if(offset!==bytes.length)throw Error('Incomplete vault');return JSON.parse(new TextDecoder().decode(bytes));
}
export function localVaultPresent(scope){try{return localStorage.getItem(scope)!==null}catch{return true}}
export async function readLocalVault(scope,pass){
 const raw=localStorage.getItem(scope);if(raw===null)return null;
 const head=await get(active(scope));if(head)return load(scope,pass,head);
 if(raw===marker)throw Error('Local encrypted vault unavailable; do not overwrite');
 return openOfflineVault(raw,pass,scope);
}
// Caller holds the scope's Web Lock. New chunks are staged, the active pointer
// changes only when all encryption and writes complete, then the prior generation
// may be removed. A failed quota write leaves the previous generation untouched.
export async function writeLocalVault(scope,pass,value,{present=true,beforeCommit=async()=>{}}={}){
 const previousMarker=localStorage.getItem(scope),previous=await get(active(scope)),g=crypto.randomUUID(),base=generationKey(scope,g),bytes=new TextEncoder().encode(JSON.stringify(value)),parts=Math.ceil(bytes.length/chunkBytes);
 if(previousMarker===null&&present)localStorage.setItem(scope,marker);
 try{
  for(let i=0;i<parts;i++){const k=base+':'+i;await put(k,await sealOfflineVault({data:encode(bytes.subarray(i*chunkBytes,(i+1)*chunkBytes))},pass,k))}
  const envelope=await sealOfflineVault({format:3,bytes:bytes.length,parts},pass,base+':manifest');
  await beforeCommit();await put(active(scope),{generation:g,envelope});
 }catch(err){await purge(base).catch(()=>{});if(previousMarker===null&&present)localStorage.removeItem(scope);throw err}
 // Keep the old encrypted legacy marker if replacing it unexpectedly fails.
 // Reads prefer the committed IndexedDB generation; no old draft is discarded.
 if(present){try{localStorage.setItem(scope,marker)}catch{}}else localStorage.removeItem(scope);
 if(previous&&uuid(previous.generation)&&previous.generation!==g)await purge(generationKey(scope,previous.generation)).catch(()=>{});
}
// Explicit user-directed deletion of a snapshot, not pending queue entries.
export async function eraseLocalVault(scope){localStorage.removeItem(scope);await del(active(scope));await purge(scope+':generation')}
export async function withLocalVaultLock(scope,fn){if(!navigator.locks?.request)throw Error('Exclusive local storage unavailable');return navigator.locks.request(scope,{mode:'exclusive'},fn)}
