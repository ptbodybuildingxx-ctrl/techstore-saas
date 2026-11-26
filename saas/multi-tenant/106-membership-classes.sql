-- Store-scoped membership classes, defaults and explicit buyer product prices.
-- Preserve old member/wholesale assignments and already issued order prices.
alter table tenant_private.buyer_price_terms drop constraint buyer_price_terms_tier_check, drop constraint buyer_price_terms_basis_points_check;
alter table tenant_private.buyer_price_terms add constraint buyer_price_terms_tier_check check(tier in ('standard','member','silver','gold','vip','wholesale')),add constraint buyer_price_terms_basis_points_check check(basis_points between 0 and 5000),add column use_default boolean not null default false;
alter table tenant_private.product_tier_prices drop constraint product_tier_prices_tier_check;
alter table tenant_private.product_tier_prices add constraint product_tier_prices_tier_check check(tier in ('standard','member','silver','gold','vip','wholesale'));
alter table tenant_private.order_discounts drop constraint order_discounts_price_tier_check,drop constraint order_discounts_basis_points_check;
alter table tenant_private.order_discounts add constraint order_discounts_price_tier_check check(price_tier in ('standard','member','silver','gold','vip','wholesale')),add constraint order_discounts_basis_points_check check(basis_points between 0 and 5000 and (price_tier is not null or basis_points>=100));

create table tenant_private.membership_rates(
 store_id uuid not null references tenant_private.workspaces(store_id),tier text not null check(tier in ('standard','member','silver','gold','vip','wholesale')),
 basis_points integer not null check(basis_points between 0 and 5000),min_units integer not null check(min_units between 1 and 5000),
 actor uuid not null,updated_at timestamptz not null default now(),primary key(store_id,tier));
create table tenant_private.membership_directory(
 store_id uuid not null references tenant_private.workspaces(store_id),buyer uuid not null references auth.users(id),
 display_name text not null check(length(btrim(display_name)) between 1 and 120),created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),primary key(store_id,buyer));
create table tenant_private.buyer_product_prices(
 store_id uuid not null,buyer uuid not null references auth.users(id),product_id uuid not null,currency text not null,
 price_minor bigint not null check(price_minor between 1 and 100000000),min_units integer not null check(min_units between 1 and 100),
 actor uuid not null,updated_at timestamptz not null default now(),primary key(store_id,buyer,product_id,currency),
 foreign key(store_id,product_id) references public.mt_products(store_id,id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency));
alter table tenant_private.membership_rates enable row level security;
alter table tenant_private.membership_directory enable row level security;
alter table tenant_private.buyer_product_prices enable row level security;
revoke all on tenant_private.membership_rates,tenant_private.membership_directory,tenant_private.buyer_product_prices from public,anon,authenticated,service_role;

create function tenant_private.known_membership_buyer(s uuid,u uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.users where id=u and not is_anonymous and email_confirmed_at is not null) and
 (exists(select 1 from tenant_private.membership_directory where store_id=s and buyer=u) or exists(select 1 from public.mt_online_orders where store_id=s and buyer=u) or exists(select 1 from tenant_private.pos_loyalty_sales where store_id=s and buyer=u) or exists(select 1 from tenant_private.buyer_price_terms where store_id=s and buyer=u))
$$;
create function tenant_private.effective_buyer_terms(s uuid,u uuid) returns tenant_private.buyer_price_terms language plpgsql stable security definer set search_path='' as $$
declare v tenant_private.buyer_price_terms%rowtype;
begin
 if s is null or u is null or not tenant_private.known_membership_buyer(s,u) then return null;end if;
 select * into v from tenant_private.buyer_price_terms where store_id=s and buyer=u;
 if not found then v.store_id:=s;v.buyer:=u;v.tier:='standard';v.enabled:=true;v.use_default:=true;end if;
 if not v.enabled then return null;end if;
 if v.use_default then
 select basis_points,min_units into v.basis_points,v.min_units from tenant_private.membership_rates where store_id=s and tier=v.tier;
 v.basis_points:=coalesce(v.basis_points,0);v.min_units:=coalesce(v.min_units,1);
 end if;
 return v;
