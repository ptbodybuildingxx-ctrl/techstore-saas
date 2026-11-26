-- Product-specific membership/wholesale prices. Buyer approval remains mandatory.
begin;
create table tenant_private.product_tier_prices(store_id uuid not null,product_id uuid not null,tier text not null check(tier in ('member','wholesale')),currency text not null,price_minor bigint not null check(price_minor between 1 and 100000000),min_units int not null check(min_units between 1 and 100),actor uuid not null,updated_at timestamptz not null default now(),primary key(store_id,product_id,tier,currency),foreign key(store_id,product_id) references public.mt_products(store_id,id),foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency));
alter table tenant_private.product_tier_prices enable row level security;revoke all on tenant_private.product_tier_prices from public,anon,authenticated,service_role;
alter table tenant_private.order_discounts add column line_prices jsonb check(line_prices is null or (price_tier is not null and jsonb_typeof(line_prices)='object'));
create function tenant_private.product_tier_set(p_store uuid,p_product uuid,p_tier text,p_currency text,p_price bigint,p_min int,p_enabled boolean) returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform tenant_private.owner_write(p_store);
 if p_tier is null or p_tier not in ('member','wholesale') or p_currency is null or p_enabled is null or not exists(select 1 from public.mt_products where store_id=p_store and id=p_product) then raise exception 'Invalid tier' using errcode='22023';end if;
 if not p_enabled then delete from tenant_private.product_tier_prices where store_id=p_store and product_id=p_product and tier=p_tier and currency=p_currency;return false;end if;
 if p_price is null or p_price not between 1 and 100000000 or p_min is null or p_min not between 1 and 100 or not exists(select 1 from public.mt_product_prices where store_id=p_store and product_id=p_product and currency=p_currency and price_minor>=p_price) then raise exception 'Tier price must not exceed list price' using errcode='22023';end if;
 insert into tenant_private.product_tier_prices(store_id,product_id,tier,currency,price_minor,min_units,actor) values(p_store,p_product,p_tier,p_currency,p_price,p_min,auth.uid()) on conflict(store_id,product_id,tier,currency) do update set price_minor=excluded.price_minor,min_units=excluded.min_units,actor=excluded.actor,updated_at=now();return true;
end $$;
create function tenant_private.product_tier_list(p_store uuid,p_product uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by tier,currency) from (select tier,currency,price_minor,min_units from tenant_private.product_tier_prices where store_id=p_store and product_id=p_product)x),'[]');
end $$;
create function tenant_private.product_tier_quote(p_slug text,p_currency text,p_lines jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid;v tenant_private.buyer_price_terms%rowtype;x jsonb;pid uuid;u bigint;retail bigint;net bigint;gross bigint:=0;total bigint:=0;units bigint:=0;prices jsonb:='{}';begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live buyer required' using errcode='42501';end if;
 if jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid cart' using errcode='22023';end if;
 if jsonb_array_length(p_lines) not between 1 and 50 or octet_length(p_lines::text)>30000 then raise exception 'Invalid cart' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug and tenant_private.storefront_active(id);
 select * into v from tenant_private.buyer_price_terms where store_id=t and buyer=auth.uid() and enabled;
 if not found then return null;end if;
 for x in select value from jsonb_array_elements(p_lines) loop
 if jsonb_typeof(x) is distinct from 'object' or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,3}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid line' using errcode='22023';end if;
 pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;
 if u not between 1 and 100 or prices ? pid::text then raise exception 'Invalid quantity or duplicate product' using errcode='22023';end if;
 select pp.price_minor into retail from public.mt_product_prices pp join tenant_private.storefront_products l on l.store_id=pp.store_id and l.product_id=pp.product_id and l.listed where pp.store_id=t and pp.product_id=pid and pp.currency=p_currency;
 if not found or retail<>(x->>'expected_price_minor')::bigint then raise exception 'List price changed' using errcode='22023';end if;
 select price_minor into net from tenant_private.product_tier_prices where store_id=t and product_id=pid and tier=v.tier and currency=p_currency and min_units<=u and price_minor<=retail;
 net:=coalesce(net,retail-retail*v.basis_points/10000);if net<1 then raise exception 'Invalid net price' using errcode='22023';end if;
 gross:=gross+retail*u;total:=total+net*u;units:=units+u;prices:=prices||jsonb_build_object(pid::text,net);
 end loop;
 if units<v.min_units or total>=gross then return null;end if;
 return jsonb_build_object('tier',v.tier,'basis_points',v.basis_points,'min_units',v.min_units,'prices',prices,'total_minor',total,'gross_minor',gross);
