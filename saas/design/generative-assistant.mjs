// Native, already-installed browser model only. No cloud fallback, download or user data.
const kinds=new Set(['cpu','board','ram','gpu','storage','psu','case','socket','form','power']);
const opts={expectedInputs:[{type:'text',languages:['en']}],expectedOutputs:[{type:'text',languages:['en']}]};
export async function localModelReady(model=globalThis.LanguageModel){
 if(typeof model?.availability!=='function'||typeof model?.create!=='function')return false;
 try{return await model.availability(opts)==='available'}catch{return false}
}
export async function explainBuildLocally(checks,{model=globalThis.LanguageModel,signal=AbortSignal.timeout(20000)}={}){
 if(!checks||!['warnings','unknown','missing'].every(k=>Array.isArray(checks[k])&&checks[k].length<=24))throw Error('Invalid build check');
 // Only allowlisted component/check identifiers, no names, descriptions, identifiers, amounts or user questions.
 const clean=x=>typeof x==='string'&&kinds.has(x)?x:'other';
 const facts=Object.fromEntries(['warnings','unknown','missing'].map(k=>[k,checks[k].map(clean)]));
 if(!await localModelReady(model))return null;
 signal.throwIfAborted();
 let session;
 try{
  session=await model.create({...opts,signal,initialPrompts:[{role:'system',content:'You explain a deterministic PC compatibility check in English in at most 100 words. Use only supplied check categories. Do not recommend specific products, prices, or claim full compatibility. State that manufacturer verification is required.'}]});
  const result=await session.prompt('Explain these check results: '+JSON.stringify(facts),{signal});
  if(typeof result!=='string'||!result.trim())return null;
  return result.trim().slice(0,1200);
 }finally{session?.destroy()}
}
