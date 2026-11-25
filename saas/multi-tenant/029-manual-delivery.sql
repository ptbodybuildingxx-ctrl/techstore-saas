begin;
alter table tenant_private.storefronts add column delivery_enabled boolean not null default false;
alter table public.mt_online_orders add column delivery_method text not null default 'pickup' check(delivery_method in ('pickup','delivery')),
 add column delivery_state text,add column delivery_address text,add column delivery_phone text,add column tracking_reference text,
 add check((delivery_method='pickup' and delivery_state is null and delivery_address is null and delivery_phone is null and tracking_reference is null) or (delivery_method='delivery' and delivery_state is not null and delivery_state in ('requested','dispatched','delivered','cancelled') and delivery_address is not null and length(btrim(delivery_address)) between 5 and 400 and delivery_phone is not null and length(btrim(delivery_phone)) between 5 and 40 and (tracking_reference is null or length(btrim(tracking_reference)) between 1 and 100))),
 add check(delivery_method='pickup' or (state='pending' and delivery_state in ('requested','dispatched')) or (state='fulfilled' and delivery_state='delivered') or (state='cancelled' and delivery_state='cancelled'));
create table tenant_private.order_reservations(
 store_id uuid not null,order_id uuid not null,product_id uuid not null,currency text not null,units bigint not null check(units between 1 and 100),
 primary key(store_id,order_id,product_id),foreign key(store_id,order_id) references public.mt_online_orders(store_id,id),foreign key(store_id,product_id) references public.mt_products(store_id,id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency)
);
create index mt_reserved_product_idx on tenant_private.order_reservations(store_id,product_id,currency);
alter table tenant_private.order_reservations enable row level security;
revoke all on tenant_private.order_reservations from public,anon,authenticated,service_role;
create function tenant_private.guard_reserved_quantity() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.quantity<old.quantity and new.quantity<(select coalesce(sum(units),0) from tenant_private.order_reservations where store_id=new.store_id and product_id=new.id) then raise exception 'Stock reserved for dispatched orders' using errcode='22023';end if;return new;
end $$;
create trigger mt_guard_reserved_quantity before update of quantity on public.mt_products for each row execute function tenant_private.guard_reserved_quantity();
create function tenant_private.guard_reserved_price() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' and old.price_minor=new.price_minor and old.currency=new.currency and old.product_id=new.product_id and old.store_id=new.store_id then return new;end if;
 if exists(select 1 from tenant_private.order_reservations where store_id=old.store_id and product_id=old.product_id and currency=old.currency) then raise exception 'Price locked by dispatched order' using errcode='22023';end if;
 if tg_op='DELETE' then return old;end if;return new;
