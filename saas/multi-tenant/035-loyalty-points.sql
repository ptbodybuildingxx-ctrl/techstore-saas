begin;
-- Non-transferable loyalty points: one point per completed, not fully returned non-reward order.
-- Reward redemptions reserve points at placement; cancellation releases, fulfillment consumes.
create table tenant_private.loyalty_settings(
 store_id uuid primary key references tenant_private.workspaces(store_id),
 enabled boolean not null default false, points_required integer not null check(points_required between 2 and 100),
 basis_points integer not null check(basis_points between 100 and 5000),actor uuid not null,updated_at timestamptz not null default now()
);
alter table tenant_private.loyalty_settings enable row level security;
revoke all on tenant_private.loyalty_settings from public,anon,authenticated,service_role;
alter table tenant_private.order_discounts alter column coupon_id drop not null,add column reward_points integer,
 add check((coupon_id is not null and reward_points is null) or (coupon_id is null and reward_points is not null and reward_points between 2 and 100));
create index mt_reward_buyer_idx on tenant_private.order_discounts(store_id,buyer) where reward_points is not null;
create function tenant_private.points_balance(p_store uuid,p_buyer uuid) returns bigint language sql stable security definer set search_path='' as $$
 select (select count(*) from public.mt_online_orders o where o.store_id=p_store and o.buyer=p_buyer and o.state='fulfilled'
 and o.total_minor>(select coalesce(sum(r.total_minor),0) from public.mt_returns r where r.store_id=o.store_id and r.sale_id=o.sale_id)
 and not exists(select 1 from tenant_private.order_discounts d where d.store_id=o.store_id and d.order_id=o.id and d.reward_points is not null))
 - (select coalesce(sum(d.reward_points),0) from tenant_private.order_discounts d join public.mt_online_orders o on o.store_id=d.store_id and o.id=d.order_id where d.store_id=p_store and d.buyer=p_buyer and d.reward_points is not null and o.state<>'cancelled')
$$;
create function tenant_private.set_loyalty(p_store uuid,p_enabled boolean,p_points integer,p_bps integer) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if p_enabled is null or p_points is null or p_points not between 2 and 100 or p_bps is null or p_bps not between 100 and 5000 then raise exception 'Invalid loyalty policy' using errcode='22023';end if;
 insert into tenant_private.loyalty_settings(store_id,enabled,points_required,basis_points,actor) values(p_store,p_enabled,p_points,p_bps,auth.uid()) on conflict(store_id) do update set enabled=excluded.enabled,points_required=excluded.points_required,basis_points=excluded.basis_points,actor=excluded.actor,updated_at=now();
 return jsonb_build_object('enabled',p_enabled,'points_required',p_points,'basis_points',p_bps);
