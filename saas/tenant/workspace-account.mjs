// Standalone verified account access. No store membership or administrator role is granted by signup.
import {createStorefrontApi} from '../storefront/api.mjs';
import {chooseTotp,mountAccountSecurity} from '../design/account-security.mjs';
import {tr} from '../design/i18n.mjs';
export function mountWorkspaceAccount(root,configuration){
 const api=createStorefrontApi({...configuration,customerAuthEnabled:true});
 const node=(tag,text)=>{const a=document.createElement(tag);if(text!==undefined)a.textContent=text;return a},t=(tag,x)=>node(tag,tr(x));
 const dialog=node('dialog'),status=node('p'),publicArea=node('div'),privateArea=node('div'),identity=node('code'),review=node('div'),securityRoot=node('div');status.setAttribute('role','status');let busy=false;
 const say=x=>{status.textContent=tr(x)};
 async function run(fn){if(busy)return;busy=true;try{await fn()}catch{say('لم يتم تأكيد الإجراء. تحقق من البريد وإعدادات الحساب أو أعد تسجيل الدخول.')}finally{busy=false;paint()}}
 const button=(label,fn)=>{const b=t('button',label);b.type='button';b.onclick=()=>run(fn);return b};
 const email=()=>{const x=node('input');x.type='email';x.required=true;x.maxLength=254;x.autocomplete='email';return x};
 const password=(mode='new-password')=>{const x=node('input');x.type='password';x.required=true;x.autocomplete=mode;x.maxLength=128;if(mode==='new-password')x.minLength=12;return x};
 const otp=()=>{const x=node('input');x.required=true;x.inputMode='numeric';x.pattern='[0-9]{6,10}';x.maxLength=10;x.autocomplete='one-time-code';return x};
 function form(title,fields,submit){const f=node('form');f.append(t('h4',title));for(const [label,x] of fields){const l=t('label',label);l.append(x);f.append(l)}const b=t('button',title);b.type='submit';f.append(b);f.onsubmit=e=>{e.preventDefault();if(busy)return;const values=fields.map(([,x])=>x.value);for(const [,x] of fields)if(x.type==='password'||x.autocomplete==='one-time-code')x.value='';run(()=>submit(...values))};return f}
 const security=mountAccountSecurity(securityRoot,{api,run,message:say});
 function paint(){const active=api.signedIn();publicArea.hidden=active;privateArea.hidden=!active;if(!active){identity.textContent='';review.replaceChildren();security.reset()}}
 const close=button('إغلاق',async()=>{try{if(api.signedIn())await api.signOut()}finally{dialog.close();paint();status.textContent='';for(const f of dialog.querySelectorAll('form'))f.reset()}});
 dialog.addEventListener('cancel',e=>{e.preventDefault();if(!busy)close.click()});
 publicArea.append(t('p','تسجيل الحساب لا يمنح صلاحية أي محل. بعد تأكيد البريد شارك معرّف حسابك مع المالك أو مدير المنصة. إرسال الرمز يتطلب إعداد خدمة البريد وقوالب الرموز في Supabase.'),
 form('إنشاء حساب ببريد مؤكد',[['البريد',email()],['كلمة المرور',password()],['تأكيد كلمة المرور',password()]],async(e,p,c)=>{if(p!==c)throw Error('Passwords differ');await api.signUp(e,p);say('إذا كان الإرسال متاحاً، استخدم رمز التأكيد الوارد في بريدك.')}),
 form('تأكيد البريد',[['البريد',email()],['رمز التأكيد',otp()]],async(e,c)=>{await api.confirmEmail(e,c);say('تم تأكيد البريد. يمكنك تسجيل الدخول.')}),
 form('طلب استرداد كلمة المرور',[['البريد',email()]],async e=>{await api.requestRecovery(e);say('إذا كان الحساب قابلاً للاسترداد والإرسال متاحاً فسيصل رمز الاسترداد إلى البريد.')}),
 form('تعيين كلمة مرور جديدة برمز الاسترداد',[['البريد',email()],['رمز الاسترداد',otp()],['كلمة المرور الجديدة',password()],['تأكيد كلمة المرور',password()]],async(e,c,p,again)=>{if(p!==again)throw Error('Passwords differ');await api.resetPassword(e,c,p);say('تم تحديث كلمة المرور. سجل الدخول من جديد.')}),
 form('دخول حساب الهوية',[['البريد',email()],['كلمة المرور',password('current-password')]],async(e,p)=>{await api.signIn(e,p,chooseTotp);identity.textContent=await api.verifiedIdentity();say('هذا معرّف حسابك المؤكد؛ لا تمنح مشاركته وحدها صلاحية المحل.')}));
 const req=node('input');req.required=true;req.maxLength=36;req.autocomplete='off';
 async function load(id){const r=await api.transferReview(id);review.replaceChildren();if(!r){review.append(t('p','طلب النقل غير متاح لهذا الحساب.'));return}review.append(node('h4',r.store_name),node('p',tr(r.role==='old'?'المالك الحالي':'المالك الجديد')+' — '+r.other_account),node('p',tr(({pending:'قيد الانتظار',completed:'مكتمل',cancelled:'ملغى'})[r.state])+' — '+r.expires_at),node('p',tr('موافقة المالك الحالي')+': '+tr(r.old_approved_at?'نعم':'لا')+' / '+tr('موافقة المالك الجديد')+': '+tr(r.new_approved_at?'نعم':'لا')));
 if(r.state==='pending'&&Date.parse(r.expires_at)>Date.now()){if(!r.mfa){review.append(t('p','فعّل المصادقة الثنائية وسجل الدخول مجدداً قبل اتخاذ القرار.'));return}for(const [accept,title] of [[true,'أوافق على نقل ملكية المحل'],[false,'أرفض طلب نقل الملكية']])review.append(button(title,async()=>{if(!confirm(tr(title)+' — '+r.store_name+'؟'))return;await api.transferDecide(id,accept);await load(id)}))}
 }
 privateArea.append(t('h3','معرّف حسابي المؤكد'),identity,button('تحديث المعرّف',async()=>{identity.textContent=await api.verifiedIdentity()}),t('h3','طلب نقل ملكية المحل'),form('مراجعة طلب النقل',[['معرّف طلب نقل الملكية',req]],id=>load(id.trim())),review,securityRoot,button('خروج',async()=>{await api.signOut();say('سجل الدخول مجدداً')}));
 dialog.append(t('h2','إنشاء الحساب واسترداده ونقل الملكية'),status,publicArea,privateArea,close);root.append(button('إنشاء الحساب أو استرداده أو الموافقة على نقل الملكية',async()=>{paint();if(!dialog.open)dialog.showModal()}),dialog);paint();
}