end $$;
create trigger mt_guard_reserved_price before update or delete on public.mt_product_prices for each row execute function tenant_private.guard_reserved_price();
create function tenant_private.delivery_enable(p_store uuid,p_enabled boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if p_enabled is null then raise exception 'Invalid setting' using errcode='22023';end if;
 insert into tenant_private.storefronts(store_id,delivery_enabled) values(p_store,p_enabled) on conflict(store_id) do update set delivery_enabled=excluded.delivery_enabled;return p_enabled;
end $$;
create function tenant_private.delivery_available(p_slug text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.saas_stores s join tenant_private.storefronts f on f.store_id=s.id where s.slug=p_slug and f.delivery_enabled and tenant_private.storefront_active(s.id))
$$;
create function tenant_private.delivery_order(p_slug text,p_request uuid,p_currency text,p_lines jsonb,p_address text,p_phone text) returns uuid language plpgsql security definer set search_path='' as $$
declare t uuid;oid uuid;o public.mt_online_orders%rowtype;existing boolean;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 if p_address is null or length(btrim(p_address)) not between 5 and 400 or p_phone is null or length(btrim(p_phone)) not between 5 and 40 then raise exception 'Invalid delivery contact' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug for update;
 if not found then raise exception 'Store unavailable' using errcode='22023';end if;
 existing:=exists(select 1 from public.mt_online_orders where store_id=t and buyer=auth.uid() and request_id=p_request);
 if not existing and not tenant_private.delivery_available(p_slug) then raise exception 'Delivery unavailable' using errcode='22023';end if;
 oid:=tenant_private.online_order(p_slug,p_request,p_currency,p_lines);
 select * into strict o from public.mt_online_orders where store_id=t and id=oid;
 if existing then
  if o.delivery_method<>'delivery' or o.delivery_address<>btrim(p_address) or o.delivery_phone<>btrim(p_phone) then raise exception 'Conflicting delivery request' using errcode='22023';end if;return oid;
 end if;
 update public.mt_online_orders set delivery_method='delivery',delivery_state='requested',delivery_address=btrim(p_address),delivery_phone=btrim(p_phone) where store_id=t and id=oid;return oid;
end $$;
create function tenant_private.dispatch_delivery(p_store uuid,p_order uuid,p_tracking text) returns text language plpgsql security definer set search_path='' as $$
declare o public.mt_online_orders%rowtype;x jsonb;pid uuid;u bigint;qty bigint;price bigint;
begin
 perform tenant_private.owner_write(p_store);
 if p_tracking is null or length(btrim(p_tracking)) not between 1 and 100 then raise exception 'Invalid tracking reference' using errcode='22023';end if;
 select * into o from public.mt_online_orders where store_id=p_store and id=p_order for update;
 if not found or o.delivery_method<>'delivery' or o.state<>'pending' then raise exception 'Pending delivery required' using errcode='22023';end if;
 if o.delivery_state='dispatched' then
  if o.tracking_reference<>btrim(p_tracking) then raise exception 'Tracking already fixed' using errcode='22023';end if;return 'dispatched';
 end if;
 for x in select value from jsonb_array_elements(o.lines) loop
  pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;
  select quantity into qty from public.mt_products where store_id=p_store and id=pid for update;
  if not found or qty-(select coalesce(sum(units),0) from tenant_private.order_reservations where store_id=p_store and product_id=pid)<u then raise exception 'Insufficient available stock' using errcode='22023';end if;
  select price_minor into price from public.mt_product_prices where store_id=p_store and product_id=pid and currency=o.currency;
  if not found or price<>(x->>'expected_price_minor')::bigint then raise exception 'Quoted price changed' using errcode='22023';end if;
  insert into tenant_private.order_reservations(store_id,order_id,product_id,currency,units) values(p_store,p_order,pid,o.currency,u);
 end loop;
 update public.mt_online_orders set delivery_state='dispatched',tracking_reference=btrim(p_tracking) where store_id=p_store and id=p_order;return 'dispatched';
end $$;
create function tenant_private.cancel_dispatched_delivery(p_store uuid,p_order uuid,p_confirm boolean) returns text language plpgsql security definer set search_path='' as $$
declare o public.mt_online_orders%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_confirm is distinct from true then raise exception 'Confirm physical return of all goods' using errcode='22023';end if;
 select * into o from public.mt_online_orders where store_id=p_store and id=p_order for update;
 if not found or o.delivery_method<>'delivery' then raise exception 'Invalid delivery' using errcode='22023';end if;
 if o.state='cancelled' then return 'cancelled';end if;
 if o.state<>'pending' or o.delivery_state<>'dispatched' then raise exception 'Dispatched delivery required' using errcode='22023';end if;
 delete from tenant_private.order_reservations where store_id=p_store and order_id=p_order;
 update public.mt_online_orders set state='cancelled',delivery_state='cancelled',finished_by=auth.uid(),finished_at=now() where store_id=p_store and id=p_order;return 'cancelled';
end $$;
create or replace function tenant_private.finish_order(p_store uuid,p_order uuid,p_action text) returns uuid
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
  if o.delivery_method='delivery' and o.delivery_state<>'dispatched' then raise exception 'Dispatch delivery first' using errcode='22023';end if;
  delete from tenant_private.order_reservations where store_id=p_store and order_id=p_order;
  -- Owner confirms actual cash at pickup or delivery; current stock and quoted price checked by core.
  r:=tenant_private.record_currency_sale(p_store,gen_random_uuid(),o.currency,o.lines);
  update public.mt_online_orders set state='fulfilled',delivery_state=case when delivery_method='delivery' then 'delivered' else null end,sale_id=(r->>'id')::uuid,finished_by=auth.uid(),finished_at=now() where store_id=p_store and id=p_order;
  return (r->>'id')::uuid;
 end if;
 if o.state='cancelled' then return null;end if;
 if o.state<>'pending' then raise exception 'Completed order cannot be cancelled' using errcode='22023';end if;
 if o.delivery_state='dispatched' then raise exception 'Owner must confirm physical return before cancellation' using errcode='22023';end if;
 update public.mt_online_orders set state='cancelled',delivery_state=case when delivery_method='delivery' then 'cancelled' else null end,finished_by=auth.uid(),finished_at=now() where store_id=p_store and id=p_order;
 return null;
end $$;
create or replace function tenant_private.my_online_orders(p_slug text,p_after uuid,p_limit integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;t uuid;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 if p_slug is null or p_slug !~ '^[a-z][a-z0-9-]{2,39}$' or p_limit is null or p_limit not between 1 and 50 then raise exception 'Invalid order page' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug;
 select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb) into r from (select store_id,id,request_id,currency,total_minor,state,sale_id,created_at,delivery_method,delivery_state,tracking_reference from public.mt_online_orders where store_id=t and buyer=auth.uid() and (p_after is null or id>p_after) order by id limit p_limit) x;return r;
end $$;
create function public.mt_delivery_enable(p_store uuid,p_enabled boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.delivery_enable(p_store,p_enabled)$$;
create function public.mt_delivery_available(p_slug text) returns boolean language sql stable security invoker set search_path='' as $$select tenant_private.delivery_available(p_slug)$$;
create function public.mt_delivery_order(p_slug text,p_request uuid,p_currency text,p_lines jsonb,p_address text,p_phone text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.delivery_order(p_slug,p_request,p_currency,p_lines,p_address,p_phone)$$;
create function public.mt_dispatch_delivery(p_store uuid,p_order uuid,p_tracking text) returns text language sql security invoker set search_path='' as $$select tenant_private.dispatch_delivery(p_store,p_order,p_tracking)$$;
create function public.mt_cancel_dispatched_delivery(p_store uuid,p_order uuid,p_confirm boolean) returns text language sql security invoker set search_path='' as $$select tenant_private.cancel_dispatched_delivery(p_store,p_order,p_confirm)$$;
revoke all on function tenant_private.guard_reserved_quantity(),tenant_private.guard_reserved_price(),tenant_private.delivery_enable(uuid,boolean),tenant_private.delivery_available(text),tenant_private.delivery_order(text,uuid,text,jsonb,text,text),tenant_private.dispatch_delivery(uuid,uuid,text),tenant_private.cancel_dispatched_delivery(uuid,uuid,boolean),public.mt_delivery_enable(uuid,boolean),public.mt_delivery_available(text),public.mt_delivery_order(text,uuid,text,jsonb,text,text),public.mt_dispatch_delivery(uuid,uuid,text),public.mt_cancel_dispatched_delivery(uuid,uuid,boolean) from public,anon,authenticated,service_role;
grant execute on function tenant_private.delivery_enable(uuid,boolean),tenant_private.delivery_order(text,uuid,text,jsonb,text,text),tenant_private.dispatch_delivery(uuid,uuid,text),tenant_private.cancel_dispatched_delivery(uuid,uuid,boolean),public.mt_delivery_enable(uuid,boolean),public.mt_delivery_order(text,uuid,text,jsonb,text,text),public.mt_dispatch_delivery(uuid,uuid,text),public.mt_cancel_dispatched_delivery(uuid,uuid,boolean) to authenticated;
grant execute on function tenant_private.delivery_available(text),public.mt_delivery_available(text) to anon,authenticated;
commit;