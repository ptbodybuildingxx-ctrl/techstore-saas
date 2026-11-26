-- Dedicated SaaS only: tenant-scoped public specifications and keyset search.
begin;
alter table public.mt_products add column specs jsonb not null default '{}'::jsonb;
create function tenant_private.valid_product_specs(p_specs jsonb) returns boolean language plpgsql immutable set search_path='' as $$
begin
 if p_specs is null or jsonb_typeof(p_specs)<>'object' then return false;end if;
 return (select count(*)<=30 and coalesce(bool_and(length(btrim(key)) between 1 and 60 and jsonb_typeof(value)='string' and length(value#>>'{}') between 1 and 240),true) from jsonb_each(p_specs));
end $$;
alter table public.mt_products add constraint mt_product_specs_valid check(tenant_private.valid_product_specs(specs));
create function public.mt_set_product_specs(p_store uuid,p_product uuid,p_specs jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(tenant_private.can_write(p_store),false) then raise exception 'Stock write denied' using errcode='42501';end if;
 if not tenant_private.valid_product_specs(p_specs) then raise exception 'Invalid specifications' using errcode='22023';end if;
 update public.mt_products set specs=p_specs where store_id=p_store and id=p_product;
 if not found then raise exception 'Product not found' using errcode='22023';end if;
 return p_specs;
end $$;
create function public.mt_search_products(p_store uuid,p_currency text,p_query text,p_after uuid default null,p_limit integer default 50,p_low boolean default false)
returns table(store_id uuid,id uuid,sku text,name text,quantity bigint,unit_price_minor bigint,specs jsonb)
language plpgsql stable security invoker set search_path='' as $$
begin
 if not coalesce(tenant_private.member_role(p_store) in ('owner','stock','cashier'),false) then raise exception 'Tenant access required' using errcode='42501';end if;
 if p_query is null or length(p_query)>100 or p_low is null or p_limit is null or p_limit not between 1 and 100 or (p_currency is not null and p_currency not in ('SYP','USD','EUR')) then raise exception 'Invalid query' using errcode='22023';end if;
 return query select p.store_id,p.id,p.sku,p.name,p.quantity,pp.price_minor,p.specs from public.mt_products p left join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=p_store and (p_after is null or p.id>p_after) and (not p_low or p.quantity<=5) and (strpos(lower(p.name),lower(btrim(p_query)))>0 or strpos(lower(p.sku),lower(btrim(p_query)))>0 or btrim(p_query)='') order by p.id limit p_limit;
end $$;
create function public.mt_search_catalog(p_slug text,p_currency text,p_query text,p_after uuid default null,p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid;n text;r jsonb;
begin
 if p_slug is null or p_slug !~ '^[a-z][a-z0-9-]{2,39}$' or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_query is null or length(p_query)>100 or p_limit is null or p_limit not between 1 and 50 then raise exception 'Invalid catalog query' using errcode='22023';end if;
 select s.id,s.name into t,n from public.saas_stores s where s.slug=p_slug and tenant_private.storefront_active(s.id);
 if not found then return null;end if;
 select jsonb_build_object('name',n,'slug',p_slug,'currency',p_currency,'products',coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb)) into r from (select p.id,p.name,p.sku,pp.price_minor,p.specs from public.mt_products p join tenant_private.storefront_products l on l.store_id=p.store_id and l.product_id=p.id and l.listed join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=t and p.quantity>0 and (p_after is null or p.id>p_after) and (btrim(p_query)='' or strpos(lower(p.name),lower(btrim(p_query)))>0 or strpos(lower(p.sku),lower(btrim(p_query)))>0) order by p.id limit p_limit) x;
 return r;
end $$;
create function public.mt_stock_history(p_store uuid,p_product uuid,p_before timestamptz default null,p_before_id uuid default null,p_limit integer default 50)
returns table(store_id uuid,request_id uuid,product_id uuid,delta bigint,balance bigint,created_at timestamptz,kind text)
language plpgsql stable security invoker set search_path='' as $$
begin
 if not coalesce(tenant_private.member_role(p_store) in ('owner','stock'),false) then raise exception 'Stock access denied' using errcode='42501';end if;
 if p_product is null or p_limit is null or p_limit not between 1 and 100 or (p_before is null)<>(p_before_id is null) then raise exception 'Invalid page' using errcode='22023';end if;
 return query select e.store_id,e.request_id,e.product_id,e.delta,e.balance,e.created_at,case when e.sale_id is not null then 'sale' when e.return_id is not null then 'return' when e.supplier_return_id is not null then 'supplier_return' when e.delta>0 then 'intake' else 'other_out' end from public.mt_stock_events e where e.store_id=p_store and e.product_id=p_product and (p_before is null or (e.created_at,e.request_id)<(p_before,p_before_id)) order by e.created_at desc,e.request_id desc limit p_limit;
end $$;
revoke all on function tenant_private.valid_product_specs(jsonb),public.mt_set_product_specs(uuid,uuid,jsonb),public.mt_search_products(uuid,text,text,uuid,integer,boolean),public.mt_search_catalog(text,text,text,uuid,integer),public.mt_stock_history(uuid,uuid,timestamptz,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.valid_product_specs(jsonb),public.mt_set_product_specs(uuid,uuid,jsonb),public.mt_search_products(uuid,text,text,uuid,integer,boolean),public.mt_stock_history(uuid,uuid,timestamptz,uuid,integer) to authenticated;
grant execute on function public.mt_search_catalog(text,text,text,uuid,integer) to anon,authenticated;
commit;
