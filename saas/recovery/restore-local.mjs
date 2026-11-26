// Actual logical restore, only into a disposable, network-disconnected local database container.
// Never connects to a hosted database. Does not install services or certify a managed-platform clone.
import {spawn} from 'node:child_process';
import {createReadStream} from 'node:fs';
import {pipeline} from 'node:stream/promises';
import {Readable} from 'node:stream';
import {mkdir,mkdtemp,rm,rename,writeFile,copyFile,lstat,realpath} from 'node:fs/promises';
import {resolve,join,relative,isAbsolute} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash,randomUUID} from 'node:crypto';
import {withVerifiedRecovery} from './preflight.mjs';
import {inventorySql,parseInventory,compareInventory} from './table-inventory.mjs';
const assert=(x,m)=>{if(!x)throw Error(m)};
const repo=fileURLToPath(new URL('../..',import.meta.url));
const inside=(a,b)=>{const r=relative(a,b);return r===''||(!r.startsWith('..')&&!isAbsolute(r))};
const dockerArgs=['--host','unix:///var/run/docker.sock'];
function docker(args,input=null){
 return new Promise((resolve,reject)=>{
  const p=spawn('docker',[...dockerArgs,...args],{stdio:[input===null?'ignore':'pipe','pipe','ignore'],env:{PATH:process.env.PATH,HOME:process.env.HOME,LC_ALL:'C'},shell:false});
  const chunks=[];let size=0,failed=false;
  const timer=setTimeout(()=>p.kill('SIGKILL'),7200000);
  p.stdout.on('data',x=>{size+=x.length;if(size>16000000)p.kill('SIGKILL');else chunks.push(x)});
  if(input!==null)pipeline(Readable.from(typeof input==='string'?[input]:input),p.stdin).catch(()=>{failed=true;p.kill('SIGKILL')});
  p.on('error',()=>{clearTimeout(timer);reject(Error('Local Docker unavailable'))});
  p.on('close',code=>{clearTimeout(timer);if(code!==0||failed)reject(Error('Local isolated command failed'));else resolve(Buffer.concat(chunks).toString('utf8'))});
 });
}
async function ensureTarget(id){
 assert(typeof id==='string'&&/^[a-f0-9]{64}$/.test(id),'Exact disposable container ID required');
 const x=JSON.parse(await docker(['inspect','--type','container',id]))[0],h=x?.HostConfig;
 assert(x?.Id===id&&x.State?.Running&&x.Config?.Labels?.['techstore.recovery']==='isolated'&&/^supabase\/postgres(?::[\w.-]+|@sha256:[a-f0-9]{64})$/.test(x.Config.Image||''),'Not an explicitly isolated Supabase database');
 assert(h?.NetworkMode==='none'&&!h.Privileged&&h.PidMode!=='host'&&h.IpcMode!=='host'&&h.UsernsMode!=='host'&&!h.Binds?.length&&!h.CapAdd?.length&&!h.Devices?.length&&!h.DeviceRequests?.length&&!Object.keys(h.PortBindings||{}).length&&Object.keys(x.NetworkSettings?.Networks||{}).every(k=>k==='none'),'Unsafe container configuration');
 for(const m of x.Mounts||[]){
  assert(m.Type==='volume'&&typeof m.Name==='string'&&/^[a-zA-Z0-9_.-]+$/.test(m.Name),'Only dedicated Docker volumes are permitted');
  const vol=JSON.parse(await docker(['volume','inspect',m.Name]))[0];
  assert(vol?.Driver==='local'&&vol.Labels?.['techstore.recovery']==='isolated'&&!Object.keys(vol.Options||{}).length,'Not a dedicated recovery volume');
  const users=(await docker(['ps','-a','--no-trunc','--filter','volume='+m.Name,'--format','{{.ID}}'])).trim().split('\n').filter(Boolean);
  assert(users.length===1&&users[0]===id,'Recovery volume is shared');
 }
}
const psql=(id,args,input=null)=>docker(['exec',...(input===null?[]:['-i']),id,'psql','-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-h','/var/run/postgresql','-U','postgres','-d','postgres',...args],input);
async function emptyTarget(id){
 const check=await psql(id,['-c',"select (to_regnamespace('tenant_private') is null and to_regnamespace('saas_private') is null and not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and (left(c.relname,3)='mt_' or left(c.relname,5)='saas_' or left(c.relname,3)='ts_')) and to_regclass('auth.users') is not null and to_regclass('storage.objects') is not null and to_regclass('storage.buckets') is not null and not exists(select 1 from auth.users) and not exists(select 1 from storage.objects) and not exists(select 1 from storage.buckets))::text"]);
 assert(check.trim()==='true','Target must be a fresh initialized database, never an existing store');
}
async function* logicalSql(database){
 for(const name of ['roles.sql','schema.sql']){for await(const chunk of createReadStream(join(database,name)))yield chunk;yield '\n'}
 yield '\nSET session_replication_role = replica;\n';
 for await(const chunk of createReadStream(join(database,'data.sql')))yield chunk;
 yield '\nSET session_replication_role = origin;\n';
}
async function fileDigest(path){const h=createHash('sha256');for await(const c of createReadStream(path))h.update(c);return h.digest('hex')}
export async function restoreLocal({bundle,privateRoot,key,containerId,confirmation}){
 process.umask(0o077);privateRoot=resolve(privateRoot);bundle=resolve(bundle);
 assert(!inside(repo,privateRoot)&&!inside(bundle,privateRoot)&&await realpath(privateRoot)===privateRoot,'Invalid private work root');
 const s=await lstat(privateRoot);assert(s.isDirectory()&&(s.mode&0o077)===0,'Private work root required');
 return withVerifiedRecovery({bundle,privateRoot,key},async({result,database,storage,tableCounts,index})=>{
  assert(confirmation==='restore:'+result.id+':'+containerId&&tableCounts!==null,'Explicit reviewed bundle and target confirmation and captured inventory required');
  await ensureTarget(containerId);await emptyTarget(containerId);
  // Storage bytes are restored locally by content hash; inventory preserves exact original object names.
  const stage=await mkdtemp(join(privateRoot,'.restore-pending-')),out=join(privateRoot,'restored-'+result.id+'-'+randomUUID());
  try{
   const files=join(stage,'objects');await mkdir(files,{mode:0o700});
   for(const o of index.objects){const target=join(files,o.file);await copyFile(join(storage,o.file),target);assert((await lstat(target)).size===o.bytes&&await fileDigest(target)===o.sha256,'Restored file mismatch')}
   await writeFile(join(stage,'inventory.json'),JSON.stringify(index),{flag:'wx',mode:0o600});
   await ensureTarget(containerId);await emptyTarget(containerId);
   // Official logical restore order; managed-schema-review.sql is NEVER executed automatically.
   await psql(containerId,['--single-transaction','--file','-'],logicalSql(database));
   const actual=parseInventory(await psql(containerId,['--file','-'],inventorySql));
   assert(compareInventory(tableCounts,actual),'Restored table inventory or RLS metadata differs; quarantine target');
   const evidence={id:result.id,applicationCommit:result.applicationCommit,containerId,databaseRestored:true,tableInventoryMatched:true,storageFilesRestored:true,storageObjects:result.objects,storageBytes:result.storageBytes,managedPlatformRestored:false,restoreVerified:false,releaseAuthorized:false};
   await writeFile(join(stage,'local-restore-evidence.json'),JSON.stringify(evidence,null,2),{flag:'wx',mode:0o600});
   await rename(stage,out);return {...evidence,privateOutput:out};
  }finally{await rm(stage,{recursive:true,force:true})}
 });
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 let key;
 try{const [bundle,privateRoot,containerId]=process.argv.slice(2),raw=process.env.RECOVERY_KEY_HEX;assert(bundle&&privateRoot&&containerId&&/^[a-f0-9]{64}$/.test(raw||''),'Private arguments required');key=Buffer.from(raw,'hex');const r=await restoreLocal({bundle,privateRoot,key,containerId,confirmation:process.env.RECOVERY_RESTORE_CONFIRM});delete r.privateOutput;console.log(JSON.stringify(r))}
 catch{console.error('Local restore not verified. Keep target quarantined; never retry on the same restored database. No release evidence.');process.exitCode=1}
 finally{key?.fill(0)}
}
