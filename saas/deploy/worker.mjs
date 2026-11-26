// Allowlisted operational assets; tenant authority remains with Supabase RPCs and RLS.
export function createWorker(files,commit){
 const headers={'X-Robots-Tag':'noindex, nofollow','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','X-Frame-Options':'DENY','Content-Security-Policy':"frame-ancestors 'none'",'Cache-Control':'no-store','Permissions-Policy':'camera=(), microphone=(), geolocation=()','X-TechStore-Commit':commit};
 const types={html:'text/html; charset=utf-8',css:'text/css; charset=utf-8',mjs:'text/javascript; charset=utf-8',txt:'text/plain; charset=utf-8'};
 const valid=s=>typeof s==='string'&&/^[a-z][a-z0-9-]{2,39}$/.test(s);
 return {async fetch(request){
  const u=new URL(request.url);if(!['GET','HEAD'].includes(request.method))return new Response('Method not allowed',{status:405,headers:{...headers,Allow:'GET, HEAD'}});
  let p=u.pathname;
  const redirect=path=>{u.pathname=path;return new Response(null,{status:308,headers:{...headers,Location:u.toString()}})};
  const aliases={'/admin':'/saas/admin/','/admin/':'/saas/admin/','/tenant':'/saas/tenant/','/tenant/':'/saas/tenant/','/saas/admin':'/saas/admin/','/saas/tenant':'/saas/tenant/'};
  if(Object.hasOwn(aliases,p))return redirect(aliases[p]);
  const legacy=['/storefront','/storefront/','/saas/storefront','/saas/storefront/','/saas/storefront/index.html'].includes(p);
  if(legacy){const s=u.searchParams.get('shop');if(valid(s)){u.searchParams.delete('shop');return redirect('/shop/'+s+'/');}p='/404.html';}
  if(/^\/shop\/[a-z][a-z0-9-]{2,39}\/push-sw\.mjs$/.test(p))return new Response(request.method==='HEAD'?null:files['/saas/storefront/push-sw.mjs'],{headers:{...headers,'Content-Type':types.mjs}});
  const match=/^\/shop\/([a-z][a-z0-9-]{2,39})(\/?)$/.exec(p);
  if(match){if(!match[2])return redirect(p+'/');const html=files['/saas/storefront/index.html'].replace('href="../admin/admin.css"','href="/saas/admin/admin.css"').replace('src="storefront.mjs"','src="/saas/storefront/storefront.mjs"');return new Response(request.method==='HEAD'?null:html,{headers:{...headers,'Content-Type':types.html}});}
  if(p.endsWith('/'))p+='index.html';let status=200;if(!Object.hasOwn(files,p)||p==='/404.html'){p='/404.html';status=404;}
  return new Response(request.method==='HEAD'?null:files[p],{status,headers:{...headers,...(p==='/saas/tenant/index.html'?{'Permissions-Policy':'camera=(self), microphone=(), geolocation=()'}:{}),'Content-Type':types[p.split('.').pop()]||'text/plain; charset=utf-8'}});
 }};
}
