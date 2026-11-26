// Read-only exact per-table counts and RLS metadata; no row contents in evidence.
export const inventorySql=String.raw`
SELECT format('SELECT jsonb_build_object(''schema'', %L, ''table'', %L, ''rows'', count(*)::text, ''rls'', %L::boolean, ''forceRls'', %L::boolean, ''policies'', %L::integer)::text FROM %I.%I;',
 n.nspname,c.relname,c.relrowsecurity,c.relforcerowsecurity,
 (SELECT count(*) FROM pg_catalog.pg_policy p WHERE p.polrelid=c.oid),n.nspname,c.relname)
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind IN ('r','p') AND (
 n.nspname IN ('tenant_private','saas_private') OR
 n.nspname='public' AND (left(c.relname,3)='mt_' OR left(c.relname,5)='saas_') OR
 n.nspname='auth' AND c.relname IN ('users','identities','mfa_factors','sessions','refresh_tokens') OR
 n.nspname='storage' AND c.relname IN ('buckets','objects'))
ORDER BY n.nspname,c.relname
\gexec
`;
export function normalizeInventory(rows){
 if(!Array.isArray(rows)||!rows.length||rows.length>2000)throw Error('Invalid table inventory');
 const seen=new Set(),result=rows.map(r=>{
  if(!r||!['tenant_private','saas_private','public','auth','storage'].includes(r.schema)||typeof r.table!=='string'||!/^[a-z_][a-z0-9_]{0,62}$/.test(r.table)||typeof r.rows!=='string'||!/^(0|[1-9]\d*)$/.test(r.rows)||typeof r.rls!=='boolean'||typeof r.forceRls!=='boolean'||!Number.isSafeInteger(r.policies)||r.policies<0)throw Error('Invalid table evidence');
  const key=r.schema+'.'+r.table;if(seen.has(key))throw Error('Duplicate table evidence');seen.add(key);
  return {schema:r.schema,table:r.table,rows:r.rows,rls:r.rls,forceRls:r.forceRls,policies:r.policies};
 });
 if(!seen.has('tenant_private.workspaces')||!seen.has('public.saas_stores')||!seen.has('auth.users')||!seen.has('storage.objects')||!seen.has('storage.buckets'))throw Error('Incomplete SaaS inventory');
 return result.sort((a,b)=>(a.schema+'.'+a.table).localeCompare(b.schema+'.'+b.table,'en'));
}
export function parseInventory(output){return normalizeInventory(output.trim().split('\n').filter(Boolean).map(line=>JSON.parse(line)))}
export function compareInventory(expected,actual){return JSON.stringify(normalizeInventory(expected))===JSON.stringify(normalizeInventory(actual))}
