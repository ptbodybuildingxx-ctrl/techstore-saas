import {buildCompatibility} from './theme.mjs';
// Bounded deterministic search, not an AI service or a performance benchmark.
export function suggestBuild(products,budget,{gpu=false}={}){
 if(!Array.isArray(products)||products.length>250||!Number.isSafeInteger(budget)||budget<1||budget>100000000000)throw Error('Invalid budget or candidate set');
 const types=['cpu','board','ram','storage','psu','case',...(gpu?['gpu']:[])],group=new Map(types.map(k=>[k,[]]));
 for(const p of products){const k=(p.specs?.type||p.profile?.type||'').trim().toLowerCase();if(group.has(k)&&p.available!==false&&Number.isSafeInteger(p.price_minor)&&p.price_minor>0&&p.price_minor<=budget)group.get(k).push(p)}
 const missing=types.filter(k=>!group.get(k).length);if(missing.length)return {items:[],missing,examined:0,total:null,compatibility:null};
 for(const [k,items] of group){items.sort((a,b)=>a.price_minor-b.price_minor||a.id.localeCompare(b.id));group.set(k,items.slice(0,5))}
 const minima=types.map(k=>group.get(k)[0].price_minor),remaining=types.map((_,i)=>minima.slice(i).reduce((n,x)=>n+x,0));
 let best=null,examined=0;const chosen=[];
 function visit(i,total){if(i===types.length){examined++;const c=buildCompatibility(chosen);if(c.warnings.length||c.missing.length)return;const score=[c.unknown.length,total];if(!best||score[0]<best.score[0]||score[0]===best.score[0]&&score[1]<best.score[1])best={score,items:[...chosen],total,compatibility:c};return}if(total+remaining[i]>budget)return;for(const p of group.get(types[i])){if(total+p.price_minor>budget)break;chosen.push(p);visit(i+1,total+p.price_minor);chosen.pop()}}
 visit(0,0);return best?{items:best.items,total:best.total,compatibility:best.compatibility,missing:[],examined}:{items:[],missing:[],examined,total:null,compatibility:null};
}
