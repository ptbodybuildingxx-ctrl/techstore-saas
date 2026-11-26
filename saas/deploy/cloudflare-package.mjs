// Deterministic allowlisted operational package for the existing Workers deployment.
export const sourcePaths=Object.freeze(["saas/admin/index.html","saas/admin/admin.css","saas/admin/admin.mjs","saas/admin/api.mjs","saas/admin/config.mjs","saas/tenant/index.html","saas/tenant/tenant.mjs","saas/tenant/api.mjs","saas/tenant/operations.mjs","saas/tenant/offline-queue.mjs","saas/storefront/index.html","saas/storefront/api.mjs","saas/storefront/storefront.mjs","saas/storefront/push.mjs","saas/storefront/push-sw.mjs","saas/design/theme.mjs","saas/design/i18n.mjs","saas/design/portal-locale.mjs","saas/design/build-suggestions.mjs","saas/design/site.mjs","saas/design/workspace.mjs","saas/deploy/portal.html"]);
export function packageWorker(sources,routing,commit){
 if(!/^[a-f0-9]{40}$/.test(commit))throw Error('Exact commit SHA required');
 const files=Object.create(null);
 for(const path of sourcePaths){const s=sources[path];if(typeof s!=='string'||!s.length||/sb_secret_[\w-]+|jtjnbeywpfdtgohffanl|pdnbwoutesojophnrgbb/.test(s))throw Error('Invalid source '+path);files[path==='saas/deploy/portal.html'?'/index.html':'/'+path]=s;}
 if(!files['/index.html'].includes('class="portal-choices"')||!files['/saas/admin/index.html'].includes('id="workspaceNav"')||!files['/saas/tenant/index.html'].includes('id="workspaceNav"'))throw Error('Operational interfaces missing');
 files['/404.html']='<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8"><title>TechStore | الصفحة غير موجودة</title><link rel="stylesheet" href="/saas/admin/admin.css"><main><h1>الصفحة أو المتجر غير متاح</h1></main></html>';
 files['/robots.txt']='User-agent: *\nDisallow: /\n';
 if(typeof routing!=='string'||!routing.includes('export function createWorker'))throw Error('Routing missing');
 return {files,modules:{'worker.mjs':"import files from './assets.mjs';\nimport {createWorker} from './routing.mjs';\nexport default createWorker(files,'"+commit+"');\n",'routing.mjs':routing,'assets.mjs':'export default Object.freeze('+JSON.stringify(files)+');\n'},config:{name:'techstore-saas',main:'worker.mjs',compatibility_date:'2026-11-23',workers_dev:true}};
}
