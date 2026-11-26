// Offline-only recovery artifact preflight. No database or Storage writes, no network, no release evidence.
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {createReadStream} from 'node:fs';
import {lstat,mkdir,mkdtemp,readFile,realpath,readdir,rm,stat} from 'node:fs/promises';
import {join,resolve,relative,isAbsolute} from 'node:path';
import {fileURLToPath} from 'node:url';
import {extractRecovery} from './bundle.mjs';
import {normalizeInventory} from './table-inventory.mjs';
const repo=fileURLToPath(new URL('../..',import.meta.url));
const expected='mezsyzdieqmqulddcrtg';
const assert=(ok,msg)=>{if(!ok)throw Error(msg)};
const hex=(x,n)=>typeof x==='string'&&new RegExp('^[a-f0-9]{'+n+'}$').test(x);
const inside=(a,b)=>{const r=relative(a,b);return r===''||(!r.startsWith('..')&&!isAbsolute(r))};
function tar(args){
 return new Promise((resolve,reject)=>{
  const child=spawn('tar',args,{stdio:['ignore','pipe','ignore'],shell:false,env:{PATH:process.env.PATH,LC_ALL:'C'}});
  let size=0;const parts=[];const timeout=setTimeout(()=>child.kill('SIGKILL'),3600000);
  child.stdout.on('data',chunk=>{size+=chunk.length;if(size>32000000)child.kill('SIGKILL');else parts.push(chunk)});
  child.on('error',()=>{clearTimeout(timeout);reject(Error('tar unavailable'))});
  child.on('close',code=>{clearTimeout(timeout);if(code===0)resolve(Buffer.concat(parts).toString('utf8'));else reject(Error('Archive operation failed'))});
 });
}
async function archive(path,destination,kind){
 const rows=(await tar(['-tvf',path,'--numeric-owner','--quoting-style=escape'])).trimEnd().split('\n');
 const allowedDb=new Set(['roles.sql','schema.sql','data.sql','managed-schema-review.sql']);
 const names=new Set();
 for(const row of rows){
  const match=/^[-d][rwxStTs-]{9}\s+\d+\/\d+\s+\d+\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?\s+(\S+)$/.exec(row);assert(match,'Unexpected archive listing');const name=match[1],clean=name.startsWith('./')?name.slice(2):name;
  if(kind==='storage'&&name==='./'&&row[0]==='d')continue;
  assert(row[0]==='-'&&!names.has(clean)&&(kind==='db'?allowedDb.has(clean):clean==='inventory.json'||hex(clean,64)),'Unsafe or unexpected archive member');
  names.add(clean);
 }
 assert(kind==='db'?names.size===4:names.has('inventory.json')&&names.size<=100001,'Incomplete archive');
 await mkdir(destination,{mode:0o700});
 await tar(['-xf',path,'-C',destination,'--no-same-owner','--no-same-permissions','--no-overwrite-dir']);
 const actual=await readdir(destination);
 assert(actual.length===names.size&&actual.every(x=>names.has(x)),'Unexpected extracted members');
 for(const name of actual){const p=join(destination,name),s=await lstat(p);assert(s.isFile()&&!s.isSymbolicLink()&&await realpath(p)===p,'Nonregular extracted artifact')}
 return names;
}
async function json(path,limit){const s=await stat(path);assert(s.size>0&&s.size<=limit,'Invalid JSON artifact size');return JSON.parse(await readFile(path,'utf8'))}
async function digest(path){const h=createHash('sha256');for await(const chunk of createReadStream(path))h.update(chunk);return h.digest('hex')}
export async function withVerifiedRecovery({bundle,privateRoot,key},use){
 assert(typeof use==='function','Missing verified artifact consumer');
 assert(Buffer.isBuffer(key)&&key.length===32,'Invalid recovery key');
 process.umask(0o077);privateRoot=resolve(privateRoot);bundle=resolve(bundle);
 assert(await realpath(privateRoot)===privateRoot&&!inside(repo,privateRoot)&&!inside(bundle,privateRoot)&&((await stat(privateRoot)).mode&0o077)===0,'Use private root outside checkout and bundle');
 const work=await mkdtemp(join(privateRoot,'.preflight-'));
 try{
  const extract=join(work,'extract'),database=join(work,'database'),storage=join(work,'storage');
  const evidence=await extractRecovery({out:bundle,destination:extract,key});
  const config=await json(join(extract,'config.json'),4000000);
  assert(config.version===1&&config.source_project===expected&&config.config?.source_project===expected&&hex(config.config?.application_commit,40)&&config.mode==='logical_cli_capture'&&config.consistency==='operator_confirmed_write_freeze'&&config.capturedAt===evidence.capturedAt,'Not a compatible SaaS capture');
  const db=await archive(join(extract,'database.dump'),database,'db');
  for(const name of db)assert((await stat(join(database,name))).size>0,'Empty database artifact');
  const stored=await archive(join(extract,'storage.tar'),storage,'storage');
  const index=await json(join(storage,'inventory.json'),64000000);
  assert(index.version===1&&Array.isArray(index.buckets)&&Array.isArray(index.objects)&&index.objects.length<=100000&&index.objects.length===config.storage_objects&&stored.size===index.objects.length+1,'Storage inventory mismatch');
  const bucketIds=new Set(index.buckets.map(b=>b?.id));assert(bucketIds.size===index.buckets.length&&[...bucketIds].every(b=>typeof b==='string'&&b.length>0&&b.length<=100),'Invalid bucket inventory');
  const seen=new Set();let totalBytes=0;
  for(const o of index.objects){
   assert(bucketIds.has(o.bucket)&&typeof o.name==='string'&&o.name.length<=1024&&o.name.split('/').every(x=>x&&x!=='.'&&x!=='..')&&hex(o.file,64)&&hex(o.sha256,64)&&Number.isSafeInteger(o.bytes)&&o.bytes>=0,'Invalid object inventory');
   const file=createHash('sha256').update(JSON.stringify([o.bucket,o.name])).digest('hex');
   assert(o.file===file&&stored.has(file)&&!seen.has(file),'Duplicate or missing object');seen.add(file);
   const path=join(storage,file);assert((await stat(path)).size===o.bytes&&await digest(path)===o.sha256,'Object integrity mismatch');
   totalBytes+=o.bytes;assert(Number.isSafeInteger(totalBytes),'Invalid total size');
  }
  const tableCounts=config.table_counts===undefined?null:normalizeInventory(config.table_counts);
  if(tableCounts){const count=(schema,table)=>tableCounts.find(x=>x.schema===schema&&x.table===table)?.rows;assert(count('storage','objects')===String(seen.size)&&count('storage','buckets')===String(bucketIds.size),'Storage database inventory mismatch')}
  const result={id:evidence.id,capturedAt:evidence.capturedAt,applicationCommit:config.config.application_commit,buckets:bucketIds.size,objects:seen.size,storageBytes:totalBytes,databaseInventoryPresent:tableCounts!==null,artifactsVerified:true,restoreVerified:false};
  return await use({result,database,storage,tableCounts,index});
 }finally{await rm(work,{recursive:true,force:true})}
}
export async function preflightRecovery(options){return withVerifiedRecovery(options,({result})=>result)}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 let key;
 try{const [bundle,root]=process.argv.slice(2);assert(bundle&&root&&hex(process.env.RECOVERY_KEY_HEX,64),'Private arguments required');key=Buffer.from(process.env.RECOVERY_KEY_HEX,'hex');console.log(JSON.stringify(await preflightRecovery({bundle,privateRoot:root,key})))}
 catch{console.error('Recovery preflight failed; no restore or release approval.');process.exitCode=1}
 finally{key?.fill(0)}
}
