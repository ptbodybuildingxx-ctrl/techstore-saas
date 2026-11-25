import {serveMedia,boundedBytes} from './handler.mjs';
const origin=Deno.env.get('SUPABASE_URL'),key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
if(origin!=='https://mezsyzdieqmqulddcrtg.supabase.co'||!key)throw Error('Unexpected media environment');
const headers={apikey:key,Authorization:'Bearer '+key};
Deno.serve(req=>serveMedia(req,{
 async lookup(shop,image){const r=await fetch(origin+'/rest/v1/rpc/mt_service_public_original',{method:'POST',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify({p_slug:shop,p_image:image}),redirect:'error',signal:AbortSignal.timeout(4000)});return r.ok?await r.json():null},
 async read(path){return boundedBytes(await fetch(origin+'/storage/v1/object/authenticated/saas-design-originals/'+path,{headers,redirect:'error',signal:AbortSignal.timeout(5000)}))}
}));
