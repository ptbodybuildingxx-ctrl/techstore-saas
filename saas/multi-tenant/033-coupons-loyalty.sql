begin;
create table public.mt_coupons(
 store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null default gen_random_uuid(),request_id uuid not null,code text not null check(code ~ '^[A-Z0-9-]{3,24}$'),
 basis_points integer not null check(basis_points between 100 and 5000),min_prior_orders integer not null check(min_prior_orders between 0 and 100),max_uses integer not null check(max_uses between 1 and 10000),
 expires_at timestamptz not null,enabled boolean not null default true,actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),unique(store_id,request_id),unique(store_id,code)
);
create table tenant_private.order_discounts(
 store_id uuid not null,order_id uuid not null,coupon_id uuid not null,buyer uuid not null,basis_points integer not null check(basis_points between 100 and 5000),
 gross_minor bigint not null check(gross_minor>0),discount_minor bigint not null check(discount_minor>0 and discount_minor<gross_minor),
 primary key(store_id,order_id),foreign key(store_id,order_id) references public.mt_online_orders(store_id,id),foreign key(store_id,coupon_id) references public.mt_coupons(store_id,id)
);
create index mt_order_discounts_coupon on tenant_private.order_discounts(store_id,coupon_id,buyer);
alter table public.mt_coupons enable row level security;alter table tenant_private.order_discounts enable row level security;
revoke all on public.mt_coupons,tenant_private.order_discounts from public,anon,authenticated,service_role;
grant select on public.mt_coupons to authenticated;
create policy owner_read on public.mt_coupons for select to authenticated using(tenant_private.member_role(store_id)='owner');
create function tenant_private.loyalty_orders(p_store uuid,p_buyer uuid) returns bigint language sql stable security definer set search_path='' as $$
 select count(*) from public.mt_online_orders o where o.store_id=p_store and o.buyer=p_buyer and o.state='fulfilled' and o.total_minor>(select coalesce(sum(r.total_minor),0) from public.mt_returns r where r.store_id=o.store_id and r.sale_id=o.sale_id)
$$;
create function tenant_private.coupon_available(p_store uuid,p_code text,p_buyer uuid) returns public.mt_coupons language plpgsql stable security definer set search_path='' as $$
declare c public.mt_coupons%rowtype;
begin
 select * into c from public.mt_coupons where store_id=p_store and code=upper(btrim(p_code)) and enabled and expires_at>now();
 if not found or tenant_private.loyalty_orders(p_store,p_buyer)<c.min_prior_orders or (select count(*) from tenant_private.order_discounts d join public.mt_online_orders o on o.store_id=d.store_id and o.id=d.order_id where d.store_id=p_store and d.coupon_id=c.id and o.state<>'cancelled')>=c.max_uses or exists(select 1 from tenant_private.order_discounts d join public.mt_online_orders o on o.store_id=d.store_id and o.id=d.order_id where d.store_id=p_store and d.coupon_id=c.id and d.buyer=p_buyer and o.state<>'cancelled') then raise exception 'Coupon unavailable' using errcode='22023';end if;
 return c;
end $$;
create function tenant_private.add_coupon(p_store uuid,p_request uuid,p_code text,p_bps integer,p_min integer,p_max integer,p_expires timestamptz) returns uuid language plpgsql security definer set search_path='' as $$
declare c public.mt_coupons%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_code is null or upper(btrim(p_code)) !~ '^[A-Z0-9-]{3,24}$' or p_bps is null or p_bps not between 100 and 5000 or p_min is null or p_min not between 0 and 100 or p_max is null or p_max not between 1 and 10000 or p_expires is null then raise exception 'Invalid coupon' using errcode='22023';end if;
 select * into c from public.mt_coupons where store_id=p_store and request_id=p_request;
 if found then
  if c.actor<>auth.uid() or c.code<>upper(btrim(p_code)) or c.basis_points<>p_bps or c.min_prior_orders<>p_min or c.max_uses<>p_max or c.expires_at<>p_expires then raise exception 'Conflicting coupon request' using errcode='22023';end if;return c.id;
 end if;
 if p_expires<=now() or p_expires>now()+interval '366 days' then raise exception 'Invalid expiry' using errcode='22023';end if;
 insert into public.mt_coupons(store_id,request_id,code,basis_points,min_prior_orders,max_uses,expires_at,actor) values(p_store,p_request,upper(btrim(p_code)),p_bps,p_min,p_max,p_expires,auth.uid()) returning * into c;return c.id;
end $$;
create function tenant_private.coupon_enable(p_store uuid,p_coupon uuid,p_enabled boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);if p_enabled is null then raise exception 'Invalid flag' using errcode='22023';end if;
 update public.mt_coupons set enabled=p_enabled where store_id=p_store and id=p_coupon;if not found then raise exception 'Unknown coupon' using errcode='22023';end if;return p_enabled;
