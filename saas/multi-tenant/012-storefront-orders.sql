-- Explicit public catalog and authenticated pickup order workflow. No external payment.
begin;
do $$ begin
 if to_regclass('public.mt_purchases') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required';end if;
end $$;
create table tenant_private.storefronts(
 store_id uuid primary key references tenant_private.workspaces(store_id),
 enabled boolean not null default false
);
create table tenant_private.storefront_products(
 store_id uuid not null,product_id uuid not null,listed boolean not null default true,
 primary key(store_id,product_id),foreign key(store_id,product_id) references public.mt_products(store_id,id)
);
create table public.mt_online_orders(
 store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null default gen_random_uuid(),request_id uuid not null,
 buyer uuid not null references auth.users(id),currency text not null,lines jsonb not null check(jsonb_typeof(lines)='array' and jsonb_array_length(lines) between 1 and 50),
 total_minor bigint not null check(total_minor between 1 and 100000000000000),
 state text not null default 'pending' check(state in ('pending','cancelled','fulfilled')),
 sale_id uuid,finished_by uuid,finished_at timestamptz,created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,buyer,request_id),unique(store_id,sale_id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),
 foreign key(store_id,sale_id) references public.mt_sales(store_id,id),
 check((state='fulfilled')=(sale_id is not null)),
 check((state='pending')=(finished_by is null and finished_at is null)),
 check((finished_by is null)=(finished_at is null))
);
create index mt_online_order_owner_idx on public.mt_online_orders(store_id,state,id);
create index mt_online_order_buyer_idx on public.mt_online_orders(buyer,store_id,created_at desc,id);
alter table tenant_private.storefronts enable row level security;
alter table tenant_private.storefront_products enable row level security;
alter table public.mt_online_orders enable row level security;
revoke all on tenant_private.storefronts,tenant_private.storefront_products,public.mt_online_orders from public,anon,authenticated,service_role;
grant select on public.mt_online_orders to authenticated;
create policy mt_order_read on public.mt_online_orders for select to authenticated using (tenant_private.member_role(store_id)='owner' or (buyer=(select auth.uid()) and (select saas_private.live_session())));
create function tenant_private.storefront_active(p_store uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from tenant_private.storefronts f join tenant_private.placements p on p.store_id=f.store_id join tenant_private.shards sh on sh.code=p.shard_code and sh.state='local' join public.saas_stores s on s.id=f.store_id join public.saas_subscriptions sub on sub.store_id=s.id where f.store_id=p_store and f.enabled and s.state='provisioning' and s.project_ref is null and s.origin is null and sub.state='trial' and sub.valid_until>now())
$$;
create function tenant_private.storefront_enable(p_store uuid,p_enabled boolean) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if p_enabled is null then raise exception 'Invalid enabled flag' using errcode='22023';end if;
 insert into tenant_private.storefronts(store_id,enabled) values(p_store,p_enabled) on conflict(store_id) do update set enabled=excluded.enabled;
 return p_enabled;
end $$;
create function tenant_private.storefront_list_product(p_store uuid,p_product uuid,p_listed boolean) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if p_listed is null or not exists(select 1 from public.mt_products where store_id=p_store and id=p_product) then raise exception 'Invalid product' using errcode='22023';end if;
 insert into tenant_private.storefront_products(store_id,product_id,listed) values(p_store,p_product,p_listed) on conflict(store_id,product_id) do update set listed=excluded.listed;
 return p_listed;
