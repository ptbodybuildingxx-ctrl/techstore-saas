-- Owner-approved buyer pricing, frozen on the order and fulfilled by the existing discounted invoice engine.
begin;
create table tenant_private.buyer_price_terms(store_id uuid not null references tenant_private.workspaces(store_id),buyer uuid not null references auth.users(id),tier text not null check(tier in ('member','wholesale')),basis_points int not null check(basis_points between 100 and 5000),min_units int not null check(min_units between 1 and 5000),enabled boolean not null,updated_at timestamptz not null default now(),actor uuid not null,primary key(store_id,buyer));
alter table tenant_private.buyer_price_terms enable row level security;revoke all on tenant_private.buyer_price_terms from public,anon,authenticated,service_role;
alter table tenant_private.order_discounts add column price_tier text check(price_tier in ('member','wholesale'));
do $$declare c text;n int;begin
 select count(*),min(conname) into n,c from pg_constraint where conrelid='tenant_private.order_discounts'::regclass and contype='c' and pg_get_constraintdef(oid) like '%coupon_id%' and pg_get_constraintdef(oid) like '%reward_points%';
 if n<>1 then raise exception 'Expected one discount source constraint';end if;
 execute format('alter table tenant_private.order_discounts drop constraint %I',c);
end$$;
alter table tenant_private.order_discounts add constraint mt_discount_source check((coupon_id is not null and reward_points is null and price_tier is null) or (coupon_id is null and reward_points is not null and reward_points between 2 and 100 and price_tier is null) or (coupon_id is null and reward_points is null and price_tier is not null));
create function tenant_private.buyer_price_set(p_store uuid,p_buyer uuid,p_tier text,p_bps int,p_min int,p_enabled boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if p_enabled is null or p_tier is null or p_tier not in ('member','wholesale') or p_bps is null or p_bps not between 100 and 5000 or p_min is null or p_min not between 1 and 5000 or not exists(select 1 from public.mt_online_orders where store_id=p_store and buyer=p_buyer) then raise exception 'Existing shop buyer and valid terms required' using errcode='22023';end if;
 insert into tenant_private.buyer_price_terms(store_id,buyer,tier,basis_points,min_units,enabled,actor) values(p_store,p_buyer,p_tier,p_bps,p_min,p_enabled,auth.uid()) on conflict(store_id,buyer) do update set tier=excluded.tier,basis_points=excluded.basis_points,min_units=excluded.min_units,enabled=excluded.enabled,actor=excluded.actor,updated_at=now();return p_enabled;
end $$;
create function tenant_private.buyer_price_list(p_store uuid,p_after uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by buyer) from (select buyer,tier,basis_points,min_units,enabled from tenant_private.buyer_price_terms where store_id=p_store and (p_after is null or buyer>p_after) order by buyer limit 50)x),'[]'::jsonb);
end $$;
create function tenant_private.buyer_price_quote(p_slug text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid;v jsonb;begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live buyer required' using errcode='42501';end if;
 select id into t from public.saas_stores where slug=p_slug and tenant_private.storefront_active(id);
 select jsonb_build_object('tier',tier,'basis_points',basis_points,'min_units',min_units) into v from tenant_private.buyer_price_terms where store_id=t and buyer=auth.uid() and enabled;return v;
end $$;
create function tenant_private.member_order(p_slug text,p_request uuid,p_currency text,p_lines jsonb,p_tier text,p_bps int,p_expected_total bigint,p_address text,p_phone text) returns uuid language plpgsql security definer set search_path='' as $$
declare t uuid;oid uuid;o public.mt_online_orders%rowtype;d tenant_private.order_discounts%rowtype;v tenant_private.buyer_price_terms%rowtype;discount bigint;units bigint;existing boolean;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 if p_tier is null or p_tier not in ('member','wholesale') or p_bps is null or p_bps not between 100 and 5000 or p_expected_total is null or p_expected_total<1 or (p_address is null)<>(p_phone is null) then raise exception 'Invalid price tier' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug for update;if not found then raise exception 'Store unavailable' using errcode='22023';end if;
 existing:=exists(select 1 from public.mt_online_orders where store_id=t and buyer=auth.uid() and request_id=p_request);
 if p_address is null then oid:=tenant_private.online_order(p_slug,p_request,p_currency,p_lines);else oid:=tenant_private.delivery_order(p_slug,p_request,p_currency,p_lines,p_address,p_phone);end if;
 select * into strict o from public.mt_online_orders where store_id=t and id=oid;
 if o.delivery_method<>(case when p_address is null then 'pickup' else 'delivery' end) then raise exception 'Conflicting delivery method' using errcode='22023';end if;
 if existing then
 select * into d from tenant_private.order_discounts where store_id=t and order_id=oid;
 if not found or d.price_tier is distinct from p_tier or d.basis_points<>p_bps or o.total_minor<>p_expected_total then raise exception 'Conflicting price tier' using errcode='22023';end if;return oid;
 end if;
 select * into v from tenant_private.buyer_price_terms where store_id=t and buyer=auth.uid() and enabled;
 if not found or v.tier<>p_tier or v.basis_points<>p_bps then raise exception 'Price terms changed' using errcode='22023';end if;
 select sum((x->>'units')::bigint),sum((x->>'units')::bigint*((x->>'expected_price_minor')::bigint*p_bps/10000)) into units,discount from jsonb_array_elements(o.lines)x;
 if units<v.min_units or discount is null or discount<=0 or o.total_minor-discount<>p_expected_total then raise exception 'Minimum quantity or price quote changed' using errcode='22023';end if;
 insert into tenant_private.order_discounts(store_id,order_id,coupon_id,buyer,basis_points,gross_minor,discount_minor,reward_points,price_tier) values(t,oid,null,auth.uid(),p_bps,o.total_minor,discount,null,p_tier);
 update public.mt_online_orders set total_minor=total_minor-discount where store_id=t and id=oid;return oid;
end $$;
create function public.mt_buyer_price_set(p_store uuid,p_buyer uuid,p_tier text,p_bps int,p_min int,p_enabled boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.buyer_price_set(p_store,p_buyer,p_tier,p_bps,p_min,p_enabled)$$;
create function public.mt_buyer_price_list(p_store uuid,p_after uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.buyer_price_list(p_store,p_after)$$;
create function public.mt_buyer_price_quote(p_slug text) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.buyer_price_quote(p_slug)$$;
create function public.mt_member_order(p_slug text,p_request uuid,p_currency text,p_lines jsonb,p_tier text,p_bps int,p_expected_total bigint,p_address text default null,p_phone text default null) returns uuid language sql security invoker set search_path='' as $$select tenant_private.member_order(p_slug,p_request,p_currency,p_lines,p_tier,p_bps,p_expected_total,p_address,p_phone)$$;
revoke all on function tenant_private.buyer_price_set(uuid,uuid,text,int,int,boolean),tenant_private.buyer_price_list(uuid,uuid),tenant_private.buyer_price_quote(text),tenant_private.member_order(text,uuid,text,jsonb,text,int,bigint,text,text),public.mt_buyer_price_set(uuid,uuid,text,int,int,boolean),public.mt_buyer_price_list(uuid,uuid),public.mt_buyer_price_quote(text),public.mt_member_order(text,uuid,text,jsonb,text,int,bigint,text,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.buyer_price_set(uuid,uuid,text,int,int,boolean),tenant_private.buyer_price_list(uuid,uuid),tenant_private.buyer_price_quote(text),tenant_private.member_order(text,uuid,text,jsonb,text,int,bigint,text,text),public.mt_buyer_price_set(uuid,uuid,text,int,int,boolean),public.mt_buyer_price_list(uuid,uuid),public.mt_buyer_price_quote(text),public.mt_member_order(text,uuid,text,jsonb,text,int,bigint,text,text) to authenticated;
commit;