end $$;
create function tenant_private.product_tier_order(p_slug text,p_request uuid,p_currency text,p_lines jsonb,p_prices jsonb,p_expected_total bigint,p_address text,p_phone text) returns uuid language plpgsql security definer set search_path='' as $$
declare t uuid;oid uuid;o public.mt_online_orders%rowtype;d tenant_private.order_discounts%rowtype;q jsonb;existing boolean;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live buyer required' using errcode='42501';end if;
 if jsonb_typeof(p_prices) is distinct from 'object' or p_expected_total is null or p_expected_total<1 or (p_address is null)<>(p_phone is null) then raise exception 'Invalid price quote' using errcode='22023';end if;
 select id into t from public.saas_stores where slug=p_slug for update;if not found then raise exception 'Store unavailable' using errcode='22023';end if;
 existing:=exists(select 1 from public.mt_online_orders where store_id=t and buyer=auth.uid() and request_id=p_request);
 if p_address is null then oid:=tenant_private.online_order(p_slug,p_request,p_currency,p_lines);else oid:=tenant_private.delivery_order(p_slug,p_request,p_currency,p_lines,p_address,p_phone);end if;
 select * into strict o from public.mt_online_orders where store_id=t and id=oid;
 if o.delivery_method<>(case when p_address is null then 'pickup' else 'delivery' end) then raise exception 'Conflicting delivery method' using errcode='22023';end if;
 if existing then select * into d from tenant_private.order_discounts where store_id=t and order_id=oid;
 if not found or d.line_prices is distinct from p_prices or o.total_minor<>p_expected_total then raise exception 'Conflicting tier request' using errcode='22023';end if;return oid;end if;
 q:=tenant_private.product_tier_quote(p_slug,p_currency,o.lines);
 if q is null or q->'prices' is distinct from p_prices or (q->>'total_minor')::bigint<>p_expected_total or (q->>'gross_minor')::bigint<>o.total_minor then raise exception 'Tier quote changed' using errcode='22023';end if;
 insert into tenant_private.order_discounts(store_id,order_id,buyer,basis_points,gross_minor,discount_minor,price_tier,line_prices) values(t,oid,auth.uid(),(q->>'basis_points')::int,o.total_minor,o.total_minor-p_expected_total,q->>'tier',p_prices);
 update public.mt_online_orders set total_minor=p_expected_total where store_id=t and id=oid;return oid;
end $$;
create or replace function tenant_private.record_discounted_order_sale(p_store uuid,p_order uuid) returns jsonb language plpgsql security definer set search_path='' as $$
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
  net:=case when d.line_prices is null then price-price*d.basis_points/10000 else (d.line_prices->>pid::text)::bigint end;
  if net is null or net<1 or net>price then raise exception 'Invalid frozen tier price';end if;
  total:=total+u*net;
 end loop;
 if total<>o.total_minor or total<>d.gross_minor-d.discount_minor then raise exception 'Discount invoice mismatch';end if;
 insert into public.mt_sales(store_id,number,request_id,actor,currency,total_minor,payment_mode) values(p_store,v_settings.next_number,gen_random_uuid(),auth.uid(),o.currency,total,'cash') returning * into s;
 update tenant_private.sales_settings set next_number=next_number+1 where store_id=p_store;
 for x in select value from jsonb_array_elements(o.lines) loop
  pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;price:=(x->>'expected_price_minor')::bigint;net:=case when d.line_prices is null then price-price*d.basis_points/10000 else (d.line_prices->>pid::text)::bigint end;
  update public.mt_products set quantity=quantity-u where store_id=p_store and id=pid returning * into pr;
  insert into public.mt_sale_lines(store_id,sale_id,product_id,sku,product_name,units,unit_price_minor) values(p_store,s.id,pid,pr.sku,pr.name,u,net);
  insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor,sale_id) values(p_store,gen_random_uuid(),pid,-u,pr.quantity,auth.uid(),s.id);
 end loop;
 insert into public.mt_cash_receipts(store_id,sale_id,currency,amount_minor) values(p_store,s.id,s.currency,total);
 return jsonb_build_object('id',s.id);
end $$;
create function public.mt_product_tier_set(p_store uuid,p_product uuid,p_tier text,p_currency text,p_price bigint,p_min int,p_enabled boolean) returns boolean language sql security invoker set search_path='' as $$select tenant_private.product_tier_set(p_store,p_product,p_tier,p_currency,p_price,p_min,p_enabled)$$;
create function public.mt_product_tier_list(p_store uuid,p_product uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.product_tier_list(p_store,p_product)$$;
create function public.mt_product_tier_quote(p_slug text,p_currency text,p_lines jsonb) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.product_tier_quote(p_slug,p_currency,p_lines)$$;
create function public.mt_product_tier_order(p_slug text,p_request uuid,p_currency text,p_lines jsonb,p_prices jsonb,p_expected_total bigint,p_address text default null,p_phone text default null) returns uuid language sql security invoker set search_path='' as $$select tenant_private.product_tier_order(p_slug,p_request,p_currency,p_lines,p_prices,p_expected_total,p_address,p_phone)$$;
revoke all on function tenant_private.product_tier_set(uuid,uuid,text,text,bigint,int,boolean),tenant_private.product_tier_list(uuid,uuid),tenant_private.product_tier_quote(text,text,jsonb),tenant_private.product_tier_order(text,uuid,text,jsonb,jsonb,bigint,text,text),public.mt_product_tier_set(uuid,uuid,text,text,bigint,int,boolean),public.mt_product_tier_list(uuid,uuid),public.mt_product_tier_quote(text,text,jsonb),public.mt_product_tier_order(text,uuid,text,jsonb,jsonb,bigint,text,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.product_tier_set(uuid,uuid,text,text,bigint,int,boolean),tenant_private.product_tier_list(uuid,uuid),tenant_private.product_tier_quote(text,text,jsonb),tenant_private.product_tier_order(text,uuid,text,jsonb,jsonb,bigint,text,text),public.mt_product_tier_set(uuid,uuid,text,text,bigint,int,boolean),public.mt_product_tier_list(uuid,uuid),public.mt_product_tier_quote(text,text,jsonb),public.mt_product_tier_order(text,uuid,text,jsonb,jsonb,bigint,text,text) to authenticated;
commit;