end $$;
create function tenant_private.storefront_status(p_store uuid,p_after uuid,p_limit integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 select jsonb_build_object('enabled',coalesce((select enabled from tenant_private.storefronts where store_id=p_store),false),'active',tenant_private.storefront_active(p_store),'products',coalesce((select jsonb_agg(to_jsonb(x) order by id) from (select p.id,p.name,p.sku,coalesce(l.listed,false) listed from public.mt_products p left join tenant_private.storefront_products l on l.store_id=p.store_id and l.product_id=p.id where p.store_id=p_store and (p_after is null or p.id>p_after) order by p.id limit p_limit) x),'[]'::jsonb)) into r;return r;
end $$;
-- No internal cost, quantity, user details, store ID, or contact information exposed.
create function tenant_private.public_catalog(p_slug text,p_currency text,p_after uuid,p_limit integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid;n text;r jsonb;
begin
 if p_slug is null or p_slug !~ '^[a-z][a-z0-9-]{2,39}$' or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_limit is null or p_limit not between 1 and 50 then raise exception 'Invalid catalog query' using errcode='22023';end if;
 select s.id,s.name into t,n from public.saas_stores s where s.slug=p_slug and tenant_private.storefront_active(s.id);
 if not found then return null;end if;
 select jsonb_build_object('name',n,'slug',p_slug,'currency',p_currency,'products',coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb)) into r from (select p.id,p.name,p.sku,pp.price_minor from public.mt_products p join tenant_private.storefront_products l on l.store_id=p.store_id and l.product_id=p.id and l.listed join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=t and p.quantity>0 and (p_after is null or p.id>p_after) order by p.id limit p_limit) x;
 return r;
end $$;
create function tenant_private.online_order(p_slug text,p_request uuid,p_currency text,p_lines jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare t uuid;x jsonb;norm jsonb;o public.mt_online_orders%rowtype;pr public.mt_products%rowtype;price bigint;total bigint:=0;u bigint;product uuid;
begin
 if not coalesce(saas_private.live_session(),false) or not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null and not is_anonymous) then raise exception 'Confirmed live account required' using errcode='42501';end if;
 if p_slug is null or p_slug !~ '^[a-z][a-z0-9-]{2,39}$' or p_request is null or p_currency is null or p_currency not in ('SYP','USD','EUR') or jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid order' using errcode='22023';end if;
 if jsonb_array_length(p_lines) not between 1 and 50 or octet_length(p_lines::text)>25000 then raise exception 'Invalid cart size' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
  if jsonb_typeof(x) is distinct from 'object' then raise exception 'Invalid cart line' using errcode='22023';end if;
  if (select count(*) from jsonb_object_keys(x))<>3 or not (x ?& array['product_id','units','expected_price_minor']) or jsonb_typeof(x->'product_id') is distinct from 'string' or jsonb_typeof(x->'units') is distinct from 'number' or jsonb_typeof(x->'expected_price_minor') is distinct from 'number' or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,3}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid cart values' using errcode='22023';end if;
  if (x->>'units')::bigint not between 1 and 100 or (x->>'expected_price_minor')::bigint not between 1 and 100000000 then raise exception 'Invalid cart amount' using errcode='22023';end if;
 end loop;
 if (select count(distinct (value->>'product_id')::uuid) from jsonb_array_elements(p_lines))<>jsonb_array_length(p_lines) then raise exception 'Duplicate product' using errcode='22023';end if;
 select jsonb_agg(jsonb_build_object('product_id',(value->>'product_id')::uuid,'units',(value->>'units')::bigint,'expected_price_minor',(value->>'expected_price_minor')::bigint) order by (value->>'product_id')::uuid) into norm from jsonb_array_elements(p_lines);
 select id into t from public.saas_stores where slug=p_slug for update;
 if not found then raise exception 'Store unavailable' using errcode='22023';end if;
 select * into o from public.mt_online_orders where store_id=t and buyer=auth.uid() and request_id=p_request;
 if found then
  if o.currency<>p_currency or o.lines is distinct from norm then raise exception 'Conflicting order request' using errcode='22023';end if;return o.id;
 end if;
 if not tenant_private.storefront_active(t) then raise exception 'Store unavailable' using errcode='22023';end if;
 if (select count(*) from public.mt_online_orders where store_id=t and buyer=auth.uid() and created_at>now()-interval '24 hours')>=10 or (select count(*) from public.mt_online_orders where store_id=t and buyer=auth.uid() and state='pending')>=3 then raise exception 'Order limit reached' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(norm) loop
  product:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;
  select p.* into pr from public.mt_products p join tenant_private.storefront_products l on l.store_id=p.store_id and l.product_id=p.id and l.listed where p.store_id=t and p.id=product;
  if not found or pr.quantity<u then raise exception 'Product unavailable' using errcode='22023';end if;
  select price_minor into price from public.mt_product_prices where store_id=t and product_id=product and currency=p_currency;
  if not found or price<>(x->>'expected_price_minor')::bigint then raise exception 'Price changed' using errcode='22023';end if;
  total:=total+u*price;
 end loop;
 insert into public.mt_online_orders(store_id,request_id,buyer,currency,lines,total_minor) values(t,p_request,auth.uid(),p_currency,norm,total) returning * into o;
 return o.id;
