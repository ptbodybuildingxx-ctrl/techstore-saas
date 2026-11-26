-- Listed products remain discoverable when temporarily unavailable.
begin;
create function tenant_private.main_available(p_store uuid,p_product uuid) returns bigint language sql stable security definer set search_path='' as $$
 select greatest(0,p.quantity-tenant_private.branch_allocated(p_store,p_product)-coalesce((select sum(units) from tenant_private.order_reservations where store_id=p_store and product_id=p_product),0))::bigint from public.mt_products p where p.store_id=p_store and p.id=p_product
$$;
create or replace function public.mt_search_catalog(p_slug text,p_currency text,p_query text,p_after uuid default null,p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid;n text;r jsonb;
begin
 if p_slug is null or p_slug !~ '^[a-z][a-z0-9-]{2,39}$' or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_query is null or length(p_query)>100 or p_limit is null or p_limit not between 1 and 50 then raise exception 'Invalid catalog query' using errcode='22023';end if;
 select s.id,s.name into t,n from public.saas_stores s where s.slug=p_slug and tenant_private.storefront_active(s.id);
 if not found then return null;end if;
 select jsonb_build_object('name',n,'slug',p_slug,'currency',p_currency,'products',coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb)) into r from (select p.id,p.name,p.sku,pp.price_minor,p.specs,p.catalog-'photos' as profile,p.catalog->'photos'->>0 as cover,tenant_private.main_available(p.store_id,p.id)>0 as available from public.mt_products p join tenant_private.storefront_products l on l.store_id=p.store_id and l.product_id=p.id and l.listed join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=t and (p_after is null or p.id>p_after) and (btrim(p_query)='' or strpos(lower(concat_ws(' ',p.name,p.sku,p.catalog->>'name_en',p.catalog->>'type',p.catalog->>'brand',p.catalog->>'category',p.catalog->>'model',p.catalog->>'variant')),lower(btrim(p_query)))>0) order by p.id limit p_limit) x;
 return r;
end $$;


create or replace function tenant_private.public_product(p_slug text,p_currency text,p_product uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if p_currency not in ('USD','SYP','EUR') then raise exception 'Invalid currency' using errcode='22023';end if;
 select jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'price_minor',pp.price_minor,'specs',p.specs,'profile',p.catalog,'available',tenant_private.main_available(p.store_id,p.id)>0) into r from public.saas_stores s join public.mt_products p on p.store_id=s.id join tenant_private.storefront_products l on l.store_id=p.store_id and l.product_id=p.id and l.listed join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where s.slug=p_slug and tenant_private.storefront_active(s.id) and p.id=p_product;
 return r;
end $$;

create function tenant_private.catalog_facets(p_slug text,p_currency text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid;
begin
 if p_currency is null or p_currency not in ('SYP','USD','EUR') then raise exception 'Invalid currency' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug and tenant_private.storefront_active(id);
 if not found then return '[]'::jsonb;end if;
 return coalesce((select jsonb_agg(x.category order by x.category) from (select distinct p.catalog->>'category' as category from public.mt_products p join tenant_private.storefront_products l on l.store_id=p.store_id and l.product_id=p.id and l.listed join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=t and p.catalog->>'category'<>'' order by category limit 200)x),'[]'::jsonb);
end $$;
create function public.mt_catalog_facets(p_slug text,p_currency text) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.catalog_facets(p_slug,p_currency)$$;
-- Exact SKU and actual availability for the selected POS branch.
create function tenant_private.pos_scan(p_store uuid,p_currency text,p_branch uuid,p_sku text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b uuid:=tenant_private.current_branch_scope(p_store);r jsonb;
begin
 if not coalesce(tenant_private.member_role(p_store) in ('owner','cashier'),false) or (b is not null and b is distinct from p_branch) then raise exception 'Branch denied' using errcode='42501';end if;
 if p_sku is null or length(btrim(p_sku)) not between 1 and 80 or p_currency not in ('SYP','USD','EUR') then raise exception 'Invalid scan' using errcode='22023';end if;
 if p_branch is not null then perform tenant_private.require_branch(p_store,p_branch);end if;
 select jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'price_minor',pp.price_minor,'quantity',case when p_branch is null then tenant_private.main_available(p_store,p.id) else coalesce(bs.units,0) end) into r from public.mt_products p join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency left join tenant_private.branch_stock bs on bs.store_id=p.store_id and bs.product_id=p.id and bs.branch_id=p_branch where p.store_id=p_store and p.sku=btrim(p_sku);return r;
end $$;
create function public.mt_pos_scan(p_store uuid,p_currency text,p_branch uuid,p_sku text) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.pos_scan(p_store,p_currency,p_branch,p_sku)$$;
revoke all on function tenant_private.main_available(uuid,uuid),tenant_private.catalog_facets(text,text),public.mt_catalog_facets(text,text),tenant_private.pos_scan(uuid,text,uuid,text),public.mt_pos_scan(uuid,text,uuid,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.catalog_facets(text,text),public.mt_catalog_facets(text,text) to anon,authenticated;
grant execute on function tenant_private.pos_scan(uuid,text,uuid,text),public.mt_pos_scan(uuid,text,uuid,text) to authenticated;
commit;
