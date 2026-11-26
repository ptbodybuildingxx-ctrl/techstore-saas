// Pack and verify already-captured backup artifacts. Does not access a database or restore it.
import {createCipheriv,createDecipheriv,createHash,randomBytes,randomUUID} from 'node:crypto';
import {createReadStream,createWriteStream} from 'node:fs';
import {lstat,realpath,mkdir,readFile,writeFile,rm,readdir} from 'node:fs/promises';
import {resolve,join,dirname,relative,isAbsolute} from 'node:path';
import {fileURLToPath} from 'node:url';
import {Transform,Writable} from 'node:stream';
import {pipeline} from 'node:stream/promises';
const names=['database.dump','storage.tar','config.json'];
const repo=fileURLToPath(new URL('../..',import.meta.url));
const inside=(a,b)=>{const r=relative(a,b);return r===''||(!r.startsWith('..')&&!isAbsolute(r))};
const hex=(v,n)=>typeof v==='string'&&new RegExp('^[a-f0-9]{'+n+'}$').test(v);
const assert=(ok,msg)=>{if(!ok)throw Error(msg)};
function keyCheck(key){assert(Buffer.isBuffer(key)&&key.length===32,'Recovery key must be 32 bytes')}
async function regular(path){const s=await lstat(path);assert(s.isFile()&&!s.isSymbolicLink()&&await realpath(path)===path,'Nonregular artifact');return s}
function meter(){const hash=createHash('sha256');let bytes=0;const stream=new Transform({transform(chunk,enc,cb){hash.update(chunk);bytes+=chunk.length;cb(null,chunk)}});return {stream,result:()=>({sha256:hash.digest('hex'),bytes})}}
function aad(id,name){return Buffer.from('techstore-recovery-v1:'+id+':'+name)}
async function sealFile(src,dst,key,id,name){const nonce=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key,nonce);cipher.setAAD(aad(id,name));const plain=meter(),encrypted=meter();await pipeline(createReadStream(src),plain.stream,cipher,encrypted.stream,createWriteStream(dst,{flags:'wx',mode:0o600}));return {name,nonce:nonce.toString('hex'),tag:cipher.getAuthTag().toString('hex'),plain:plain.result(),encrypted:encrypted.result()}}
export async function packRecovery({source,out,key,capturedAt}){
 keyCheck(key);assert(typeof capturedAt==='string'&&Number.isFinite(Date.parse(capturedAt))&&Date.parse(capturedAt)<=Date.now(),'Invalid capture time');
 source=resolve(source);out=resolve(out);assert(await realpath(source)===source&&await realpath(dirname(out))===dirname(out)&&!inside(source,out)&&!inside(repo,out),'Use a new private output directory outside repository and source');
 for(const n of names)await regular(join(source,n));
 const id=randomUUID();await mkdir(out,{mode:0o700});
 try{const files=[];for(const n of names)files.push(await sealFile(join(source,n),join(out,n+'.enc'),key,id,n));
 const manifest={version:1,id,shard:'shared-001',capturedAt,mode:'supplied_artifacts_only',files};
 const nonce=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key,nonce);cipher.setAAD(aad(id,'manifest'));const data=Buffer.concat([cipher.update(JSON.stringify(manifest)),cipher.final()]);await writeFile(join(out,'manifest.enc.json'),JSON.stringify({id,nonce:nonce.toString('hex'),tag:cipher.getAuthTag().toString('hex'),data:data.toString('base64')}),{flag:'wx',mode:0o600});return {id,mode:manifest.mode,files:files.length};
 }catch(e){await rm(out,{recursive:true,force:true});throw e}
}
async function inspectRecovery({out,key,destination=null}){
 keyCheck(key);out=resolve(out);assert(await realpath(out)===out,'Nonregular directory');
 const expected=[...names.map(n=>n+'.enc'),'manifest.enc.json'].sort();assert(JSON.stringify((await readdir(out)).sort())===JSON.stringify(expected),'Unexpected files');
 const mpath=join(out,'manifest.enc.json'),stat=await regular(mpath);assert(stat.size<50000,'Manifest too large');
 const m=JSON.parse(await readFile(mpath,'utf8'));assert(m&&typeof m.id==='string'&&/^[0-9a-f-]{36}$/.test(m.id)&&hex(m.nonce,24)&&hex(m.tag,32)&&typeof m.data==='string','Invalid manifest envelope');
 const decipher=createDecipheriv('aes-256-gcm',key,Buffer.from(m.nonce,'hex'));decipher.setAAD(aad(m.id,'manifest'));decipher.setAuthTag(Buffer.from(m.tag,'hex'));const manifest=JSON.parse(Buffer.concat([decipher.update(Buffer.from(m.data,'base64')),decipher.final()]).toString('utf8'));
 assert(manifest.version===1&&manifest.id===m.id&&manifest.shard==='shared-001'&&manifest.mode==='supplied_artifacts_only'&&Array.isArray(manifest.files)&&manifest.files.length===names.length&&Number.isFinite(Date.parse(manifest.capturedAt)),'Invalid manifest');
 for(const [i,f] of manifest.files.entries()){
  assert(f.name===names[i]&&hex(f.nonce,24)&&hex(f.tag,32)&&[f.plain,f.encrypted].every(x=>x&&hex(x.sha256,64)&&Number.isSafeInteger(x.bytes)&&x.bytes>=0),'Invalid artifact metadata');
  const path=join(out,f.name+'.enc');await regular(path);const enc=meter(),plain=meter(),d=createDecipheriv('aes-256-gcm',key,Buffer.from(f.nonce,'hex'));d.setAAD(aad(m.id,f.name));d.setAuthTag(Buffer.from(f.tag,'hex'));
  const sink=destination===null?new Writable({write(c,e,cb){cb()}}):createWriteStream(join(destination,f.name),{flags:'wx',mode:0o600});
  await pipeline(createReadStream(path),enc.stream,d,plain.stream,sink);assert(JSON.stringify(enc.result())===JSON.stringify(f.encrypted)&&JSON.stringify(plain.result())===JSON.stringify(f.plain),'Artifact digest mismatch');
 }
 return {id:m.id,mode:'integrity_verified_only',restoreVerified:false,capturedAt:manifest.capturedAt,files:names.length};
}
export async function verifyRecovery({out,key}){return inspectRecovery({out,key})}
export async function extractRecovery({out,destination,key}){
 keyCheck(key);out=resolve(out);destination=resolve(destination);
 assert(await realpath(out)===out&&await realpath(dirname(destination))===dirname(destination)&&!inside(out,destination)&&!inside(repo,destination)&&!inside(destination,out),'Use a new isolated private extraction directory');
 await mkdir(destination,{mode:0o700});
 try{const verified=await inspectRecovery({out,key,destination});return {...verified,mode:'artifacts_extracted_only',restoreVerified:false}}
 catch(error){await rm(destination,{recursive:true,force:true});throw error}
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 try{const value=process.env.RECOVERY_KEY_HEX;assert(hex(value,64),'Set RECOVERY_KEY_HEX privately');const key=Buffer.from(value,'hex');const [cmd,a,b,c]=process.argv.slice(2);const r=cmd==='pack'?await packRecovery({source:a,out:b,key,capturedAt:c}):cmd==='verify'?await verifyRecovery({out:a,key}):cmd==='extract'?await extractRecovery({out:a,destination:b,key}):(()=>{throw Error('Use pack SOURCE OUT CAPTURED_AT, verify OUT, or extract OUT NEW_PRIVATE_DIRECTORY')})();console.log(JSON.stringify(r));}catch{console.error('Recovery operation failed; no restore authorization.');process.exitCode=1}
}
