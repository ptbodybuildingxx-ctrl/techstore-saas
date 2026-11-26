// Deploy separately as SaaS notification-dispatch, never the original techstore-push.
// @ts-nocheck
import webpush from 'npm:web-push@3.6.7';
import {dispatch,emailPayload} from './dispatch.mjs';
const env=k=>Deno.env.get(k)||'';
const base=env('SUPABASE_URL'),service=env('SUPABASE_SERVICE_ROLE_KEY'),token=env('SAAS_NOTIFICATION_WORKER_TOKEN');
const origin=env('SAAS_NOTIFICATION_ORIGIN');
async function rpc(name,body){const r=await fetch(base+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:service,Authorization:'Bearer '+service,'Content-Type':'application/json'},body:JSON.stringify(body),redirect:'error',signal:AbortSignal.timeout(10000)});if(!r.ok)throw Error('Queue RPC failed');return r.json()}
async function equal(a,b){const enc=new TextEncoder(),x=new Uint8Array(await crypto.subtle.digest('SHA-256',enc.encode(a))),y=new Uint8Array(await crypto.subtle.digest('SHA-256',enc.encode(b)));let diff=0;for(let i=0;i<x.length;i++)diff|=x[i]^y[i];return diff===0}
Deno.serve(async req=>{const reply=(r,status=200)=>Response.json(r,{status,headers:{'Cache-Control':'no-store'}});if(req.method!=='POST')return reply({error:'Method'},405);
 if(!/^[a-f0-9]{64}$/.test(token)||!await equal(req.headers.get('x-worker-token')||'',token))return reply({error:'Denied'},403);
 if(!base||!service||!origin||!/^https:\/\/[a-z0-9.-]+(?::443)?$/.test(origin))return reply({error:'Disabled'},503);
 const channel=new URL(req.url).searchParams.get('channel');try{
 if(channel==='email'&&env('SAAS_EMAIL_ENABLED')==='true'&&env('SAAS_RESEND_KEY')&&env('SAAS_EMAIL_FROM'))return reply(await dispatch({channel,rpc,send:async j=>{const r=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:'Bearer '+env('SAAS_RESEND_KEY'),'Content-Type':'application/json','Idempotency-Key':'techstore/'+j.store+'/'+j.id},body:JSON.stringify(emailPayload(j,env('SAAS_EMAIL_FROM'),origin)),redirect:'error',signal:AbortSignal.timeout(8000)});return r.status}}));
 if(channel==='push'&&env('SAAS_PUSH_ENABLED')==='true'&&env('SAAS_VAPID_PUBLIC')&&env('SAAS_VAPID_PRIVATE'))return reply(await dispatch({channel,rpc,send:async j=>{const r=await webpush.sendNotification({endpoint:j.endpoint,keys:{p256dh:j.p256dh,auth:j.auth}},JSON.stringify({title:'TechStore',body:'لديك تحديث جديد في حسابك.',tag:'ts-'+j.id}),{TTL:3600,timeout:8000,vapidDetails:{subject:origin,publicKey:env('SAAS_VAPID_PUBLIC'),privateKey:env('SAAS_VAPID_PRIVATE')}});return r.statusCode}}));
 return reply({error:'Channel disabled'},503)
 }catch{return reply({error:'Dispatch unconfirmed'},502)}});
