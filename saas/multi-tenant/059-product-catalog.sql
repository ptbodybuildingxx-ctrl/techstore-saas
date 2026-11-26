-- Catalog administration, independent of financial and inventory transactions.
begin;
create function tenant_private.valid_catalog_profile(v jsonb) returns boolean language plpgsql immutable set search_path='' as $$
begin
 if v is null or jsonb_typeof(v)<>'object' then return false;end if;
 if (select count(*) from jsonb_object_keys(v))<>9 or not (v ?& array['name_en','type','brand','category','model','variant','description','video','photos']) then return false;end if;
 if exists(select 1 from jsonb_each(v) where key<>'photos' and (jsonb_typeof(value)<>'string' or length(value#>>'{}')>case key when 'description' then 2000 when 'name_en' then 160 when 'video' then 11 when 'type' then 30 else 100 end)) then return false;end if;
 if v->>'video'<>'' and v->>'video' !~ '^[A-Za-z0-9_-]{11}$' then return false;end if;
 if jsonb_typeof(v->'photos') is distinct from 'array' then return false;end if;
 if jsonb_array_length(v->'photos')>4 then return false;end if;
 return not exists(select 1 from jsonb_array_elements(v->'photos') x where jsonb_typeof(x)<>'string' or length(x#>>'{}') not between 8 and 32000 or length(x#>>'{}')%4<>0 or x#>>'{}' !~ '^/9j/[A-Za-z0-9+/]*={0,2}$');
end $$;
alter table public.mt_products add column catalog jsonb not null default '{"name_en":"","type":"","brand":"","category":"","model":"","variant":"","description":"","video":"","photos":[]}'::jsonb check(tenant_private.valid_catalog_profile(catalog));
create table tenant_private.catalog_requests(store_id uuid not null references tenant_private.workspaces(store_id),request_id uuid not null,actor uuid not null,payload jsonb not null,result jsonb not null,created_at timestamptz not null default now(),primary key(store_id,request_id));
alter table tenant_private.catalog_requests enable row level security;
revoke all on tenant_private.catalog_requests from public,anon,authenticated,service_role;
create function tenant_private.catalog_item(p_store uuid,p_product uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 select jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'profile',p.catalog,'specs',p.specs,'listed',coalesce(l.listed,false)) into r from public.mt_products p left join tenant_private.storefront_products l on l.store_id=p.store_id and l.product_id=p.id where p.store_id=p_store and p.id=p_product;
 if not found then raise exception 'Unknown product' using errcode='22023';end if;return r;
end $$;
create function tenant_private.catalog_save(p_store uuid,p_request uuid,p_product uuid,p_name text,p_sku text,p_profile jsonb,p_specs jsonb,p_listed boolean,p_currency text,p_price bigint) returns uuid language plpgsql security definer set search_path='' as $$
declare v uuid;old tenant_private.catalog_requests%rowtype;payload jsonb;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_name is null or length(btrim(p_name)) not between 1 and 160 or p_sku is null or length(btrim(p_sku)) not between 1 and 80 or not tenant_private.valid_catalog_profile(p_profile) or not tenant_private.valid_product_specs(p_specs) or p_listed is null or (p_currency is null)<>(p_price is null) then raise exception 'Invalid product' using errcode='22023';end if;
 payload:=jsonb_build_object('id',p_product,'name',btrim(p_name),'sku',btrim(p_sku),'profile',p_profile,'specs',p_specs,'listed',p_listed,'currency',p_currency,'price',p_price);
 select * into old from tenant_private.catalog_requests where store_id=p_store and request_id=p_request;
 if found then if old.actor<>auth.uid() or old.payload is distinct from payload then raise exception 'Conflicting request' using errcode='22023';end if;return (old.result->>'id')::uuid;end if;
 if p_product is null then
 insert into public.mt_products(store_id,name,sku,catalog,specs) values(p_store,btrim(p_name),btrim(p_sku),p_profile,p_specs) returning id into v;
 else
 update public.mt_products set name=btrim(p_name),sku=btrim(p_sku),catalog=p_profile,specs=p_specs where store_id=p_store and id=p_product returning id into v;
 if not found then raise exception 'Unknown product' using errcode='22023';end if;
 end if;
 perform tenant_private.storefront_list_product(p_store,v,p_listed);
 if p_price is not null then perform tenant_private.set_currency_price(p_store,v,p_currency,p_price);end if;
 insert into tenant_private.catalog_requests values(p_store,p_request,auth.uid(),payload,jsonb_build_object('id',v),now());return v;
end $$;
create function tenant_private.catalog_bulk(p_store uuid,p_request uuid,p_products uuid[],p_action text,p_value text,p_currency text) returns jsonb language plpgsql security definer set search_path='' as $$
declare v uuid;old tenant_private.catalog_requests%rowtype;payload jsonb;r jsonb;price bigint;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_products is null or cardinality(p_products) not between 1 and 50 or (select count(distinct x) from unnest(p_products)x)<>cardinality(p_products) or p_action is null or p_action not in ('show','hide','brand','category','price') or p_value is null or length(p_value)>100 then raise exception 'Invalid bulk action' using errcode='22023';end if;
 payload:=jsonb_build_object('products',to_jsonb(p_products),'action',p_action,'value',p_value,'currency',p_currency);
 select * into old from tenant_private.catalog_requests where store_id=p_store and request_id=p_request;
 if found then if old.actor<>auth.uid() or old.payload is distinct from payload then raise exception 'Conflicting request' using errcode='22023';end if;return old.result;end if;
 if (select count(*) from public.mt_products where store_id=p_store and id=any(p_products))<>cardinality(p_products) then raise exception 'Unknown product' using errcode='22023';end if;
 if p_action='price' then if p_value !~ '^[0-9]{1,9}$' then raise exception 'Invalid price' using errcode='22023';end if;price:=p_value::bigint;end if;
 foreach v in array p_products loop
 if p_action in ('show','hide') then perform tenant_private.storefront_list_product(p_store,v,p_action='show');
 elsif p_action='price' then perform tenant_private.set_currency_price(p_store,v,p_currency,price);
 else update public.mt_products set catalog=jsonb_set(catalog,array[p_action],to_jsonb(btrim(p_value))) where store_id=p_store and id=v;end if;
 end loop;
 r:=jsonb_build_object('count',cardinality(p_products));insert into tenant_private.catalog_requests values(p_store,p_request,auth.uid(),payload,r,now());return r;
end $$;
create function tenant_private.catalog_import(p_store uuid,p_request uuid,p_rows jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare old tenant_private.catalog_requests%rowtype;x jsonb;r jsonb;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'Invalid import' using errcode='22023';end if;
 if jsonb_array_length(p_rows) not between 1 and 100 or octet_length(p_rows::text)>100000 then raise exception 'Invalid import size' using errcode='22023';end if;
 select * into old from tenant_private.catalog_requests where store_id=p_store and request_id=p_request;
 if found then if old.actor<>auth.uid() or old.payload is distinct from p_rows then raise exception 'Conflicting request' using errcode='22023';end if;return old.result;end if;
 for x in select value from jsonb_array_elements(p_rows) loop
 if jsonb_typeof(x) is distinct from 'object' or jsonb_typeof(x->'sku') is distinct from 'string' or jsonb_typeof(x->'name') is distinct from 'string' or length(btrim(x->>'sku')) not between 1 and 80 or length(btrim(x->>'name')) not between 1 and 160 or not tenant_private.valid_catalog_profile(x->'profile') then raise exception 'Invalid import row' using errcode='22023';end if;
 insert into public.mt_products(store_id,sku,name,catalog) values(p_store,btrim(x->>'sku'),btrim(x->>'name'),x->'profile');
 end loop;
 r:=jsonb_build_object('count',jsonb_array_length(p_rows));insert into tenant_private.catalog_requests values(p_store,p_request,auth.uid(),p_rows,r,now());return r;
end $$;
create or replace function tenant_private.scoped_products(p_store uuid,p_currency text,p_query text,p_after uuid,p_limit integer,p_low boolean)
returns table(store_id uuid,id uuid,sku text,name text,quantity bigint,unit_price_minor bigint,specs jsonb) language plpgsql stable security definer set search_path='' as $$
declare b uuid:=tenant_private.current_branch_scope(p_store);
begin
 if not coalesce(tenant_private.member_role(p_store) in ('owner','stock','cashier'),false) then raise exception 'Tenant access required' using errcode='42501';end if;
 if p_query is null or length(p_query)>100 or p_low is null or p_limit is null or p_limit not between 1 and 100 or (p_currency is not null and p_currency not in ('SYP','USD','EUR')) then raise exception 'Invalid query' using errcode='22023';end if;
 return query select p.store_id,p.id,p.sku,p.name,case when b is null then p.quantity else bs.units end,pp.price_minor,p.specs from public.mt_products p left join tenant_private.branch_stock bs on bs.store_id=p.store_id and bs.product_id=p.id and bs.branch_id=b left join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=p_store and (b is null or bs.branch_id=b) and (p_after is null or p.id>p_after) and (not p_low or (case when b is null then p.quantity else bs.units end)<=5) and (btrim(p_query)='' or strpos(lower(concat_ws(' ',p.name,p.sku,p.catalog->>'name_en',p.catalog->>'type',p.catalog->>'brand',p.catalog->>'category',p.catalog->>'model',p.catalog->>'variant')),lower(btrim(p_query)))>0) order by p.id limit p_limit;
end $$;

create or replace function public.mt_search_catalog(p_slug text,p_currency text,p_query text,p_after uuid default null,p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid;n text;r jsonb;
begin
 if p_slug is null or p_slug !~ '^[a-z][a-z0-9-]{2,39}$' or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_query is null or length(p_query)>100 or p_limit is null or p_limit not between 1 and 50 then raise exception 'Invalid catalog query' using errcode='22023';end if;
 select s.id,s.name into t,n from public.saas_stores s where s.slug=p_slug and tenant_private.storefront_active(s.id);
 if not found then return null;end if;
 select jsonb_build_object('name',n,'slug',p_slug,'currency',p_currency,'products',coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb)) into r from (select p.id,p.name,p.sku,pp.price_minor,p.specs,p.catalog-'photos' as profile,p.catalog->'photos'->>0 as cover from public.mt_products p join tenant_private.storefront_products l on l.store_id=p.store_id and l.product_id=p.id and l.listed join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=t and p.quantity>0 and (p_after is null or p.id>p_after) and (btrim(p_query)='' or strpos(lower(concat_ws(' ',p.name,p.sku,p.catalog->>'name_en',p.catalog->>'type',p.catalog->>'brand',p.catalog->>'category',p.catalog->>'model',p.catalog->>'variant')),lower(btrim(p_query)))>0) order by p.id limit p_limit) x;
 return r;
end $$;

create function tenant_private.public_product(p_slug text,p_currency text,p_product uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if p_currency not in ('USD','SYP','EUR') then raise exception 'Invalid currency' using errcode='22023';end if;
 select jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'price_minor',pp.price_minor,'specs',p.specs,'profile',p.catalog) into r from public.saas_stores s join public.mt_products p on p.store_id=s.id join tenant_private.storefront_products l on l.store_id=p.store_id and l.product_id=p.id and l.listed join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where s.slug=p_slug and tenant_private.storefront_active(s.id) and p.id=p_product and p.quantity>0;
 return r;
end $$;
create function public.mt_catalog_item(p_store uuid,p_product uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.catalog_item(p_store,p_product)$$;
create function public.mt_catalog_save(p_store uuid,p_request uuid,p_product uuid,p_name text,p_sku text,p_profile jsonb,p_specs jsonb,p_listed boolean,p_currency text,p_price bigint) returns uuid language sql security invoker set search_path='' as $$select tenant_private.catalog_save(p_store,p_request,p_product,p_name,p_sku,p_profile,p_specs,p_listed,p_currency,p_price)$$;
create function public.mt_catalog_bulk(p_store uuid,p_request uuid,p_products uuid[],p_action text,p_value text,p_currency text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.catalog_bulk(p_store,p_request,p_products,p_action,p_value,p_currency)$$;
create function public.mt_catalog_import(p_store uuid,p_request uuid,p_rows jsonb) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.catalog_import(p_store,p_request,p_rows)$$;
create function public.mt_public_product(p_slug text,p_currency text,p_product uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.public_product(p_slug,p_currency,p_product)$$;
revoke all on function tenant_private.valid_catalog_profile(jsonb),tenant_private.catalog_item(uuid,uuid),tenant_private.catalog_save(uuid,uuid,uuid,text,text,jsonb,jsonb,boolean,text,bigint),tenant_private.catalog_bulk(uuid,uuid,uuid[],text,text,text),tenant_private.catalog_import(uuid,uuid,jsonb),tenant_private.public_product(text,text,uuid),public.mt_catalog_item(uuid,uuid),public.mt_catalog_save(uuid,uuid,uuid,text,text,jsonb,jsonb,boolean,text,bigint),public.mt_catalog_bulk(uuid,uuid,uuid[],text,text,text),public.mt_catalog_import(uuid,uuid,jsonb),public.mt_public_product(text,text,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.catalog_item(uuid,uuid),tenant_private.catalog_save(uuid,uuid,uuid,text,text,jsonb,jsonb,boolean,text,bigint),tenant_private.catalog_bulk(uuid,uuid,uuid[],text,text,text),tenant_private.catalog_import(uuid,uuid,jsonb),public.mt_catalog_item(uuid,uuid),public.mt_catalog_save(uuid,uuid,uuid,text,text,jsonb,jsonb,boolean,text,bigint),public.mt_catalog_bulk(uuid,uuid,uuid[],text,text,text),public.mt_catalog_import(uuid,uuid,jsonb) to authenticated;
grant execute on function tenant_private.public_product(text,text,uuid),public.mt_public_product(text,text,uuid) to anon,authenticated;
commit;
