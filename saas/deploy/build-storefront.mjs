import {mkdir,readFile,writeFile,lstat,realpath} from 'node:fs/promises';
import {join,resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../..',import.meta.url)),out=join(root,'dist-storefront');
const assets=['saas/admin/admin.css','saas/admin/config.mjs','saas/storefront/api.mjs','saas/storefront/storefront.mjs','saas/storefront/push.mjs','saas/design/theme.mjs','saas/design/i18n.mjs','saas/design/account-security.mjs','saas/design/build-suggestions.mjs','saas/design/local-assistant.mjs','saas/design/generative-assistant.mjs','saas/design/site.mjs'];
async function source(path){const src=resolve(root,path);if(!(await lstat(src)).isFile()||await realpath(src)!==src)throw Error('Unexpected source '+path);const c=await readFile(src,'utf8');if(/sb_secret_[A-Za-z0-9_-]+|jtjnbeywpfdtgohffanl|pdnbwoutesojophnrgbb/.test(c))throw Error('Protected configuration');return c}
const config=await source('saas/admin/config.mjs');
if(!config.includes('https://mezsyzdieqmqulddcrtg.supabase.co')||!/publishableKey:"sb_publishable_[A-Za-z0-9_-]{20,200}"/.test(config)||/customDomainRouting|customerAuthEnabled|service_role\s*[:=]/.test(config))throw Error('Unexpected configuration; review build');
const routed=config.replace('Object.freeze({','Object.freeze({customDomainRouting:true,customerAuthEnabled:false,');
if(routed===config)throw Error('Routing flag not applied');
const html=(await source('saas/storefront/index.html')).replace('href="../admin/admin.css"','href="/saas/admin/admin.css"').replace('src="storefront.mjs"','src="/saas/storefront/storefront.mjs"');
if(!html.includes('href="/saas/admin/admin.css"')||!html.includes('src="/saas/storefront/storefront.mjs"'))throw Error('Unexpected entry point');
const files=await Promise.all(assets.map(async path=>[path,path.endsWith('/config.mjs')?routed:await source(path)]));
await mkdir(out,{recursive:false});
for(const [path,content] of [...files,['index.html',html],['robots.txt','User-agent: *\nDisallow: /\n']]){const dest=join(out,path);await mkdir(dirname(dest),{recursive:true});await writeFile(dest,content,{flag:'wx'})}
console.log('Storefront-only development build; hostname verification mandatory; no administration pages.');
