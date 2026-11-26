// Deterministic, browser-local assistant. No model, credentials, prompt storage, or network calls.
const digits=s=>s.replace(/[٠-٩۰-۹]/g,c=>String(c.charCodeAt(0)-(c<='٩'?0x660:0x6f0)));
const normalize=s=>digits(s.normalize('NFKC')).replace(/[\u064b-\u065f\u0670]/g,'').replace(/[أإآ]/g,'ا').replace(/ة/g,'ه').replace(/ى/g,'ي').replace(/\u066b/g,'.').toLowerCase().trim();
const currencies={USD:/\busd\b|\bdollars?\b|دولار|\$/,EUR:/\beur\b|\beuros?\b|يورو|€/,SYP:/\bsyp\b|ليره\s*سوريه|ل\.?\s*س\.?|syrian pounds?/};
export function assistantIntent(question,currency){
 if(typeof question!=='string'||question.length>240||!['USD','SYP','EUR'].includes(currency))throw Error('Invalid question');
 const q=normalize(question);if(!q)return {kind:'help'};
 const named=Object.entries(currencies).filter(([,pattern])=>pattern.test(q)).map(([k])=>k);
 if(named.length>1||named.length===1&&named[0]!==currency)return {kind:'currency'};
 const build=/\b(build|pc|computer|budget|gaming|workstation)\b|تجميع|ميزاني|كمبيوتر|حاسوب|العاب|مونتاج|جهاز/.test(q);
 const compat=/\b(compatible|compatibility|fit|socket)\b|توافق|متوافق|مقبس|يناسب/.test(q);
 // Explicit budgets only; do not infer from a model number or multiple numeric values.
 if(build&&!compat){
  if(/[\d][,\u066c][\d]/.test(q)||/[\d]\s*(الف|مليون|thousand|million|[km]\b)/.test(q))return {kind:'budget'};
  const numbers=q.match(/\d+(?:\.\d+)?/g)||[];
  if(numbers.length!==1||!/^\d{1,9}(?:\.\d{1,2})?$/.test(numbers[0])||!/ميزاني|سعر|بسعر|ضمن|بحدود|بقيمة|بقيمه|تحت|مبلغ|\bbudget\b|\bunder\b|\bfor\b|\bwithin\b|[$€]|دولار|يورو|ليره|\busd\b|\bsyp\b|\beur\b/.test(q))return {kind:'budget'};
  const [whole,frac='']=numbers[0].split('.'),budget=Number(whole)*100+Number(frac.padEnd(2,'0'));
  if(!Number.isSafeInteger(budget)||budget<1||budget>100000000000)return {kind:'budget'};
  return {kind:'build',budget,gpu:/\bgpu\b|\bgaming\b|\bgraphics\b|العاب|مونتاج|كرت شاش|بطاقه رسوم/.test(q)&&!/\b(no|without)\s+(gpu|graphics)\b|بدون\s+(كرت|بطاقه)/.test(q)};
 }
 if(compat)return {kind:'compatibility'};
 if(/\b(delivery|shipping|pickup|payment)\b|توصيل|شحن|دفع|استلام/.test(q))return {kind:'delivery'};
 if(/\b(repair|warranty|track)\b|صيانه|ضمان|تتبع|متابعه/.test(q))return {kind:'tracking'};
 return {kind:'help'};
}
export function assistantPartLabel(code){
 const map={cpu:'المعالج',board:'اللوحة الأم',ram:'الذاكرة',gpu:'كرت الشاشة',storage:'التخزين',psu:'مزود الطاقة',case:'الصندوق',socket:'مقبس المعالج',form:'حجم اللوحة والصندوق',power:'قدرة الطاقة'};
 return map[code]||null;
}
