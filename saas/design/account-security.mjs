// Shared account security. Tokens and TOTP secrets are held in memory only.
import {tr} from './i18n.mjs';
const id=x=>typeof x==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(x);
export function createAccountSecurity({request,token,replaceSession,rpc,requireVerifiedFactor=false}){
 async function factors(){
  const u=await request('/auth/v1/user',undefined,token(),'GET'),r=u?.factors??[];
  if(!u||!id(u.id)||!Array.isArray(r)||r.some(x=>!id(x.id)||typeof x.status!=='string'||typeof x.factor_type!=='string'))throw Error('Invalid factors');
  return r.filter(x=>x.factor_type==='totp').map(x=>({id:x.id,status:x.status,name:typeof x.friendly_name==='string'?x.friendly_name:''}));
 }
 async function enroll(){
  const r=await request('/auth/v1/factors',{factor_type:'totp',friendly_name:'TechStore '+crypto.randomUUID()},token());
  if(!id(r?.id)||typeof r.totp?.secret!=='string'||!/^[A-Z2-7]{16,128}$/i.test(r.totp.secret))throw Error('Invalid enrollment');
  return {id:r.id,secret:r.totp.secret};
 }
 async function verify(factor,code){
  if(!id(factor)||typeof code!=='string'||!/^\d{6}$/.test(code))throw Error('Invalid TOTP');
  const before=token(),c=await request('/auth/v1/factors/'+factor+'/challenge',{},before);
  if(!id(c?.id)||before!==token())throw Error('Invalid challenge');
  const result=await request('/auth/v1/factors/'+factor+'/verify',{challenge_id:c.id,code},before);
  if(before!==token())throw Error('Session changed');
  replaceSession(result);
 }
 async function remove(factor){
  if(!id(factor))throw Error('Invalid factor');
  const before=token(),all=await factors();
  if(before!==token())throw Error('Session changed');
  const chosen=all.find(f=>f.id===factor);
  if(!chosen)throw Error('Unknown factor');
  if(requireVerifiedFactor&&chosen.status==='verified'&&all.filter(f=>f.status==='verified').length<=1)throw Error('Enroll and verify a replacement authenticator first');
  await request('/auth/v1/factors/'+factor,undefined,before,'DELETE');
 }
 function canRemove(factor,all){return !requireVerifiedFactor||factor.status!=='verified'||all.filter(f=>f.status==='verified').length>1}
 async function authenticate(provider,{required=false}={}){
  const verified=(await factors()).filter(x=>x.status==='verified');
  if(!verified.length){if(required)throw Error('Administrator TOTP enrollment required');return}
  if(typeof provider!=='function')throw Error('TOTP required');
  const choice=await provider(verified);
  if(!choice||!verified.some(x=>x.id===choice.id))throw Error('TOTP cancelled');
  await verify(choice.id,choice.code);
 }
 async function sessions(){
  const r=await rpc('mt_account_sessions',{});
  if(!Array.isArray(r)||r.length>50||r.some(x=>!id(x.id)||typeof x.current!=='boolean'||typeof x.device!=='string'))throw Error('Invalid sessions');
  return r;
 }
 async function revoke(session){if(!id(session)||await rpc('mt_account_revoke_session',{p_session:session})!==true)throw Error('Revocation not confirmed')}
 return {factors,enroll,verify,remove,canRemove,authenticate,sessions,revoke};
}
export function chooseTotp(factors){
 let selected=factors[0];
 if(factors.length>1){const choice=prompt(tr('اختر رقم تطبيق المصادقة')+'\n'+factors.map((x,i)=>(i+1)+' — '+(x.name||'TOTP')).join('\n'));selected=factors[Number(choice)-1]}
 if(!selected)return null;
 const code=prompt(tr('أدخل الرمز المكون من 6 أرقام من تطبيق المصادقة'));
 return code===null?null:{id:selected.id,code:code.trim()};
}
// Reuses the existing account/settings section; no new navigation area.
export function mountAccountSecurity(root,{api,run,message}){
 const node=(tag,t)=>{const n=document.createElement(tag);if(t!==undefined)n.textContent=tr(t);return n};
 const button=(label,fn)=>{const b=node('button',label);b.type='button';b.onclick=()=>run(fn);return b};
 const list=node('div'),secret=node('p'),form=node('form'),label=node('label','رمز المصادقة'),input=node('input'),status=node('p');
 let pending=null;
 const reset=()=>{pending=null;secret.textContent='';input.value='';form.hidden=true;list.replaceChildren();status.textContent=''};
 input.autocomplete='one-time-code';input.inputMode='numeric';input.maxLength=6;input.required=true;label.append(input);
 const submit=node('button','تأكيد');submit.type='submit';form.append(label,submit,button('إلغاء',async()=>{if(pending)await api.security.remove(pending.id);pending=null;secret.textContent='';input.value='';form.hidden=true}));
 async function refresh(){
  const [factors,sessions]=await Promise.all([api.security.factors(),api.security.sessions()]);
  list.replaceChildren(node('h4','تطبيقات المصادقة'));
  for(const f of factors){const p=node('p');p.append(document.createTextNode((f.name||'TOTP')+' — '+tr(f.status==='verified'?'مفعّل':'غير مؤكد')+' '));if(api.security.canRemove(f,factors)){p.append(button('إزالة',async()=>{if(confirm(tr('إزالة تطبيق المصادقة هذا؟'))){await api.security.remove(f.id);try{await api.signOut()}finally{reset();message(tr('سجل الدخول مجدداً'))}}}))}else p.append(node('span','أضف تطبيق مصادقة بديلاً وفعّله قبل إزالة التطبيق الأخير.'));list.append(p)}
  list.append(node('h4','الجلسات الحالية'));
  for(const s of sessions){const p=node('p');p.textContent=tr(s.current?'هذه الجلسة':'جلسة أخرى')+' — '+(s.device||tr('جهاز غير معروف'))+' — '+(s.created_at||'')+' ';if(!s.current)p.append(button('إلغاء وصول الجهاز',async()=>{if(confirm(tr('إلغاء وصول هذه الجلسة إلى المنصة؟'))){await api.security.revoke(s.id);await refresh()}}));list.append(p)}
 }
 form.onsubmit=e=>{e.preventDefault();const code=input.value.trim();input.value='';run(async()=>{if(!pending)return;await api.security.verify(pending.id,code);pending=null;secret.textContent='';form.hidden=true;await refresh();status.textContent=tr('تم تفعيل المصادقة الثنائية')})};
 root.replaceChildren(node('h3','المصادقة الثنائية وإدارة الأجهزة'),node('p','إلغاء وصول الجهاز يتطلب المصادقة الثنائية ويمنع وصول الجلسة إلى المنصة.'),button('عرض التطبيقات والجلسات',refresh),button('إضافة تطبيق مصادقة',async()=>{if(pending)return;if(!confirm(tr('احتفظ بطريقة آمنة لاستعادة الوصول إلى تطبيق المصادقة.')))return;pending=await api.security.enroll();secret.textContent=pending.secret;form.hidden=false}),secret,form,status,list);
 form.hidden=true;return {reset};
}
