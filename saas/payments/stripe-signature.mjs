// Offline Stripe snapshot signature verifier. Not a live webhook handler.
// A verified signature alone is NOT proof of an eligible paid invoice.
import {createHmac,createHash,timingSafeEqual} from 'node:crypto';
export function verifyStripeSnapshot({raw,signature,secret,liveMode,apiVersion,now=Date.now()}){
 if(!Buffer.isBuffer(raw)||raw.length<2||raw.length>1048576||typeof signature!=='string'||signature.length>4096||typeof secret!=='string'||!secret.startsWith('whsec_')||secret.length<16||typeof liveMode!=='boolean'||typeof apiVersion!=='string'||!apiVersion||!Number.isFinite(now))throw Error('Invalid webhook input');
 const parts=signature.split(',').map(x=>x.trim().split('='));
 if(parts.some(x=>x.length!==2))throw Error('Invalid signature header');
 const ts=parts.filter(x=>x[0]==='t').map(x=>x[1]),sigs=parts.filter(x=>x[0]==='v1').map(x=>x[1]);
 if(ts.length!==1||!/^\d{1,12}$/.test(ts[0])||sigs.length<1||sigs.length>10||Math.abs(now/1000-Number(ts[0]))>300)throw Error('Stale or invalid signature');
 const mac=createHmac('sha256',secret).update(ts[0]+'.').update(raw).digest();
 if(!sigs.some(x=>/^[0-9a-f]{64}$/i.test(x)&&timingSafeEqual(mac,Buffer.from(x,'hex'))))throw Error('Signature mismatch');
 let event;try{event=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(raw))}catch{throw Error('Invalid webhook JSON')}
 if(!event||event.object!=='event'||typeof event.id!=='string'||!/^evt_[A-Za-z0-9_]+$/.test(event.id)||event.livemode!==liveMode||event.api_version!==apiVersion||typeof event.type!=='string'||!event.data?.object)throw Error('Unexpected event identity or mode');
 return {event,evidenceSha256:createHash('sha256').update(raw).digest('hex')};
}
