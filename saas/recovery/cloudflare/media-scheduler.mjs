// Separate cron-only worker. No public functionality or business data.
const endpoint='https://mezsyzdieqmqulddcrtg.supabase.co/functions/v1/techstore-media-backup';
export default {
 fetch(){return new Response(null,{status:404})},
 async scheduled(_event,env){
  const key=env.MEDIA_SCHEDULER_KEY;
  if(typeof key!=='string'||!/^[0-9a-f]{64}$/.test(key))throw Error('Scheduler not provisioned');
  const r=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({scheduler_key:key}),redirect:'error',cache:'no-store',signal:AbortSignal.timeout(110000)});
  // Do not log request/response bodies, secrets, or file metadata.
  await r.body?.cancel();
  if(r.status!==204&&r.status!==409)throw Error('Media scheduler request failed: '+r.status);
 }
};