end $$;
create function tenant_private.buyer_loyalty(p_slug text,p_code text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid;c public.mt_coupons%rowtype;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 select id into t from public.saas_stores where slug=p_slug;if t is null or not tenant_private.storefront_active(t) then raise exception 'Store unavailable' using errcode='22023';end if;
 if p_code is not null then c:=tenant_private.coupon_available(t,p_code,auth.uid());end if;
 return jsonb_build_object('eligible_orders',tenant_private.loyalty_orders(t,auth.uid()),'basis_points',c.basis_points);
end $$;
create function tenant_private.discount_order(p_slug text,p_request uuid,p_currency text,p_lines jsonb,p_code text,p_expected_total bigint,p_address text,p_phone text) returns uuid language plpgsql security definer set search_path='' as $$
declare t uuid;oid uuid;o public.mt_online_orders%rowtype;d tenant_private.order_discounts%rowtype;c public.mt_coupons%rowtype;discount bigint;existing boolean;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live account required' using errcode='42501';end if;
 if p_code is null or upper(btrim(p_code)) !~ '^[A-Z0-9-]{3,24}$' or p_expected_total is null or p_expected_total<1 or (p_address is null)<>(p_phone is null) then raise exception 'Invalid coupon order' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug for update;if not found then raise exception 'Store unavailable' using errcode='22023';end if;
 existing:=exists(select 1 from public.mt_online_orders where store_id=t and buyer=auth.uid() and request_id=p_request);
 if p_address is null then oid:=tenant_private.online_order(p_slug,p_request,p_currency,p_lines);else oid:=tenant_private.delivery_order(p_slug,p_request,p_currency,p_lines,p_address,p_phone);end if;
 select * into strict o from public.mt_online_orders where store_id=t and id=oid;
 if o.delivery_method<>(case when p_address is null then 'pickup' else 'delivery' end) then raise exception 'Conflicting delivery method' using errcode='22023';end if;
 if existing then
  select * into d from tenant_private.order_discounts where store_id=t and order_id=oid;
  if not found or o.total_minor<>p_expected_total or not exists(select 1 from public.mt_coupons where store_id=t and id=d.coupon_id and code=upper(btrim(p_code))) then raise exception 'Conflicting coupon request' using errcode='22023';end if;return oid;
 end if;
 c:=tenant_private.coupon_available(t,p_code,auth.uid());
 select sum((x->>'units')::bigint*((x->>'expected_price_minor')::bigint*c.basis_points/10000)) into discount from jsonb_array_elements(o.lines)x;
 if discount is null or discount<=0 or o.total_minor-discount<>p_expected_total then raise exception 'Discount quote changed' using errcode='22023';end if;
 insert into tenant_private.order_discounts(store_id,order_id,coupon_id,buyer,basis_points,gross_minor,discount_minor) values(t,oid,c.id,auth.uid(),c.basis_points,o.total_minor,discount);
 update public.mt_online_orders set total_minor=total_minor-discount where store_id=t and id=oid;return oid;
end $$;
-- Only called by owner fulfillment under the existing store lock. All amounts derived from frozen order.
create function tenant_private.record_discounted_order_sale(p_store uuid,p_order uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.mt_online_orders%rowtype;d tenant_private.order_discounts%rowtype;v_settings tenant_private.sales_settings%rowtype;s public.mt_sales%rowtype;x jsonb;pr public.mt_products%rowtype;pid uuid;u bigint;price bigint;net bigint;total bigint:=0;
begin
 perform tenant_private.owner_write(p_store);
 select * into strict o from public.mt_online_orders where store_id=p_store and id=p_order and state='pending';
 select * into strict d from tenant_private.order_discounts where store_id=p_store and order_id=p_order;
 select * into strict v_settings from tenant_private.sales_settings where store_id=p_store for update;
 for x in select value from jsonb_array_elements(o.lines) loop
  pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;
  select * into pr from public.mt_products where store_id=p_store and id=pid for update;
  if not found or pr.quantity<u then raise exception 'Insufficient stock' using errcode='22023';end if;
  select price_minor into price from public.mt_product_prices where store_id=p_store and product_id=pid and currency=o.currency;
  if not found or price<>(x->>'expected_price_minor')::bigint then raise exception 'Price changed' using errcode='22023';end if;
  total:=total+u*(price-price*d.basis_points/10000);
 end loop;
 if total<>o.total_minor or total<>d.gross_minor-d.discount_minor then raise exception 'Discount invoice mismatch';end if;
 insert into public.mt_sales(store_id,number,request_id,actor,currency,total_minor,payment_mode) values(p_store,v_settings.next_number,gen_random_uuid(),auth.uid(),o.currency,total,'cash') returning * into s;
 update tenant_private.sales_settings set next_number=next_number+1 where store_id=p_store;
 for x in select value from jsonb_array_elements(o.lines) loop
  pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;price:=(x->>'expected_price_minor')::bigint;net:=price-price*d.basis_points/10000;
  update public.mt_products set quantity=quantity-u where store_id=p_store and id=pid returning * into pr;
  insert into public.mt_sale_lines(store_id,sale_id,product_id,sku,product_name,units,unit_price_minor) values(p_store,s.id,pid,pr.sku,pr.name,u,net);
  insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor,sale_id) values(p_store,gen_random_uuid(),pid,-u,pr.quantity,auth.uid(),s.id);
 end loop;
 insert into public.mt_cash_receipts(store_id,sale_id,currency,amount_minor) values(p_store,s.id,s.currency,total);
 return jsonb_build_object('id',s.id);
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
  if exists(select 1 from tenant_private.order_discounts where store_id=p_store and order_id=p_order) then r:=tenant_private.record_discounted_order_sale(p_store,p_order);else r:=tenant_private.record_currency_sale(p_store,gen_random_uuid(),o.currency,o.lines);end if;
  update public.mt_online_orders set state='fulfilled',delivery_state=case when delivery_method='delivery' then 'delivered' else null end,sale_id=(r->>'id')::uuid,finished_by=auth.uid(),finished_at=now() where store_id=p_store and id=p_order;
  return (r->>'id')::uuid;
 end if;
 if o.state='cancelled' then return null;end if;
 if o.state<>'pending' then raise exception 'Completed order cannot be cancelled' using errcode='22023';end if;
 if o.delivery_state='dispatched' then raise exception 'Owner must confirm physical return before cancellation' using errcode='22023';end if;
 update public.mt_online_orders set state='cancelled',delivery_state=case when delivery_method='delivery' then 'cancelled' else null end,finished_by=auth.uid(),finished_at=now() where store_id=p_store and id=p_order;
 return null;
end $$;
create function public.mt_add_coupon(p_store uuid,p_request uuid,p_code text,p_bps integer,p_min integer,p_max integer,p_expires timestamptz) returns uuid language sql security invoker set search_path='' as $$select tenant_private.add_coupon(p_store,p_request,p_code,p_bps,p_min,p_max,p_expires)$$;
create function public.mt_coupon_enable(p_store uuid,p_coupon uuid,p_enabled boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.coupon_enable(p_store,p_coupon,p_enabled)$$;
create function public.mt_buyer_loyalty(p_slug text,p_code text default null) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.buyer_loyalty(p_slug,p_code)$$;
create function public.mt_discount_order(p_slug text,p_request uuid,p_currency text,p_lines jsonb,p_code text,p_expected_total bigint,p_address text default null,p_phone text default null) returns uuid language sql security invoker set search_path='' as $$select tenant_private.discount_order(p_slug,p_request,p_currency,p_lines,p_code,p_expected_total,p_address,p_phone)$$;
create function public.mt_list_coupons(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.mt_coupons language plpgsql stable security invoker set search_path='' as $$
begin if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;return query select * from public.mt_coupons where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;end $$;
revoke all on function tenant_private.loyalty_orders(uuid,uuid),tenant_private.coupon_available(uuid,text,uuid),tenant_private.record_discounted_order_sale(uuid,uuid),tenant_private.add_coupon(uuid,uuid,text,integer,integer,integer,timestamptz),tenant_private.coupon_enable(uuid,uuid,boolean),tenant_private.buyer_loyalty(text,text),tenant_private.discount_order(text,uuid,text,jsonb,text,bigint,text,text),public.mt_add_coupon(uuid,uuid,text,integer,integer,integer,timestamptz),public.mt_coupon_enable(uuid,uuid,boolean),public.mt_buyer_loyalty(text,text),public.mt_discount_order(text,uuid,text,jsonb,text,bigint,text,text),public.mt_list_coupons(uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.add_coupon(uuid,uuid,text,integer,integer,integer,timestamptz),tenant_private.coupon_enable(uuid,uuid,boolean),tenant_private.buyer_loyalty(text,text),tenant_private.discount_order(text,uuid,text,jsonb,text,bigint,text,text),public.mt_add_coupon(uuid,uuid,text,integer,integer,integer,timestamptz),public.mt_coupon_enable(uuid,uuid,boolean),public.mt_buyer_loyalty(text,text),public.mt_discount_order(text,uuid,text,jsonb,text,bigint,text,text),public.mt_list_coupons(uuid,uuid,integer) to authenticated;
commit;