end $$;
create function tenant_private.membership_rates_read(s uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return (select jsonb_agg(jsonb_build_object('tier',t.tier,'basis_points',coalesce(r.basis_points,0),'min_units',coalesce(r.min_units,1)) order by t.n) from unnest(array['standard','silver','gold','vip','wholesale','member']) with ordinality t(tier,n) left join tenant_private.membership_rates r on r.store_id=s and r.tier=t.tier);
end $$;
create function tenant_private.membership_rate_set(s uuid,t text,bps integer,m integer) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(s);
 if t is null or t not in ('standard','member','silver','gold','vip','wholesale') or bps is null or bps not between 0 and 5000 or m is null or m not between 1 and 5000 then raise exception 'Invalid membership rate';end if;
 insert into tenant_private.membership_rates(store_id,tier,basis_points,min_units,actor) values(s,t,bps,m,auth.uid())
 on conflict(store_id,tier) do update set basis_points=excluded.basis_points,min_units=excluded.min_units,actor=excluded.actor,updated_at=now();
 return true;
end $$;
create function tenant_private.membership_enroll(slug_value text,n text) returns boolean language plpgsql security definer set search_path='' as $$
declare s uuid;u uuid:=auth.uid();
begin
 if u is null or not coalesce(saas_private.live_session(),false) or not exists(select 1 from auth.users where id=u and not is_anonymous and email_confirmed_at is not null) then raise exception 'Live confirmed buyer required' using errcode='42501';end if;
 if n is null or length(btrim(n)) not between 1 and 120 then raise exception 'Invalid display name';end if;
 select id into s from public.saas_stores where slug=slug_value and tenant_private.storefront_active(id) for update;
 if s is null then raise exception 'Store unavailable';end if;
 insert into tenant_private.membership_directory(store_id,buyer,display_name) values(s,u,btrim(n))
 on conflict(store_id,buyer) do update set display_name=excluded.display_name,updated_at=now();
 return true;
end $$;
create function tenant_private.membership_buyer_directory(s uuid,q text,a uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(s) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if q is null or length(q)>120 then raise exception 'Invalid search';end if;
 return (with known as (
 select buyer from tenant_private.membership_directory where store_id=s
 union select buyer from public.mt_online_orders where store_id=s
 union select buyer from tenant_private.pos_loyalty_sales where store_id=s
 union select buyer from tenant_private.buyer_price_terms where store_id=s
 ),page as (
 select k.buyer,coalesce(d.display_name,'') display_name,coalesce(t.tier,'standard') tier,
 coalesce(t.enabled,true) enabled,coalesce(t.use_default,true) use_default,
 coalesce(case when t.use_default is false then t.basis_points else r.basis_points end,0) basis_points,
 coalesce(case when t.use_default is false then t.min_units else r.min_units end,1) min_units
 from known k join auth.users u on u.id=k.buyer and not u.is_anonymous and u.email_confirmed_at is not null
 left join tenant_private.membership_directory d on d.store_id=s and d.buyer=k.buyer
 left join tenant_private.buyer_price_terms t on t.store_id=s and t.buyer=k.buyer
 left join tenant_private.membership_rates r on r.store_id=s and r.tier=coalesce(t.tier,'standard')
 where (a is null or k.buyer>a) and (q='' or strpos(lower(coalesce(d.display_name,'')),lower(q))>0 or strpos(k.buyer::text,lower(q))>0)
 order by k.buyer limit 51)
 select coalesce(jsonb_agg(to_jsonb(page) order by buyer),'[]'::jsonb) from page);
end $$;
create function tenant_private.membership_assign(s uuid,u uuid,t text,defaults boolean,bps integer,m integer,enabled_value boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(s);
 if not tenant_private.known_membership_buyer(s,u) or t is null or t not in ('standard','member','silver','gold','vip','wholesale') or defaults is null or enabled_value is null or bps is null or bps not between 0 and 5000 or m is null or m not between 1 and 5000 then raise exception 'Invalid membership assignment';end if;
 insert into tenant_private.buyer_price_terms(store_id,buyer,tier,use_default,basis_points,min_units,enabled,actor)
 values(s,u,t,defaults,case when defaults then 0 else bps end,case when defaults then 1 else m end,enabled_value,auth.uid())
 on conflict(store_id,buyer) do update set tier=excluded.tier,use_default=excluded.use_default,basis_points=excluded.basis_points,min_units=excluded.min_units,enabled=excluded.enabled,actor=excluded.actor,updated_at=now();
 return true;
end $$;
create function tenant_private.buyer_product_price_set(s uuid,u uuid,p uuid,c text,price bigint,m integer,enabled_value boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(s);
 if not tenant_private.known_membership_buyer(s,u) or p is null or c is null or c not in ('SYP','USD','EUR') or enabled_value is null or not exists(select 1 from public.mt_products where store_id=s and id=p) then raise exception 'Invalid buyer price';end if;
 if not enabled_value then delete from tenant_private.buyer_product_prices where store_id=s and buyer=u and product_id=p and currency=c;return false;end if;
 if price is null or price not between 1 and 100000000 or m is null or m not between 1 and 100 or not exists(select 1 from public.mt_product_prices where store_id=s and product_id=p and currency=c and price_minor>=price) then raise exception 'Special price must not exceed retail price';end if;
 insert into tenant_private.buyer_product_prices(store_id,buyer,product_id,currency,price_minor,min_units,actor) values(s,u,p,c,price,m,auth.uid())
 on conflict(store_id,buyer,product_id,currency) do update set price_minor=excluded.price_minor,min_units=excluded.min_units,actor=excluded.actor,updated_at=now();return true;
end $$;
create function tenant_private.buyer_product_price_list(s uuid,u uuid,p uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(s) is distinct from 'owner' or not tenant_private.known_membership_buyer(s,u) then raise exception 'Buyer access denied' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'price_minor',price_minor,'min_units',min_units) order by currency),'[]'::jsonb) from tenant_private.buyer_product_prices where store_id=s and buyer=u and product_id=p);
end $$;

create function public.mt_membership_rates_read(p_store uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.membership_rates_read(p_store)$$;
revoke all on function tenant_private.membership_rates_read(uuid),public.mt_membership_rates_read(uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.membership_rates_read(uuid),public.mt_membership_rates_read(uuid) to authenticated;
create function public.mt_membership_rate_set(p_store uuid,p_tier text,p_bps integer,p_min integer) returns boolean language sql  security invoker set search_path='' as $$select tenant_private.membership_rate_set(p_store,p_tier,p_bps,p_min)$$;
revoke all on function tenant_private.membership_rate_set(uuid,text,integer,integer),public.mt_membership_rate_set(uuid,text,integer,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.membership_rate_set(uuid,text,integer,integer),public.mt_membership_rate_set(uuid,text,integer,integer) to authenticated;
create function public.mt_membership_enroll(p_slug text,p_name text) returns boolean language sql  security invoker set search_path='' as $$select tenant_private.membership_enroll(p_slug,p_name)$$;
revoke all on function tenant_private.membership_enroll(text,text),public.mt_membership_enroll(text,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.membership_enroll(text,text),public.mt_membership_enroll(text,text) to authenticated;
create function public.mt_membership_buyer_directory(p_store uuid,p_query text,p_after uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.membership_buyer_directory(p_store,p_query,p_after)$$;
revoke all on function tenant_private.membership_buyer_directory(uuid,text,uuid),public.mt_membership_buyer_directory(uuid,text,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.membership_buyer_directory(uuid,text,uuid),public.mt_membership_buyer_directory(uuid,text,uuid) to authenticated;
create function public.mt_membership_assign(p_store uuid,p_buyer uuid,p_tier text,p_defaults boolean,p_bps integer,p_min integer,p_enabled boolean) returns boolean language sql  security invoker set search_path='' as $$select tenant_private.membership_assign(p_store,p_buyer,p_tier,p_defaults,p_bps,p_min,p_enabled)$$;
revoke all on function tenant_private.membership_assign(uuid,uuid,text,boolean,integer,integer,boolean),public.mt_membership_assign(uuid,uuid,text,boolean,integer,integer,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.membership_assign(uuid,uuid,text,boolean,integer,integer,boolean),public.mt_membership_assign(uuid,uuid,text,boolean,integer,integer,boolean) to authenticated;
create function public.mt_buyer_product_price_set(p_store uuid,p_buyer uuid,p_product uuid,p_currency text,p_price bigint,p_min integer,p_enabled boolean) returns boolean language sql  security invoker set search_path='' as $$select tenant_private.buyer_product_price_set(p_store,p_buyer,p_product,p_currency,p_price,p_min,p_enabled)$$;
revoke all on function tenant_private.buyer_product_price_set(uuid,uuid,uuid,text,bigint,integer,boolean),public.mt_buyer_product_price_set(uuid,uuid,uuid,text,bigint,integer,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.buyer_product_price_set(uuid,uuid,uuid,text,bigint,integer,boolean),public.mt_buyer_product_price_set(uuid,uuid,uuid,text,bigint,integer,boolean) to authenticated;
create function public.mt_buyer_product_price_list(p_store uuid,p_buyer uuid,p_product uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.buyer_product_price_list(p_store,p_buyer,p_product)$$;
revoke all on function tenant_private.buyer_product_price_list(uuid,uuid,uuid),public.mt_buyer_product_price_list(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.buyer_product_price_list(uuid,uuid,uuid),public.mt_buyer_product_price_list(uuid,uuid,uuid) to authenticated;
revoke all on function tenant_private.known_membership_buyer(uuid,uuid),tenant_private.effective_buyer_terms(uuid,uuid) from public,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION tenant_private.buyer_price_set(p_store uuid, p_buyer uuid, p_tier text, p_bps integer, p_min integer, p_enabled boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 perform tenant_private.owner_write(p_store);
 if p_enabled is null or p_tier is null or p_tier not in ('standard','member','silver','gold','vip','wholesale') or p_bps is null or p_bps not between 0 and 5000 or p_min is null or p_min not between 1 and 5000 or not tenant_private.known_membership_buyer(p_store,p_buyer) then raise exception 'Existing shop buyer and valid terms required' using errcode='22023';end if;
 insert into tenant_private.buyer_price_terms(store_id,buyer,tier,basis_points,min_units,enabled,actor) values(p_store,p_buyer,p_tier,p_bps,p_min,p_enabled,auth.uid()) on conflict(store_id,buyer) do update set use_default=false,tier=excluded.tier,basis_points=excluded.basis_points,min_units=excluded.min_units,enabled=excluded.enabled,actor=excluded.actor,updated_at=now();return p_enabled;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.buyer_price_quote(p_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid;v tenant_private.buyer_price_terms%rowtype;begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live buyer required' using errcode='42501';end if;
 select id into t from public.saas_stores where slug=p_slug and tenant_private.storefront_active(id);
 v:=tenant_private.effective_buyer_terms(t,auth.uid());if v.buyer is null then return null;end if;return jsonb_build_object('tier',v.tier,'basis_points',v.basis_points,'min_units',v.min_units);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.product_tier_quote(p_slug text, p_currency text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid;v tenant_private.buyer_price_terms%rowtype;x jsonb;pid uuid;u bigint;retail bigint;net bigint;gross bigint:=0;total bigint:=0;units bigint:=0;prices jsonb:='{}';begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live buyer required' using errcode='42501';end if;
 if jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid cart' using errcode='22023';end if;
 if jsonb_array_length(p_lines) not between 1 and 50 or octet_length(p_lines::text)>30000 then raise exception 'Invalid cart' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug and tenant_private.storefront_active(id);
 v:=tenant_private.effective_buyer_terms(t,auth.uid());
 if v.buyer is null then return null;end if;
 for x in select value from jsonb_array_elements(p_lines) loop
 if jsonb_typeof(x) is distinct from 'object' or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,3}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid line' using errcode='22023';end if;
 pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;
 if u not between 1 and 100 or prices ? pid::text then raise exception 'Invalid quantity or duplicate product' using errcode='22023';end if;
 select pp.price_minor into retail from public.mt_product_prices pp join tenant_private.storefront_products l on l.store_id=pp.store_id and l.product_id=pp.product_id and l.listed where pp.store_id=t and pp.product_id=pid and pp.currency=p_currency;
 if not found or retail<>(x->>'expected_price_minor')::bigint then raise exception 'List price changed' using errcode='22023';end if;
 select price_minor into net from tenant_private.buyer_product_prices where store_id=t and buyer=auth.uid() and product_id=pid and currency=p_currency and min_units<=u and price_minor<=retail;
 if not found then select price_minor into net from tenant_private.product_tier_prices where store_id=t and product_id=pid and tier=v.tier and currency=p_currency and min_units<=u and price_minor<=retail;end if;
 net:=coalesce(net,retail-retail*v.basis_points/10000);if net<1 then raise exception 'Invalid net price' using errcode='22023';end if;
 gross:=gross+retail*u;total:=total+net*u;units:=units+u;prices:=prices||jsonb_build_object(pid::text,net);
 end loop;
 if units<v.min_units or total>=gross then return null;end if;
 return jsonb_build_object('tier',v.tier,'basis_points',v.basis_points,'min_units',v.min_units,'prices',prices,'total_minor',total,'gross_minor',gross);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.product_tier_set(p_store uuid, p_product uuid, p_tier text, p_currency text, p_price bigint, p_min integer, p_enabled boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 perform tenant_private.owner_write(p_store);
 if p_tier is null or p_tier not in ('standard','member','silver','gold','vip','wholesale') or p_currency is null or p_enabled is null or not exists(select 1 from public.mt_products where store_id=p_store and id=p_product) then raise exception 'Invalid tier' using errcode='22023';end if;
 if not p_enabled then delete from tenant_private.product_tier_prices where store_id=p_store and product_id=p_product and tier=p_tier and currency=p_currency;return false;end if;
 if p_price is null or p_price not between 1 and 100000000 or p_min is null or p_min not between 1 and 100 or not exists(select 1 from public.mt_product_prices where store_id=p_store and product_id=p_product and currency=p_currency and price_minor>=p_price) then raise exception 'Tier price must not exceed list price' using errcode='22023';end if;
 insert into tenant_private.product_tier_prices(store_id,product_id,tier,currency,price_minor,min_units,actor) values(p_store,p_product,p_tier,p_currency,p_price,p_min,auth.uid()) on conflict(store_id,product_id,tier,currency) do update set price_minor=excluded.price_minor,min_units=excluded.min_units,actor=excluded.actor,updated_at=now();return true;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.member_order(p_slug text, p_request uuid, p_currency text, p_lines jsonb, p_tier text, p_bps integer, p_expected_total bigint, p_address text, p_phone text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid;oid uuid;o public.mt_online_orders%rowtype;d tenant_private.order_discounts%rowtype;v tenant_private.buyer_price_terms%rowtype;discount bigint;units bigint;existing boolean;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 if p_tier is null or p_tier not in ('standard','member','silver','gold','vip','wholesale') or p_bps is null or p_bps not between 100 and 5000 or p_expected_total is null or p_expected_total<1 or (p_address is null)<>(p_phone is null) then raise exception 'Invalid price tier' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug for update;if not found then raise exception 'Store unavailable' using errcode='22023';end if;
 existing:=exists(select 1 from public.mt_online_orders where store_id=t and buyer=auth.uid() and request_id=p_request);
 if p_address is null then oid:=tenant_private.online_order(p_slug,p_request,p_currency,p_lines);else oid:=tenant_private.delivery_order(p_slug,p_request,p_currency,p_lines,p_address,p_phone);end if;
 select * into strict o from public.mt_online_orders where store_id=t and id=oid;
 if o.delivery_method<>(case when p_address is null then 'pickup' else 'delivery' end) then raise exception 'Conflicting delivery method' using errcode='22023';end if;
 if existing then
 select * into d from tenant_private.order_discounts where store_id=t and order_id=oid;
 if not found or d.price_tier is distinct from p_tier or d.basis_points<>p_bps or o.total_minor<>p_expected_total then raise exception 'Conflicting price tier' using errcode='22023';end if;return oid;
 end if;
 v:=tenant_private.effective_buyer_terms(t,auth.uid());
 if v.buyer is null or v.tier<>p_tier or v.basis_points<>p_bps then raise exception 'Price terms changed' using errcode='22023';end if;
 select sum((x->>'units')::bigint),sum((x->>'units')::bigint*((x->>'expected_price_minor')::bigint*p_bps/10000)) into units,discount from jsonb_array_elements(o.lines)x;
 if units<v.min_units or discount is null or discount<=0 or o.total_minor-discount<>p_expected_total then raise exception 'Minimum quantity or price quote changed' using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(o.lines) x where exists(select 1 from tenant_private.buyer_product_prices b where b.store_id=t and b.buyer=auth.uid() and b.product_id=(x->>'product_id')::uuid and b.currency=p_currency and b.min_units<=(x->>'units')::int and b.price_minor<=(x->>'expected_price_minor')::bigint) or exists(select 1 from tenant_private.product_tier_prices b where b.store_id=t and b.tier=v.tier and b.product_id=(x->>'product_id')::uuid and b.currency=p_currency and b.min_units<=(x->>'units')::int and b.price_minor<=(x->>'expected_price_minor')::bigint)) then raise exception 'Use current product tier quote';end if;
 insert into tenant_private.order_discounts(store_id,order_id,coupon_id,buyer,basis_points,gross_minor,discount_minor,reward_points,price_tier) values(t,oid,null,auth.uid(),p_bps,o.total_minor,discount,null,p_tier);
 update public.mt_online_orders set total_minor=total_minor-discount where store_id=t and id=oid;return oid;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.business_export(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t text;v jsonb;out_data jsonb:='{}';n bigint;total_rows bigint:=0;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' or not tenant_private.shared_licensed(p_store) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Owner and AAL2 required' using errcode='42501';end if;
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines','tenant_private.stock_count_cancellations','tenant_private.procurement_grants','tenant_private.procurement_requests','tenant_private.sale_invoice_details','tenant_private.sale_warranty_claims','tenant_private.sale_warranty_events','tenant_private.pos_loyalty_sales','tenant_private.customer_profile_edits','tenant_private.standalone_debts','tenant_private.standalone_installments','tenant_private.standalone_debt_payments','tenant_private.standalone_payment_allocations','tenant_private.receivable_grants','tenant_private.receivable_resolutions','tenant_private.membership_rates','tenant_private.membership_directory','tenant_private.buyer_product_prices','tenant_private.product_tier_prices'] loop
 -- Fixed relation allowlist; no user-supplied table or SQL text.
 execute format('select count(*) from (select 1 from %I.%I where store_id=$1 limit 5001)x',split_part(t,'.',1),split_part(t,'.',2)) into n using p_store;
 if n>5000 or total_rows+n>20000 then raise exception 'Export exceeds browser snapshot limit; use controlled server backup' using errcode='22023';end if;
 -- Limit before building the aggregate, including large image-containing product rows.
 execute format('select coalesce(sum(octet_length(to_jsonb(r)::text)),0) from %I.%I r where store_id=$1',split_part(t,'.',1),split_part(t,'.',2)) into n using p_store;
 if n>4000000 or octet_length(out_data::text)+n>8000000 then raise exception 'Export exceeds browser byte limit' using errcode='22023';end if;
 execute format('select coalesce(jsonb_agg(to_jsonb(r)),''[]''::jsonb) from %I.%I r where store_id=$1',split_part(t,'.',1),split_part(t,'.',2)) into v using p_store;
 total_rows:=total_rows+jsonb_array_length(v);out_data:=out_data||jsonb_build_object(t,v);
 end loop;
 return jsonb_build_object('version',1,'scope','business_export_only','store',p_store,'captured_at',now(),'rows',total_rows,'tables',out_data);
end $function$;