end $$;
create function tenant_private.finish_order(p_store uuid,p_order uuid,p_action text) returns uuid
language plpgsql security definer set search_path='' as $$
declare o public.mt_online_orders%rowtype;r jsonb;is_owner boolean;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 if p_action is null or p_action not in ('cancel','fulfill') then raise exception 'Invalid action' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 is_owner:=coalesce(tenant_private.member_role(p_store)='owner',false);
 select * into o from public.mt_online_orders where store_id=p_store and id=p_order for update;
 if not found or not (is_owner or o.buyer=auth.uid()) then raise exception 'Order access denied' using errcode='42501';end if;
 if p_action='fulfill' then
  if not is_owner then raise exception 'Owner required' using errcode='42501';end if;
  perform tenant_private.owner_write(p_store);
  if o.state='fulfilled' then return o.sale_id;end if;
  if o.state<>'pending' then raise exception 'Order not pending' using errcode='22023';end if;
  -- Owner confirms actual cash at pickup; current stock and quoted price checked by core.
  r:=tenant_private.record_currency_sale(p_store,gen_random_uuid(),o.currency,o.lines);
  update public.mt_online_orders set state='fulfilled',sale_id=(r->>'id')::uuid,finished_by=auth.uid(),finished_at=now() where store_id=p_store and id=p_order;
  return (r->>'id')::uuid;
 end if;
 if o.state='cancelled' then return null;end if;
 if o.state<>'pending' then raise exception 'Completed order cannot be cancelled' using errcode='22023';end if;
 update public.mt_online_orders set state='cancelled',finished_by=auth.uid(),finished_at=now() where store_id=p_store and id=p_order;
 return null;
end $$;
create function public.mt_storefront_enable(p_store uuid,p_enabled boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.storefront_enable(p_store,p_enabled)$$;
create function public.mt_storefront_list_product(p_store uuid,p_product uuid,p_listed boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.storefront_list_product(p_store,p_product,p_listed)$$;
create function public.mt_storefront_status(p_store uuid,p_after uuid default null,p_limit integer default 50) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.storefront_status(p_store,p_after,p_limit)$$;
create function public.mt_public_catalog(p_slug text,p_currency text,p_after uuid default null,p_limit integer default 50) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.public_catalog(p_slug,p_currency,p_after,p_limit)$$;
create function public.mt_online_order(p_slug text,p_request uuid,p_currency text,p_lines jsonb) returns uuid language sql security invoker set search_path='' as $$select tenant_private.online_order(p_slug,p_request,p_currency,p_lines)$$;
create function public.mt_finish_order(p_store uuid,p_order uuid,p_action text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.finish_order(p_store,p_order,p_action)$$;
create function public.mt_list_orders(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.mt_online_orders
language plpgsql stable security invoker set search_path='' as $$
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select * from public.mt_online_orders where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;
end $$;
revoke all on function tenant_private.storefront_active(uuid),tenant_private.storefront_enable(uuid,boolean),tenant_private.storefront_list_product(uuid,uuid,boolean),tenant_private.storefront_status(uuid,uuid,integer),tenant_private.public_catalog(text,text,uuid,integer),tenant_private.online_order(text,uuid,text,jsonb),tenant_private.finish_order(uuid,uuid,text),public.mt_storefront_enable(uuid,boolean),public.mt_storefront_list_product(uuid,uuid,boolean),public.mt_storefront_status(uuid,uuid,integer),public.mt_public_catalog(text,text,uuid,integer),public.mt_online_order(text,uuid,text,jsonb),public.mt_finish_order(uuid,uuid,text),public.mt_list_orders(uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.storefront_enable(uuid,boolean),tenant_private.storefront_list_product(uuid,uuid,boolean),tenant_private.storefront_status(uuid,uuid,integer),tenant_private.online_order(text,uuid,text,jsonb),tenant_private.finish_order(uuid,uuid,text),public.mt_storefront_enable(uuid,boolean),public.mt_storefront_list_product(uuid,uuid,boolean),public.mt_storefront_status(uuid,uuid,integer),public.mt_online_order(text,uuid,text,jsonb),public.mt_finish_order(uuid,uuid,text),public.mt_list_orders(uuid,uuid,integer) to authenticated;
-- Anonymous may execute the deliberately narrow catalog projection only.
grant usage on schema tenant_private to anon;
grant execute on function tenant_private.public_catalog(text,text,uuid,integer),public.mt_public_catalog(text,text,uuid,integer) to anon,authenticated;
commit;