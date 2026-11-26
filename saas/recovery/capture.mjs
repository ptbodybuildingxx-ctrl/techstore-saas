// Run only on a private, independently provisioned recovery host. Never in a browser or CI with live credentials.
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,copyFile,rm,stat,realpath,lstat,rename} from 'node:fs/promises';
import {createWriteStream,createReadStream} from 'node:fs';
import {Readable} from 'node:stream';
import {pipeline} from 'node:stream/promises';
import {createHash,randomUUID} from 'node:crypto';
import {join,resolve,relative,isAbsolute} from 'node:path';
import {fileURLToPath} from 'node:url';
import {packRecovery,verifyRecovery} from './bundle.mjs';
import {replicateRecovery} from './replicate.mjs';
const repo=fileURLToPath(new URL('../..',import.meta.url));
const expected='mezsyzdieqmqulddcrtg';
const assert=(ok,msg)=>{if(!ok)throw Error(msg)};
const inside=(a,b)=>{const r=relative(a,b);return r===''||(!r.startsWith('..')&&!isAbsolute(r))};
function run(cmd,args,{env=process.env,output=false,cwd}={}){
 return new Promise((resolve,reject)=>{const child=spawn(cmd,args,{env,cwd,stdio:['ignore',output?'pipe':'ignore','ignore'],shell:false});let chunks=[],size=0;
 const timer=setTimeout(()=>child.kill('SIGKILL'),3600000);
 if(output)child.stdout.on('data',c=>{size+=c.length;if(size>16000000)child.kill('SIGKILL');else chunks.push(c)});
 child.on('error',()=>{clearTimeout(timer);reject(Error(cmd+' unavailable'))});
 child.on('close',code=>{clearTimeout(timer);if(code!==0)reject(Error(cmd+' failed'));else resolve(Buffer.concat(chunks).toString('utf8'))});
 });
}
function checkSource(url){const u=new URL(url);assert(u.protocol==='postgresql:'&&u.port==='5432'&&u.pathname==='/postgres'&&u.searchParams.get('sslmode')==='require'&&!!u.password&&((u.hostname==='db.'+expected+'.supabase.co'&&decodeURIComponent(u.username)==='postgres')||(u.hostname.endsWith('.pooler.supabase.com')&&decodeURIComponent(u.username)==='postgres.'+expected)),'Only the dedicated SaaS source project is permitted');return u}
async function inventory(env){
 const q="select jsonb_build_object('saas',to_regclass('tenant_private.workspaces') is not null and to_regclass('public.ts_workspace') is null,'buckets',(select coalesce(jsonb_agg(to_jsonb(b) order by id),'[]') from storage.buckets b),'objects',(select coalesce(jsonb_agg(jsonb_build_object('bucket',bucket_id,'name',name,'id',id,'updated_at',updated_at,'metadata',metadata) order by bucket_id,name),'[]') from storage.objects))::text";
 const x=JSON.parse(await run('psql',['-X','-A','-t','-v','ON_ERROR_STOP=1','-c',q],{env,output:true}));
 assert(x.saas===true&&Array.isArray(x.buckets)&&Array.isArray(x.objects)&&x.objects.length<=100000,'Invalid source inventory');return x;
}
async function capture(){
 process.umask(0o077);
 const {RECOVERY_ROOT,RECOVERY_DB_URL,RECOVERY_SERVICE_KEY,RECOVERY_KEY_HEX,RECOVERY_CONFIG_FILE,RECOVERY_WRITE_FREEZE,RECOVERY_MIRROR_ROOT}=process.env;
 assert(RECOVERY_WRITE_FREEZE==='confirmed'&&RECOVERY_ROOT&&RECOVERY_CONFIG_FILE&&RECOVERY_DB_URL&&RECOVERY_SERVICE_KEY&&/^[a-f0-9]{64}$/.test(RECOVERY_KEY_HEX||''),'Missing private configuration or write freeze confirmation');
 checkSource(RECOVERY_DB_URL);
 const root=resolve(RECOVERY_ROOT),cfg=resolve(RECOVERY_CONFIG_FILE);
 assert(await realpath(root)===root&&!inside(repo,root)&&!inside(repo,cfg)&&(await lstat(cfg)).isFile()&&await realpath(cfg)===cfg,'Use private regular paths outside checkout');
 assert(((await stat(root)).mode&0o077)===0&&((await stat(cfg)).mode&0o077)===0,'Private root and config permissions required');
 // No local key, DB URL or service key is written to the bundle or console.
 const key=Buffer.from(RECOVERY_KEY_HEX,'hex'),lock=join(root,'.capture-lock');
 await mkdir(lock,{mode:0o700});let work,staged;
 const cleanEnv={...process.env,PGDATABASE:RECOVERY_DB_URL,PGCONNECT_TIMEOUT:'20'};delete cleanEnv.RECOVERY_KEY_HEX;delete cleanEnv.RECOVERY_SERVICE_KEY;delete cleanEnv.RECOVERY_DB_URL;
 try{
 work=await mkdtemp(join(root,'.capture-'));const db=join(work,'db'),objects=join(work,'objects');await mkdir(db,{mode:0o700});await mkdir(objects,{mode:0o700});
 const capturedAt=new Date().toISOString(),before=await inventory(cleanEnv);
 for(const [file,args] of [['roles.sql',['--role-only']],['schema.sql',[]],['data.sql',['--data-only','--use-copy','-x','storage.buckets_vectors','-x','storage.vector_indexes']]]){
 await run('supabase',['db','dump','--db-url',RECOVERY_DB_URL,'-f',join(db,file),...args],{env:cleanEnv});assert((await stat(join(db,file))).size>0,'Empty database artifact');
 }
 // Capture managed schema definitions for review; do not replay blindly into another project.
 await run('pg_dump',['--schema-only','--schema=auth','--schema=storage','--no-owner','--no-privileges','--file',join(db,'managed-schema-review.sql')],{env:cleanEnv});
 await run('tar',['-cf',join(work,'database.dump'),'-C',db,'roles.sql','schema.sql','data.sql','managed-schema-review.sql'],{env:cleanEnv});
 const index=[];
 for(const item of before.objects){
 assert(typeof item.bucket==='string'&&typeof item.name==='string'&&item.name.length<=1024&&item.bucket.length<=100,'Invalid storage identity');
 const segments=[item.bucket,...item.name.split('/')];assert(segments.every(x=>x&&x!=='.'&&x!=='..'),'Unsupported object path');
 const name=createHash('sha256').update(JSON.stringify([item.bucket,item.name])).digest('hex'),path=join(objects,name);
 const response=await fetch('https://'+expected+'.supabase.co/storage/v1/object/authenticated/'+segments.map(encodeURIComponent).join('/'),{headers:{apikey:RECOVERY_SERVICE_KEY,Authorization:'Bearer '+RECOVERY_SERVICE_KEY},redirect:'error',signal:AbortSignal.timeout(180000)});
 assert(response.ok&&response.body,'Storage object capture failed');await pipeline(Readable.fromWeb(response.body),createWriteStream(path,{flags:'wx',mode:0o600}));
 const bytes=(await stat(path)).size,declared=Number(item.metadata?.size);assert(!Number.isFinite(declared)||bytes===declared,'Storage size changed');const hash=createHash('sha256');for await(const chunk of createReadStream(path))hash.update(chunk);index.push({...item,file:name,bytes,sha256:hash.digest('hex')});
 }
 const after=await inventory(cleanEnv);assert(JSON.stringify(before)===JSON.stringify(after),'Storage inventory changed; capture rejected');
 await writeFile(join(objects,'inventory.json'),JSON.stringify({version:1,buckets:before.buckets,objects:index}),{flag:'wx',mode:0o600});
 await run('tar',['-cf',join(work,'storage.tar'),'-C',objects,'.'],{env:cleanEnv});
 const config=JSON.parse(await readFile(cfg,'utf8'));assert(config&&config.source_project===expected&&config.application_commit&&/^[a-f0-9]{40}$/.test(config.application_commit),'Invalid config snapshot');
 await writeFile(join(work,'config.json'),JSON.stringify({version:1,capturedAt,source_project:expected,mode:'logical_cli_capture',config,storage_objects:index.length,consistency:'operator_confirmed_write_freeze'}),{flag:'wx',mode:0o600});
 const name='backup-'+capturedAt.replace(/[:.]/g,'-')+'-'+randomUUID(),out=join(root,name);staged=join(root,'.pending-'+name);await packRecovery({source:work,out:staged,key,capturedAt});const verified=await verifyRecovery({out:staged,key});await rename(staged,out);staged=null;
 let mirror=null;
 if(RECOVERY_MIRROR_ROOT){try{mirror=await replicateRecovery({source:out,mirrorRoot:RECOVERY_MIRROR_ROOT,key})}catch{console.error('Local encrypted backup preserved; replica failed.');throw Error('Replica failed')}}
 console.log(JSON.stringify({id:verified.id,capturedAt,storageObjects:index.length,integrityVerified:true,mirrorVerified:!!mirror,distinctMirrorFilesystem:mirror?.distinctFilesystem??null,restoreVerified:false}));
 }finally{if(staged)await rm(staged,{recursive:true,force:true});if(work)await rm(work,{recursive:true,force:true});await rm(lock,{recursive:true,force:true});key.fill(0)}
}
capture().catch(()=>{console.error('Recovery capture failed. No successful backup or restore evidence recorded.');process.exitCode=1});
