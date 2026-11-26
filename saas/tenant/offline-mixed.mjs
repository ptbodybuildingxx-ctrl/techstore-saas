// Integer conversion of store-approved rates captured while connected.
import {tr} from '../design/i18n.mjs';
const uuid=v=>typeof v==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(v);
const int=(v,a,b)=>Number.isSafeInteger(v)&&v>=a&&v<=b;
const currency=v=>['SYP','USD','EUR'].includes(v);
export function validateMixedRates(v,identity={}){
 if(!v||v.version!==1||!uuid(v.store)||!uuid(v.actor)||!currency(v.currency)||!Number.isFinite(Date.parse(v.capturedAt))||['store','actor','currency'].some(k=>identity[k]!==undefined&&identity[k]!==v[k])||!Array.isArray(v.rates)||v.rates.length<1||v.rates.length>3||new Set(v.rates.map(r=>r?.currency)).size!==v.rates.length)throw Error('Invalid FX snapshot');
 for(const r of v.rates){if(!r||!currency(r.currency)||!int(r.numerator,1,1000000000000)||!int(r.denominator,1,1000000000000))throw Error('Invalid FX rate');if(r.currency===v.currency){if(r.rate_id!==null||r.numerator!==1||r.denominator!==1||r.expires_at!==null)throw Error('Invalid invoice rate')}else if(!uuid(r.rate_id)||!Number.isFinite(Date.parse(r.expires_at))||Date.parse(r.expires_at)<=Date.parse(v.capturedAt)||Date.parse(r.expires_at)>Date.parse(v.capturedAt)+86400000)throw Error('Invalid FX expiration')}
 if(!v.rates.some(r=>r.currency===v.currency))throw Error('Missing invoice currency');return v;
}
const fresh=(v,now=Date.now())=>!!v&&Number.isFinite(Date.parse(v.capturedAt))&&now-Date.parse(v.capturedAt)>=-60000&&now-Date.parse(v.capturedAt)<=86400000;
export function usableMixedRates(snapshot,now=Date.now()){if(snapshot?.role!=='owner'||!fresh(snapshot.mixedRates,now))return [];return snapshot.mixedRates.rates.filter(r=>r.expires_at===null||Date.parse(r.expires_at)>now)}
const minor=raw=>{if(typeof raw!=='string'||!/^\d{1,12}(?:\.\d{1,2})?$/.test(raw.trim()))throw Error('Invalid tender amount');const [w,d='']=raw.trim().split('.');const n=BigInt(w)*100n+BigInt(d.padEnd(2,'0'));if(n<1n||n>100000000000000n)throw Error('Tender out of range');return n};
const fmt=(n,c)=>{const a=BigInt(n);return String(a/100n)+'.'+String(a%100n).padStart(2,'0')+' '+c};
export function captureMixedTenders(snapshot,amounts,total,now=Date.now()){
 if(!int(total,1,100000000000000))throw Error('Invalid total');
 const active=new Map(usableMixedRates(snapshot,now).map(r=>[r.currency,r])),out=[];let paid=0n;
 for(const [c,raw] of Object.entries(amounts)){
 if(!raw.trim())continue;const r=active.get(c);if(!r)throw Error('FX rate expired');
 const a=minor(raw),numerator=BigInt(r.numerator),denominator=BigInt(r.denominator),converted=(2n*a*numerator+denominator)/(2n*denominator);
 if(converted<1n||converted>100000000000000n)throw Error('Invalid converted amount');
 paid+=converted;out.push({currency:c,amount_minor:Number(a),rate_id:r.rate_id,expected_invoice_minor:Number(converted)});
 }
 if(out.length<2||out.length>3||paid!==BigInt(total))throw Error('Tenders must match net invoice');return out;
}
export function createOfflineMixedPanel({root,status,onChange}){
 let snapshot=null,rows=[];
 function set(s){snapshot=s;rows=[];root.replaceChildren();status.textContent='';if(!s?.mixedRates)return;for(const r of s.mixedRates.rates){const l=document.createElement('label'),i=document.createElement('input'),note=document.createElement('small');l.textContent=tr('المبلغ')+' '+r.currency;i.type='text';i.inputMode='decimal';i.maxLength=16;i.oninput=onChange;note.textContent=r.rate_id?tr('سعر الصرف المحفوظ')+': '+r.numerator+' / '+r.denominator+' — '+tr('صالح حتى')+': '+new Date(r.expires_at).toLocaleString():tr('عملة الفاتورة');l.append(i,note);root.append(l);rows.push({r,i})}}
 function clear(){set(null)}
 function reset(){for(const {i} of rows)i.value='';status.textContent=''}
 function amounts(){return Object.fromEntries(rows.map(({r,i})=>[r.currency,i.value]))}
 function capture(total){return captureMixedTenders(snapshot,amounts(),total)}
 function paint(total,disabled){const active=new Set(usableMixedRates(snapshot).map(r=>r.currency));for(const {r,i} of rows)i.disabled=disabled||!active.has(r.currency);if(!snapshot)return false;try{const t=capture(total);status.textContent=t.map(x=>fmt(x.amount_minor,x.currency)+' = '+fmt(x.expected_invoice_minor,snapshot.currency)).join(' — ')+' · '+tr('المجموع مطابق');return true}catch{status.textContent=tr('أدخل مبالغ عملتين أو ثلاث تساوي صافي الفاتورة، ضمن صلاحية أسعار الصرف.');return false}}
 return {set,clear,reset,capture,paint,available:()=>usableMixedRates(snapshot).length>=2};
}
