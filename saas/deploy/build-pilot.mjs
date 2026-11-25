import { mkdir, copyFile, writeFile, readFile, lstat, realpath } from 'node:fs/promises';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root=fileURLToPath(new URL('../..',import.meta.url));
const out=join(root,'dist-pilot');
const allow=['saas/admin/index.html','saas/admin/admin.css','saas/admin/admin.mjs','saas/admin/api.mjs','saas/admin/config.mjs','saas/tenant/index.html','saas/tenant/tenant.mjs','saas/tenant/api.mjs'];
const allowedHost='https://mezsyzdieqmqulddcrtg.supabase.co';
const config=await readFile(join(root,'saas/admin/config.mjs'),'utf8');
if(!config.includes(allowedHost)||!/publishableKey:"sb_publishable_[A-Za-z0-9_-]{20,200}"/.test(config)||/sb_secret_|service_role\s*[:=]/i.test(config))throw Error('Unexpected pilot config');
const landing='<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'self\'; base-uri \'none\'; form-action \'none\'"><title>TechStore SaaS | Pilot</title><link rel="stylesheet" href="saas/admin/admin.css"></head><body><header><div><small>TECHSTORE SAAS</small><h1>النسخة التجريبية المشتركة</h1></div></header><main><section class="panel"><h2>بيئة اختبار غير تجارية</h2><p>لا تدخل بيانات عملاء حقيقية أو تسجل مدفوعات حقيقية. الدخول يتطلب حساباً مصرحاً به مسبقاً.</p><p><a href="saas/admin/">لوحة الإدارة المركزية</a></p><p><a href="saas/tenant/">واجهة المحل التجريبية</a></p></section></main></body></html>';
await mkdir(out,{recursive:false}); // fail rather than reuse an existing output directory
for(const path of allow){
 const src=resolve(root,path),dst=join(out,path);
 if(!(await lstat(src)).isFile()||await realpath(src)!==src)throw Error('Unexpected source file '+path);
 let content=await readFile(src,'utf8');
 if(/sb_secret_[A-Za-z0-9_-]+|jtjnbeywpfdtgohffanl|pdnbwoutesojophnrgbb/.test(content))throw Error('Protected configuration in '+path);
 await mkdir(dirname(dst),{recursive:true});
 if(path.endsWith('.html')){content=content.replace('<head>','<head><meta name="robots" content="noindex,nofollow">');await writeFile(dst,content,{flag:'wx'})}
 else await copyFile(src,dst);
}
await writeFile(join(out,'index.html'),landing,{flag:'wx'});
await writeFile(join(out,'robots.txt'),'User-agent: *\nDisallow: /\n',{flag:'wx'});
console.log('Development pilot built: '+allow.length+' allowlisted assets; no legacy application or SQL included.');
