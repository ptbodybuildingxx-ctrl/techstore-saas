// Copy only authenticated encrypted artifacts. No database access and no retention deletion.
import {copyFile,lstat,realpath,mkdir,mkdtemp,rename,rm,chmod} from 'node:fs/promises';
import {constants} from 'node:fs';
import {resolve,relative,isAbsolute,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {verifyRecovery} from './bundle.mjs';
const repo=fileURLToPath(new URL('../..',import.meta.url));
const names=['database.dump.enc','storage.tar.enc','config.json.enc','manifest.enc.json'];
const inside=(a,b)=>{const r=relative(a,b);return r===''||(!r.startsWith('..')&&!isAbsolute(r))};
async function privateDirectory(p){const s=await lstat(p);if(!s.isDirectory()||s.isSymbolicLink()||await realpath(p)!==p||(s.mode&0o077)!==0)throw Error('Private regular directory required');return s}
export async function replicateRecovery({source,mirrorRoot,key}){
 source=resolve(source);mirrorRoot=resolve(mirrorRoot);
 if(inside(repo,source)||inside(repo,mirrorRoot)||inside(source,mirrorRoot)||inside(mirrorRoot,source))throw Error('Use independent private roots outside checkout');
 const [a,b]=await Promise.all([privateDirectory(source),privateDirectory(mirrorRoot)]);
 const original=await verifyRecovery({out:source,key}),staged=await mkdtemp(join(mirrorRoot,'.pending-replica-'));
 try{
  for(const n of names){const src=join(source,n),s=await lstat(src);if(!s.isFile()||s.isSymbolicLink()||await realpath(src)!==src||(s.mode&0o077)!==0)throw Error('Invalid source artifact');const dst=join(staged,n);await copyFile(src,dst,constants.COPYFILE_EXCL);await chmod(dst,0o600)}
  const replica=await verifyRecovery({out:staged,key});
  if(replica.id!==original.id||replica.capturedAt!==original.capturedAt)throw Error('Replica mismatch');
  const out=join(mirrorRoot,'replica-'+original.id+'-'+randomUUID());
  await rename(staged,out);
  return {id:original.id,integrityVerified:true,restoreVerified:false,distinctFilesystem:a.dev!==b.dev,directory:out};
 }finally{await rm(staged,{recursive:true,force:true})}
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 let key;
 try{const [source,mirrorRoot]=process.argv.slice(2),raw=process.env.RECOVERY_KEY_HEX;if(!source||!mirrorRoot||!/^[a-f0-9]{64}$/.test(raw||''))throw Error('Private recovery configuration required');key=Buffer.from(raw,'hex');const r=await replicateRecovery({source,mirrorRoot,key});console.log(JSON.stringify({id:r.id,integrityVerified:r.integrityVerified,restoreVerified:false,distinctFilesystem:r.distinctFilesystem}));}
 catch{console.error('Replica failed; source backup not deleted.');process.exitCode=1}
 finally{key?.fill(0)}
}
