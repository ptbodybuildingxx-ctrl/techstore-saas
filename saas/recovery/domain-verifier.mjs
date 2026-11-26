// Trusted Node-side orchestration only. Never import into the browser bundle.
import {resolveTxt as dnsResolveTxt} from 'node:dns/promises';
import {createHash,randomUUID} from 'node:crypto';
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
function validHost(h){return typeof h==='string'&&h.length<=253&&/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(h)&&h.split('.').every(x=>x.length<=63&&!x.startsWith('-')&&!x.endsWith('-'))&&/^[a-z][a-z0-9-]{1,62}$/.test(h.split('.').at(-1))&&!/(^|\.)(localhost|local|internal|test|invalid|example|onion|github\.io|supabase\.co|supabase\.in)$/.test(h)}
export async function verifyDomain(candidate,{resolveTxt=dnsResolveTxt,verifyHosting,activate}={}){
 const {storeId,id,hostname,proof,state}=candidate??{};
 if(!uuid.test(storeId)||!uuid.test(id)||!uuid.test(proof)||!validHost(hostname)||state!=='pending')throw Error('Invalid pending domain');
 if(typeof verifyHosting!=='function'||typeof activate!=='function')throw Error('Trusted hosting adapter required');
 const dnsName='_techstore.'+hostname,dnsValue='techstore-verification='+proof;
 const records=await resolveTxt(dnsName);
 if(!Array.isArray(records)||records.length>128||!records.every(r=>Array.isArray(r)&&r.length<=32&&r.every(s=>typeof s==='string'&&s.length<=255)))throw Error('Invalid DNS response');
 if(!records.some(r=>r.join('')===dnsValue))throw Error('DNS proof missing');
 const nonce=randomUUID();
 // Adapter must query the configured hosting provider and verify the tenant-specific HTTPS challenge with valid TLS.
 // No user-supplied URL is fetched by this module.
 const attestation=await verifyHosting(Object.freeze({storeId,hostname,nonce}));
 if(!attestation||attestation.storeId!==storeId||attestation.hostname!==hostname||attestation.nonce!==nonce||attestation.mappingVerified!==true||attestation.tlsVerified!==true||attestation.challengeVerified!==true)throw Error('Hosting verification failed');
 const evidence=createHash('sha256').update(JSON.stringify({version:1,storeId,id,hostname,dnsName,dnsValue,nonce,mappingVerified:true,tlsVerified:true,challengeVerified:true})).digest('hex');
 if(await activate({p_store:storeId,p_id:id,p_host:hostname,p_proof:proof,p_evidence:evidence})!==true)throw Error('Domain activation rejected');
 return {hostname,storeId,evidence};
}
