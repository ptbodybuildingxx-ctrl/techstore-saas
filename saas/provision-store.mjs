import {readFile,readdir,mkdir,writeFile,lstat,realpath,rm} from 'node:fs/promises';
import {resolve,dirname,relative,join,isAbsolute,sep} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {buildStore,validateConfig} from './build-store.mjs';
const rootDefault=fileURLToPath(new URL('../',import.meta.url));
const manifestPath=fileURLToPath(new URL('./provisioning/backend-manifest.json',import.meta.url));
const sha256=b=>createHash('sha256').update(b).digest('hex');
const gitBlob=b=>createHash('sha1').update('blob '+b.length+'\0').update(b).digest('hex');
const ref=/^[a-z0-9]{20}$/;
const protectedBase=new Set(['jtjnbeywpfdtgohffanl','mezsyzdieqmqulddcrtg']);
const exactKeys=(obj,keys)=>obj&&typeof obj==='object'&&!Array.isArray(obj)&&Object.keys(obj).length===keys.length&&keys.every(k=>Object.hasOwn(obj,k));
export function validateProvisioning(input){
 if(!exactKeys(input,['store','target','inventory']))throw Error('Expected store, target and privately obtained project inventory');
 const store=validateConfig(input.store);
 const target=input.target,inventory=input.inventory;
 if(!exactKeys(target,['projectRef','status','newProject','publicTables','authUsers','storageObjects','storageBuckets','edgeFunctions','appliedMigrations'])||target.projectRef!==store.project||target.status!=='ACTIVE_HEALTHY'||target.newProject!==true)throw Error('Target identity or readiness mismatch');
 for(const k of ['publicTables','authUsers','storageObjects','storageBuckets','edgeFunctions','appliedMigrations'])if(target[k]!==0)throw Error('Target not empty: '+k);
 if(!exactKeys(inventory,['protectedProjects','assignedProjects','assignedOrigins','existingProjects'])||!['protectedProjects','assignedProjects','existingProjects'].every(k=>Array.isArray(inventory[k])&&inventory[k].every(x=>typeof x==='string'&&ref.test(x)))||!Array.isArray(inventory.assignedOrigins)||inventory.assignedOrigins.some(x=>typeof x!=='string'))throw Error('Invalid inventory');
 const forbidden=new Set([...protectedBase,...inventory.protectedProjects,...inventory.assignedProjects]);
 if(forbidden.has(store.project)||inventory.assignedOrigins.includes(store.storeOrigin))throw Error('Protected or assigned target');
 if(inventory.existingProjects.filter(x=>x===store.project).length!==1||[...protectedBase].some(x=>!inventory.protectedProjects.includes(x)))throw Error('Incomplete project inventory');
 // Treat every known project other than the explicitly new target as occupied.
 if(inventory.existingProjects.some(x=>x!==store.project&&!forbidden.has(x)))throw Error('Unclassified existing project');
 return store;
}
async function readRegular(root,path){
 const f=resolve(root,path),rel=relative(root,f);
 if(!rel||rel==='..'||rel.startsWith('..'+sep)||isAbsolute(rel))throw Error('Unsafe input path');
 if(!(await lstat(f)).isFile()||await realpath(f)!==f)throw Error('Non-regular backend source '+path);
 return readFile(f);
}
export async function inspectBackend(root=rootDefault){
 root=await realpath(root);
 const m=JSON.parse(await readFile(manifestPath,'utf8'));
 if(m.version!=='6.3.8'||!Array.isArray(m.files)||m.files.length!==59||new Set(m.files.map(x=>x.path)).size!==59)throw Error('Invalid pinned manifest');
 const expected=m.files.map(x=>x.path);
 const migrations=(await readdir(join(root,'supabase/migrations'),{withFileTypes:true})).map(x=>{if(!x.isFile()||!/^\d{14}_[a-z0-9_]+\.sql$/.test(x.name))throw Error('Unexpected migration '+x.name);return 'supabase/migrations/'+x.name}).sort();
 if(JSON.stringify(migrations)!==JSON.stringify(expected.filter(x=>x.startsWith('supabase/migrations/')).sort()))throw Error('Migration set changed; review and repin');
 const functions=await readdir(join(root,'supabase/functions'),{withFileTypes:true});
 if(functions.length!==3||functions.some(x=>!x.isDirectory()||!['techstore-ai','techstore-api','techstore-push'].includes(x.name)))throw Error('Unexpected Edge function set');
 for(const x of functions){const entries=await readdir(join(root,'supabase/functions',x.name),{withFileTypes:true});if(entries.length!==1||!entries[0].isFile()||entries[0].name!=='index.ts')throw Error('Unexpected Edge dependency; review and repin')}
 const files=[],findings=[];
 for(const x of m.files){
  if(!/^supabase\/(migrations\/\d{14}_[a-z0-9_]+\.sql|functions\/techstore-(ai|api|push)\/index\.ts)$/.test(x.path)||!/^[0-9a-f]{40}$/.test(x.gitBlob))throw Error('Invalid manifest entry');
  const data=await readRegular(root,x.path);
  if(gitBlob(data)!==x.gitBlob)throw Error('Backend source changed: '+x.path);
  const code=data.toString('utf8');
  if(/jtjnbeywpfdtgohffanl|mezsyzdieqmqulddcrtg|ptbodybuildingxx\.github\.io|ptbodybuildingxx-ctrl\.github\.io|https?:\/\/[a-z0-9]{20}\.supabase\.co|sb_secret_[A-Za-z0-9_-]{20,}|sb_publishable_[A-Za-z0-9_-]{20,}/i.test(code))findings.push({path:x.path,code:'embedded-project-or-key'});
  if(x.path.endsWith('.sql')&&/\b(?:cron\.schedule|net\.http_(?:post|get)|alter\s+role\s+[^;]+password|insert\s+into\s+auth\.users)\b/i.test(code))findings.push({path:x.path,code:'environment-specific-operation-review'});
  files.push({path:x.path,sha256:sha256(data),bytes:data.length,data});
 }
 return {version:m.version,sourceCommit:m.sourceCommit,files,findings};
}
async function collectFiles(dir,base=dir){
 const files=[];
 for(const e of (await readdir(dir,{withFileTypes:true})).sort((a,b)=>a.name.localeCompare(b.name))){
  const full=join(dir,e.name);
  if(e.isDirectory())files.push(...await collectFiles(full,base));
  else if(e.isFile()){const b=await readFile(full);files.push({path:relative(base,full).split(sep).join('/'),sha256:sha256(b),bytes:b.length})}
  else throw Error('Unexpected generated asset');
 }
 return files;
}
export async function prepareProvisioning(input,output,root=rootDefault){
 const config=validateProvisioning(input);root=await realpath(root);
 const dest=resolve(output),rel=relative(root,dest);
 if(rel===''||(!rel.startsWith('..'+sep)&&rel!=='..'))throw Error('Output must be outside repository');
 const backend=await inspectBackend(root);
 if(backend.findings.length)throw Error('Backend review required: '+JSON.stringify(backend.findings));
 // Create exclusively. No network, no migrations, no secrets, no automatic deployment.
 await mkdir(dest,{mode:0o700});
 try{
  const web=join(dest,'web');await buildStore(input.store,web,root);
  for(const f of backend.files){const target=join(dest,'backend',f.path);await mkdir(dirname(target),{recursive:true,mode:0o700});await writeFile(target,f.data,{flag:'wx',mode:0o600})}
  const receipt={version:backend.version,sourceCommit:backend.sourceCommit,store:config.slug,projectRef:config.project,origin:config.storeOrigin,mode:'prepared_only',deploymentAuthorized:false,migrations:backend.files.filter(x=>x.path.endsWith('.sql')).length,edgeFunctions:backend.files.filter(x=>x.path.endsWith('.ts')).length,files:await collectFiles(dest)};
  await writeFile(join(dest,'provisioning-receipt.json'),JSON.stringify(receipt,null,2)+'\n',{flag:'wx',mode:0o600});
  return receipt;
 }catch(e){await rm(dest,{recursive:true,force:true});throw e}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 const [cmd,input,out]=process.argv.slice(2);
 if(cmd==='inspect'){const r=await inspectBackend();console.log(JSON.stringify({version:r.version,sourceCommit:r.sourceCommit,migrations:r.files.filter(x=>x.path.endsWith('.sql')).length,edgeFunctions:r.files.filter(x=>x.path.endsWith('.ts')).length,findings:r.findings},null,2));if(r.findings.length)process.exitCode=1}
 else if(cmd==='prepare'&&input&&out){const r=await prepareProvisioning(JSON.parse(await readFile(input,'utf8')),out);console.log(JSON.stringify({mode:r.mode,store:r.store,migrations:r.migrations,edgeFunctions:r.edgeFunctions,files:r.files.length}))}
 else throw Error('Usage: node saas/provision-store.mjs inspect OR prepare /private/request.json /private/new-output');
}
