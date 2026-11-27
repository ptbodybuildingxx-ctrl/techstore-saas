// Scheduled worker. No arbitrary paths, caller-supplied service keys, or logs of payloads.
// Authenticated pull: the private scheduler key authorizes one bounded claim; job tokens never traverse pg_net.
const expected='https://mezsyzdieqmqulddcrtg.supabase.co';
const key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const url=Deno.env.get('SUPABASE_URL')?.replace(/\/$/,'');
const hex=/^[0-9a-f]{64}$/;
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const response=(status:number)=>new Response(null,{status,headers:{'Cache-Control':'no-store'}});
async function rpc(name:string,body:Record<string,unknown>){
 const r=await fetch(expected+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:key!,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify(body),redirect:'error',signal:AbortSignal.timeout(20000)});
 if(!r.ok)throw Error('RPC failed');return await r.json();
}
async function bounded(r:ReadableStream<Uint8Array>,limit:number){
 const reader=r.getReader(),out=new Uint8Array(limit);let n=0;
 try{while(true){const {done,value}=await reader.read();if(done)break;if(n+value.byteLength>limit)throw Error('File exceeds reservation');out.set(value,n);n+=value.byteLength}if(n!==limit)throw Error('File length differs');return out}
 finally{await reader.cancel().catch(()=>{});reader.releaseLock()}
}
function base64(bytes:Uint8Array){let out='';for(let i=0;i<bytes.length;i+=24576)out+=btoa(String.fromCharCode(...bytes.subarray(i,i+24576)));return out}
Deno.serve(async(req)=>{
 if(req.method!=='POST'||url!==expected||!key)return response(404);
 let token='',claimed=false;
 try{
  // Reject oversized or chunked requests before parsing. Scheduler sends tiny JSON.
  const length=Number(req.headers.get('content-length'));if(!Number.isSafeInteger(length)||length<1||length>256||!req.body)return response(400);
  const bytes=await bounded(req.body,length),body=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  if(!body||Object.keys(body).length!==1||typeof body.scheduler_key!=='string'||!hex.test(body.scheduler_key))return response(403);
  const next=await rpc('mt_backup_media_next',{p_key:body.scheduler_key});
  if(next?.status==='denied')return response(403);
  if(['idle','busy','rate_limited'].includes(next?.status))return response(204);
  if(next?.status!=='claimed'||!hex.test(next.token)||!next.job)throw Error('Invalid claim');
  token=next.token;const job=next.job;claimed=true;
  if(!uuid.test(job.store)||!uuid.test(job.asset)||job.path!==job.store+'/'+job.asset+'.jpg'||!Number.isSafeInteger(job.bytes)||job.bytes<12||job.bytes>2000000)throw Error('Bad reservation');
  const r=await fetch(expected+'/storage/v1/object/authenticated/saas-design-originals/'+job.path,{headers:{apikey:key,Authorization:'Bearer '+key},redirect:'error',cache:'no-store',signal:AbortSignal.timeout(45000)});
  if(!r.ok||!r.body)throw Error('Storage read failed');
  const file=await bounded(r.body,job.bytes),saved=await rpc('mt_backup_media_finish',{token,body_base64:base64(file)});
  file.fill(0);return response(saved===true?204:409);
 }catch{if(claimed)await rpc('mt_backup_media_finish',{token,body_base64:null}).catch(()=>{});return response(503)}
});
