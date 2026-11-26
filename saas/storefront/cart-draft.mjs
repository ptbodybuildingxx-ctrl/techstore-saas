// Explicit per-tab public cart draft; no credentials, contact data, coupons or pending order IDs.
const key='techstore.shop.cart-draft.v1';
const shop=x=>typeof x==='string'&&/^[a-z][a-z0-9-]{2,39}$/.test(x);
const currency=x=>['SYP','USD','EUR'].includes(x);
const id=x=>typeof x==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(x);
function valid(r){return !!r&&r.version===1&&shop(r.shop)&&currency(r.currency)&&Array.isArray(r.lines)&&r.lines.length>=1&&r.lines.length<=50&&r.lines.every(x=>id(x.id)&&Number.isSafeInteger(x.units)&&x.units>=1&&x.units<=100&&Number.isSafeInteger(x.price)&&x.price>=1&&x.price<=100000000)&&new Set(r.lines.map(x=>x.id)).size===r.lines.length}
export function readCartDraft(storage){try{const raw=(storage??globalThis.sessionStorage).getItem(key);if(!raw||raw.length>10000)return null;const r=JSON.parse(raw);return valid(r)?r:null}catch{return null}}
export function saveCartDraft(shop,currency,lines,storage){const r={version:1,shop,currency,lines:lines.map(x=>({id:x.product_id,units:x.units,price:x.expected_price_minor}))};if(!valid(r))throw Error('Invalid cart draft');(storage??globalThis.sessionStorage).setItem(key,JSON.stringify(r))}
export function clearCartDraft(storage){try{(storage??globalThis.sessionStorage).removeItem(key)}catch{}}
export async function restoreCartDraft(api,shop,currency,draft){
 if(!valid(draft)||draft.shop!==shop||draft.currency!==currency)throw Error('Different shop or currency');
 const lines=[];let changed=0,unavailable=0;
 for(let i=0;i<draft.lines.length;i+=5){const batch=draft.lines.slice(i,i+5);const products=await Promise.all(batch.map(x=>api.product(shop,currency,x.id)));for(let j=0;j<batch.length;j++){const p=products[j],old=batch[j];if(!p||p.available!==true){unavailable++;continue}if(old.price!==p.price_minor)changed++;lines.push({product_id:p.id,units:old.units,expected_price_minor:p.price_minor,name:p.name})}}
 return {lines,changed,unavailable}
}