end $$;
create function tenant_private.loyalty_settings_read(p_store uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare s tenant_private.loyalty_settings%rowtype;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 select * into s from tenant_private.loyalty_settings where store_id=p_store;
 return jsonb_build_object('enabled',coalesce(s.enabled,false),'points_required',coalesce(s.points_required,5),'basis_points',coalesce(s.basis_points,1000));
end $$;
create function tenant_private.buyer_points(p_slug text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid;s tenant_private.loyalty_settings%rowtype;b bigint;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 select id into t from public.saas_stores where slug=p_slug;if t is null or not tenant_private.storefront_active(t) then raise exception 'Store unavailable' using errcode='22023';end if;
 select * into s from tenant_private.loyalty_settings where store_id=t;
 b:=tenant_private.points_balance(t,auth.uid());
 return jsonb_build_object('balance',greatest(0,b),'deficit',greatest(0,-b),'enabled',coalesce(s.enabled,false),'points_required',coalesce(s.points_required,5),'basis_points',coalesce(s.basis_points,1000),'eligible',coalesce(s.enabled,false) and b>=coalesce(s.points_required,5));
end $$;
create function tenant_private.reward_order(p_slug text,p_request uuid,p_currency text,p_lines jsonb,p_points integer,p_bps integer,p_expected_total bigint,p_address text,p_phone text) returns uuid language plpgsql security definer set search_path='' as $$
declare t uuid;oid uuid;o public.mt_online_orders%rowtype;d tenant_private.order_discounts%rowtype;s tenant_private.loyalty_settings%rowtype;discount bigint;existing boolean;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 if p_points is null or p_points not between 2 and 100 or p_bps is null or p_bps not between 100 and 5000 or p_expected_total is null or p_expected_total<1 or (p_address is null)<>(p_phone is null) then raise exception 'Invalid reward' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug for update;if not found then raise exception 'Store unavailable' using errcode='22023';end if;
 existing:=exists(select 1 from public.mt_online_orders where store_id=t and buyer=auth.uid() and request_id=p_request);
 if p_address is null then oid:=tenant_private.online_order(p_slug,p_request,p_currency,p_lines);else oid:=tenant_private.delivery_order(p_slug,p_request,p_currency,p_lines,p_address,p_phone);end if;
 select * into strict o from public.mt_online_orders where store_id=t and id=oid;
 if o.delivery_method<>(case when p_address is null then 'pickup' else 'delivery' end) then raise exception 'Conflicting delivery method' using errcode='22023';end if;
 if existing then
  select * into d from tenant_private.order_discounts where store_id=t and order_id=oid;
  if not found or d.reward_points is distinct from p_points or d.basis_points<>p_bps or o.total_minor<>p_expected_total then raise exception 'Conflicting reward request' using errcode='22023';end if;return oid;
 end if;
 select * into s from tenant_private.loyalty_settings where store_id=t;
 if not found or not s.enabled or s.points_required<>p_points or s.basis_points<>p_bps or tenant_private.points_balance(t,auth.uid())<p_points then raise exception 'Reward unavailable' using errcode='22023';end if;
 select sum((x->>'units')::bigint*((x->>'expected_price_minor')::bigint*p_bps/10000)) into discount from jsonb_array_elements(o.lines)x;
 if discount is null or discount<=0 or o.total_minor-discount<>p_expected_total then raise exception 'Reward quote changed' using errcode='22023';end if;
 insert into tenant_private.order_discounts(store_id,order_id,coupon_id,buyer,basis_points,gross_minor,discount_minor,reward_points) values(t,oid,null,auth.uid(),p_bps,o.total_minor,discount,p_points);
 update public.mt_online_orders set total_minor=total_minor-discount where store_id=t and id=oid;return oid;
end $$;
create function public.mt_set_loyalty(p_store uuid,p_enabled boolean,p_points integer,p_bps integer) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.set_loyalty(p_store,p_enabled,p_points,p_bps)$$;
create function public.mt_loyalty_settings(p_store uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.loyalty_settings_read(p_store)$$;
create function public.mt_buyer_points(p_slug text) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.buyer_points(p_slug)$$;
create function public.mt_reward_order(p_slug text,p_request uuid,p_currency text,p_lines jsonb,p_points integer,p_bps integer,p_expected_total bigint,p_address text default null,p_phone text default null) returns uuid language sql security invoker set search_path='' as $$select tenant_private.reward_order(p_slug,p_request,p_currency,p_lines,p_points,p_bps,p_expected_total,p_address,p_phone)$$;
revoke all on function tenant_private.points_balance(uuid,uuid),tenant_private.set_loyalty(uuid,boolean,integer,integer),tenant_private.loyalty_settings_read(uuid),tenant_private.buyer_points(text),tenant_private.reward_order(text,uuid,text,jsonb,integer,integer,bigint,text,text),public.mt_set_loyalty(uuid,boolean,integer,integer),public.mt_loyalty_settings(uuid),public.mt_buyer_points(text),public.mt_reward_order(text,uuid,text,jsonb,integer,integer,bigint,text,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.set_loyalty(uuid,boolean,integer,integer),tenant_private.loyalty_settings_read(uuid),tenant_private.buyer_points(text),tenant_private.reward_order(text,uuid,text,jsonb,integer,integer,bigint,text,text),public.mt_set_loyalty(uuid,boolean,integer,integer),public.mt_loyalty_settings(uuid),public.mt_buyer_points(text),public.mt_reward_order(text,uuid,text,jsonb,integer,integer,bigint,text,text) to authenticated;
commit;