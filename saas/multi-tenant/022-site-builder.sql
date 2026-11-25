begin;
-- Backward-compatible bounded page builder. All published media is intentionally public.
alter function tenant_private.valid_theme(jsonb) rename to valid_theme_v2;
create function tenant_private.valid_site(v jsonb) returns boolean language plpgsql immutable set search_path='' as $$
declare pg jsonb;bl jsonb;im jsonb;dev jsonb; k text; ref text; ids text[]:='{}'; slugs text[]:='{}'; total_blocks integer:=0;
begin
 if jsonb_typeof(v) is distinct from 'object' or octet_length(v::text)>240000 then return false;end if;
 if (select count(*) from jsonb_object_keys(v))<>5 or not(v ?& array['pages','images','product_images','desktop','mobile']) then return false;end if;
 if jsonb_typeof(v->'pages') is distinct from 'array' or jsonb_typeof(v->'images') is distinct from 'array' or jsonb_typeof(v->'product_images') is distinct from 'object' then return false;end if;
 if jsonb_array_length(v->'pages')>8 or jsonb_array_length(v->'images')>12 or (select count(*) from jsonb_object_keys(v->'product_images'))>50 then return false;end if;
 for im in select value from jsonb_array_elements(v->'images') loop
  if jsonb_typeof(im) is distinct from 'object' then return false;end if;
  if (select count(*) from jsonb_object_keys(im))<>3 or not(im ?& array['id','alt','data']) or exists(select 1 from jsonb_each(im) x where jsonb_typeof(x.value)<>'string') then return false;end if;
  if im->>'id' !~ '^[a-z0-9-]{1,40}$' or im->>'id'=any(ids) or length(im->>'alt') not between 1 and 100 or length(im->>'data')>18000 or length(im->>'data')%4<>0 or im->>'data' !~ '^/9j/[A-Za-z0-9+/]*={0,2}$' then return false;end if;
  ids:=array_append(ids,im->>'id');
 end loop;
 for k,ref in select key,value#>>'{}' from jsonb_each(v->'product_images') loop
  if length(k) not between 1 and 100 or jsonb_typeof(v->'product_images'->k) is distinct from 'string' or not(ref=any(ids)) then return false;end if;
 end loop;
 for pg in select value from jsonb_array_elements(v->'pages') loop
  if jsonb_typeof(pg) is distinct from 'object' then return false;end if;
  if (select count(*) from jsonb_object_keys(pg))<>3 or not(pg ?& array['slug','title','blocks']) or jsonb_typeof(pg->'slug') is distinct from 'string' or jsonb_typeof(pg->'title') is distinct from 'string' or jsonb_typeof(pg->'blocks') is distinct from 'array' then return false;end if;
  if pg->>'slug' !~ '^[a-z][a-z0-9-]{0,39}$' or pg->>'slug'=any(slugs) or length(btrim(pg->>'title')) not between 1 and 80 or jsonb_array_length(pg->'blocks')>12 then return false;end if;
  slugs:=array_append(slugs,pg->>'slug');total_blocks:=total_blocks+jsonb_array_length(pg->'blocks');
  for bl in select value from jsonb_array_elements(pg->'blocks') loop
   if jsonb_typeof(bl) is distinct from 'object' then return false;end if;
   if (select count(*) from jsonb_object_keys(bl))<>6 or not(bl ?& array['type','title','body','image','action','tone']) or exists(select 1 from jsonb_each(bl) x where jsonb_typeof(x.value)<>'string') then return false;end if;
   if bl->>'type' not in ('banner','text','image','cta') or length(btrim(bl->>'title')) not between 1 and 100 or length(bl->>'body')>600 or (bl->>'image'<>'' and not(bl->>'image'=any(ids))) or (bl->>'type'='image' and bl->>'image'='') or bl->>'action' not in ('none','catalog') or bl->>'tone' not in ('accent','surface') then return false;end if;
  end loop;
 end loop;
 if total_blocks>32 then return false;end if;
 foreach k in array array['desktop','mobile'] loop
  dev:=v->k;
  if jsonb_typeof(dev) is distinct from 'object' then return false;end if;
  if (select count(*) from jsonb_object_keys(dev))<>3 or not(dev ?& array['layout','columns','density']) or jsonb_typeof(dev->'layout') is distinct from 'string' or jsonb_typeof(dev->'density') is distinct from 'string' or jsonb_typeof(dev->'columns') is distinct from 'number' then return false;end if;
  if dev->>'layout' not in ('list','cards') or dev->>'density' not in ('compact','normal','spacious') or dev->>'columns' not in ('1','2','3','4') or (k='mobile' and dev->>'columns' not in ('1','2')) then return false;end if;
 end loop;
 return true;
end $$;
create function tenant_private.valid_theme(v jsonb) returns boolean language plpgsql immutable set search_path='' as $$
begin
 if jsonb_typeof(v) is distinct from 'object' then return false;end if;
 return coalesce(tenant_private.valid_theme_v2(v-'site'),false) and (not(v ? 'site') or coalesce(tenant_private.valid_site(v->'site'),false));
end $$;
alter table tenant_private.design_versions drop constraint design_versions_theme_check;
alter table tenant_private.design_versions add constraint design_versions_theme_check check(tenant_private.valid_theme(theme));
revoke all on function tenant_private.valid_theme(jsonb),tenant_private.valid_theme_v2(jsonb),tenant_private.valid_site(jsonb) from public,anon,authenticated,service_role;
commit;