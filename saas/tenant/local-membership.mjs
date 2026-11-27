// Read-only local pricing, calculated in integer minor units. Server confirmation is mandatory.
import {validMembershipTier} from '../design/membership.mjs';
const uuid=v=>typeof v==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(v);
const int=(v,a,b)=>Number.isSafeInteger(v)&&v>=a&&v<=b;
const current=(v,now=Date.now())=>Number.isFinite(Date.parse(v))&&now-Date.parse(v)>=-60000&&now-Date.parse(v)<=86400000;
function index(rows,check,key){if(!Array.isArray(rows))throw Error('Invalid local pricing rows');const m=new Map();for(const r of rows){if(!r||!check(r)||m.has(key(r)))throw Error('Invalid local pricing record');m.set(key(r),r)}return m}
export function validateLocalMembershipSnapshot(v,identity={}){
 if(!v||v.version!==1||!uuid(v.store)||!uuid(v.actor)||!(v.branch===null||uuid(v.branch))||!['SYP','USD','EUR'].includes(v.currency)||!Number.isFinite(Date.parse(v.capturedAt))||['store','actor','branch','currency'].some(k=>identity[k]!==undefined&&identity[k]!==v[k]))throw Error('Invalid local pricing identity');
 const terms=index(v.terms,r=>uuid(r.customer_id)&&validMembershipTier(r.tier)&&int(r.basis_points,0,5000)&&int(r.min_units,1,5000),r=>r.customer_id);
 const tiers=index(v.tiers,r=>uuid(r.product_id)&&validMembershipTier(r.tier)&&int(r.price_minor,1,100000000)&&int(r.min_units,1,100),r=>r.tier+':'+r.product_id);
 const prices=index(v.prices,r=>terms.has(r.customer_id)&&uuid(r.product_id)&&int(r.price_minor,1,100000000)&&int(r.min_units,1,100),r=>r.customer_id+':'+r.product_id);
 if(identity.ledger){const ids=new Set(identity.ledger.customers.map(x=>x.id));if([...terms.keys()].some(k=>!ids.has(k)))throw Error('Missing local customer reference')}
 return v;
}
export function localPricingFresh(v){return !!v&&current(v.capturedAt)}
export function quoteLocalMembership(snapshot,customer,lines){
 const v=snapshot?.localPrices;if(!v||!localPricingFresh(v)||!current(snapshot.capturedAt)||!uuid(customer)||!Array.isArray(lines)||lines.length<1||lines.length>100)throw Error('Local pricing snapshot unavailable');
 const term=v.terms.find(t=>t.customer_id===customer);if(!term)throw Error('No approved local membership');
 const own=new Map(v.prices.filter(p=>p.customer_id===customer).map(p=>[p.product_id,p])),tiers=new Map(v.tiers.filter(p=>p.tier===term.tier).map(p=>[p.product_id,p])),catalog=new Map(snapshot.products.map(p=>[p.id,p]));
 const prices={},seen=new Set();let total=0,gross=0,units=0;
 for(const l of lines){if(!l||!uuid(l.product_id)||seen.has(l.product_id)||!int(l.units,1,10000)||!int(l.expected_price_minor,1,100000000)||catalog.get(l.product_id)?.price!==l.expected_price_minor)throw Error('Invalid local cart');seen.add(l.product_id);
 const retail=l.expected_price_minor,eligible=p=>p&&p.min_units<=l.units&&p.price_minor<=retail,personal=own.get(l.product_id),tier=tiers.get(l.product_id),net=eligible(personal)?personal.price_minor:eligible(tier)?tier.price_minor:retail-Math.floor(retail*term.basis_points/10000);
 prices[l.product_id]=net;units+=l.units;gross+=l.units*retail;total+=l.units*net;
 }
 if(units<term.min_units||!int(total,1,100000000000000)||!int(gross,total,100000000000000))throw Error('Minimum quantity or amount');
 return {customer,price_tier:term.tier,prices,currency:v.currency,gross_minor:gross,total_minor:total,discount_minor:gross-total};
}
