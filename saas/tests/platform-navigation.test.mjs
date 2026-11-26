import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const root=new URL('../../',import.meta.url);
const views=[['saas/deploy/portal.html','/'],['saas/admin/index.html','/saas/admin/'],['saas/tenant/index.html','/saas/tenant/'],['saas/storefront/index.html','/saas/storefront/']];
test('all platform views link to all four routes and mark only their current page',async()=>{for(const [file,route] of views){const html=await readFile(new URL(file,root),'utf8');const nav=html.match(/<nav class="platform-nav"[^>]*>(.*?)<\/nav>/s)?.[1];assert.ok(nav,file);const links=[...nav.matchAll(/<a href="([^"]+)"([^>]*)>/g)];assert.deepEqual(links.map(m=>new URL(m[1],'https://platform.invalid'+route).pathname).sort(),views.map(v=>v[1]).sort(),file);assert.deepEqual(links.filter(m=>m[2].includes('aria-current="page"')).map(m=>new URL(m[1],'https://platform.invalid'+route).pathname),[route],file);}});
