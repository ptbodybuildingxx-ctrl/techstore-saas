begin;
-- Optional bounded free-grid placement; old published themes remain valid.
create or replace function tenant_private.valid_site(v jsonb) returns boolean language plpgsql immutable set search_path='' as $$
declare pg jsonb;bl jsonb;lay jsonb;im jsonb;dev jsonb; k text; ref text; ids text[]:='{}'; slugs text[]:='{}'; total_blocks integer:=0; pos jsonb; d text; c integer; r integer; w integer; occupied text[]; cell text;
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
  occupied:='{}';slugs:=array_append(slugs,pg->>'slug');total_blocks:=total_blocks+jsonb_array_length(pg->'blocks');
  for bl in select value from jsonb_array_elements(pg->'blocks') loop
   if jsonb_typeof(bl) is distinct from 'object' then return false;end if;
   if bl ? 'layout' then
    lay:=bl->'layout';
    if jsonb_typeof(lay) is distinct from 'object' then return false;end if;
    if (select count(*) from jsonb_object_keys(lay))<>case when lay ? 'position' then 7 else 6 end or not(lay ?& array['desktop','mobile','align','padding','image_fit','heading']) then return false;end if;
    if jsonb_typeof(lay->'desktop') is distinct from 'number' or jsonb_typeof(lay->'mobile') is distinct from 'number' or lay->>'desktop' not in ('3','4','6','8','9','12') or lay->>'mobile' not in ('6','12') or exists(select 1 from jsonb_each(lay) x where x.key not in ('desktop','mobile','position') and jsonb_typeof(x.value)<>'string') or lay->>'align' not in ('start','center','end') or lay->>'padding' not in ('compact','normal','spacious') or lay->>'image_fit' not in ('natural','square','wide') or lay->>'heading' not in ('small','normal','large') then return false;end if;
    if lay ? 'position' then
     pos:=lay->'position';
     if jsonb_typeof(pos) is distinct from 'object' then return false;end if;
     if (select count(*) from jsonb_object_keys(pos))<>4 or not(pos ?& array['desktop_column','desktop_row','mobile_column','mobile_row']) or exists(select 1 from jsonb_each(pos) x where jsonb_typeof(x.value)<>'number' or x.value#>>'{}' !~ '^[0-9]{1,2}
   end if;
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
commit;) then return false;end if;
     foreach d in array array['desktop','mobile'] loop
      c:=(pos->>(d||'_column'))::integer;r:=(pos->>(d||'_row'))::integer;w:=(lay->>d)::integer;
      if c>13-w or r>32 or ((c=0)<>(r=0)) then return false;end if;
      if c>0 then for j in c..c+w-1 loop cell:=d||':'||r||':'||j;if cell=any(occupied) then return false;end if;occupied:=array_append(occupied,cell);end loop;end if;
     end loop;
    end if;
    bl:=bl-'layout';
   end if;
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
commit;