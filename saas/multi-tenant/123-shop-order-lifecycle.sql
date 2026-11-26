-- 123: order confirmation, purchase-time item names, authenticated order details, central stock.
begin;
create table tenant_private.shop_order_confirmations(
 store_id uuid not null references tenant_private.workspaces(store_id),channel text not null check(channel in ('online','guest')),order_id uuid not null,actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,channel,order_id)
);
create table tenant_private.shop_order_items(
 store_id uuid not null references tenant_private.workspaces(store_id),channel text not null check(channel in ('online','guest')),order_id uuid not null,product_id uuid not null,product_name text not null,sku text not null,primary key(store_id,channel,order_id,product_id)
);
create table tenant_private.shop_order_history(
 store_id uuid not null references tenant_private.workspaces(store_id),channel text not null check(channel in ('online','guest')),order_id uuid not null,id uuid not null default gen_random_uuid(),event text not null check(event in ('pending','confirmed','dispatched','fulfilled','cancelled')),actor uuid,created_at timestamptz not null default now(),primary key(store_id,channel,order_id,id)
);
create index shop_order_history_order on tenant_private.shop_order_history(store_id,channel,order_id,created_at,id);
alter table tenant_private.shop_order_confirmations enable row level security;
alter table tenant_private.shop_order_items enable row level security;
alter table tenant_private.shop_order_history enable row level security;
revoke all on tenant_private.shop_order_confirmations,tenant_private.shop_order_items,tenant_private.shop_order_history from public,anon,authenticated;

create function tenant_private.capture_shop_order()
returns trigger language plpgsql security definer set search_path='' as $$
declare ch text:=case when tg_table_name='mt_online_orders' then 'online' else 'guest' end;ev text;
begin
 if tg_op='INSERT' then
 insert into tenant_private.shop_order_items(store_id,channel,order_id,product_id,product_name,sku)
 select new.store_id,ch,new.id,p.id,p.name,p.sku from jsonb_array_elements(new.lines) x join public.mt_products p on p.store_id=new.store_id and p.id=(x->>'product_id')::uuid;
 ev:='pending';
 elsif new.state is distinct from old.state then ev:=new.state;
 elsif ch='online' then
  if (to_jsonb(new)->>'delivery_state')='dispatched' and (to_jsonb(old)->>'delivery_state') is distinct from 'dispatched' then ev:='dispatched';end if;
 end if;
 if ev is not null then insert into tenant_private.shop_order_history(store_id,channel,order_id,event,actor) values(new.store_id,ch,new.id,ev,auth.uid());end if;
 return new;
end $$;
revoke all on function tenant_private.capture_shop_order() from public,anon,authenticated;
create trigger mt_shop_order_history after insert or update on public.mt_online_orders for each row execute function tenant_private.capture_shop_order();
create trigger mt_guest_order_history after insert or update on tenant_private.guest_orders for each row execute function tenant_private.capture_shop_order();

create function tenant_private.check_shop_order_stock(s uuid,c text,items jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare x jsonb;pid uuid;units bigint;price bigint;
begin
 for x in select value from jsonb_array_elements(items) loop
  pid:=(x->>'product_id')::uuid;units:=(x->>'units')::bigint;
  select price_minor into price from public.mt_product_prices where store_id=s and product_id=pid and currency=c;
  if not found or price is distinct from (x->>'expected_price_minor')::bigint or coalesce(tenant_private.main_available(s,pid),0)<units then raise exception 'Price or central stock changed' using errcode='22023';end if;
 end loop;
end $$;
revoke all on function tenant_private.check_shop_order_stock(uuid,text,jsonb) from public,anon,authenticated;

create function tenant_private.confirm_shop_order(s uuid,o uuid,ch text)
returns boolean language plpgsql security definer set search_path='' as $$
declare st text;c text;items jsonb;
begin
 perform tenant_private.owner_write(s);
 if o is null or ch is null or ch not in ('online','guest') then raise exception 'Invalid order' using errcode='22023';end if;
 if exists(select 1 from tenant_private.shop_order_confirmations where store_id=s and channel=ch and order_id=o) then return true;end if;
 if ch='online' then select state,currency,lines into st,c,items from public.mt_online_orders where store_id=s and id=o;
 else select state,currency,lines into st,c,items from tenant_private.guest_orders where store_id=s and id=o;end if;
 if not found or st<>'pending' then raise exception 'Pending order required' using errcode='22023';end if;
 perform tenant_private.check_shop_order_stock(s,c,items);
 insert into tenant_private.shop_order_confirmations(store_id,channel,order_id,actor) values(s,ch,o,auth.uid());
 insert into tenant_private.shop_order_history(store_id,channel,order_id,event,actor) values(s,ch,o,'confirmed',auth.uid());
 return true;
end $$;
CREATE OR REPLACE FUNCTION tenant_private.dispatch_delivery(p_store uuid, p_order uuid, p_tracking text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.mt_online_orders%rowtype;x jsonb;pid uuid;u bigint;qty bigint;price bigint;
begin
 perform tenant_private.owner_write(p_store);
 if p_tracking is null or length(btrim(p_tracking)) not between 1 and 100 then raise exception 'Invalid tracking reference' using errcode='22023';end if;
 select * into o from public.mt_online_orders where store_id=p_store and id=p_order for update;
 if not found or o.delivery_method<>'delivery' or o.state<>'pending' then raise exception 'Pending delivery required' using errcode='22023';end if;
 if o.delivery_state='dispatched' then
  if o.tracking_reference<>btrim(p_tracking) then raise exception 'Tracking already fixed' using errcode='22023';end if;return 'dispatched';
 end if;
 perform tenant_private.confirm_shop_order(p_store,p_order,'online');
 for x in select value from jsonb_array_elements(o.lines) loop
  pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;
  select quantity into qty from public.mt_products where store_id=p_store and id=pid for update;
  if not found or coalesce(tenant_private.main_available(p_store,pid),0)<u then raise exception 'Insufficient available stock' using errcode='22023';end if;
  select price_minor into price from public.mt_product_prices where store_id=p_store and product_id=pid and currency=o.currency;
  if not found or price<>(x->>'expected_price_minor')::bigint then raise exception 'Quoted price changed' using errcode='22023';end if;
  insert into tenant_private.order_reservations(store_id,order_id,product_id,currency,units) values(p_store,p_order,pid,o.currency,u);
 end loop;
 update public.mt_online_orders set delivery_state='dispatched',tracking_reference=btrim(p_tracking) where store_id=p_store and id=p_order;return 'dispatched';
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.finish_order_with_invoice(p_store uuid, p_order uuid, p_action text, p_meta jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if o.state='fulfilled' then perform tenant_private.channel_invoice_retry(p_store,o.sale_id,'online',p_order,p_meta);return o.sale_id;end if;
  if o.state<>'pending' then raise exception 'Order not pending' using errcode='22023';end if;
  if o.delivery_method='delivery' and o.delivery_state<>'dispatched' then raise exception 'Dispatch delivery first' using errcode='22023';end if;
  if o.delivery_state is distinct from 'dispatched' and not exists(select 1 from tenant_private.shop_order_confirmations where store_id=p_store and channel='online' and order_id=p_order) then raise exception 'Confirm order before fulfillment' using errcode='22023';end if;
  delete from tenant_private.order_reservations where store_id=p_store and order_id=p_order;
  perform tenant_private.check_shop_order_stock(p_store,o.currency,o.lines);
  -- Owner confirms actual cash at pickup or delivery; current stock and quoted price checked by core.
  if exists(select 1 from tenant_private.order_discounts where store_id=p_store and order_id=p_order) then r:=tenant_private.record_discounted_order_sale(p_store,p_order);else r:=tenant_private.record_currency_sale(p_store,gen_random_uuid(),o.currency,o.lines);end if;
  perform tenant_private.snapshot_channel_invoice(p_store,(r->>'id')::uuid,'online',p_order,p_meta,null,nullif(o.delivery_phone,''));
  update public.mt_online_orders set state='fulfilled',delivery_state=case when delivery_method='delivery' then 'delivered' else null end,sale_id=(r->>'id')::uuid,finished_by=auth.uid(),finished_at=now() where store_id=p_store and id=p_order;
  return (r->>'id')::uuid;
 end if;
 if p_meta is not null then raise exception 'Cancellation cannot issue invoice';end if;
 if o.state='cancelled' then return null;end if;
 if o.state<>'pending' then raise exception 'Completed order cannot be cancelled' using errcode='22023';end if;
 if o.delivery_state='dispatched' then raise exception 'Owner must confirm physical return before cancellation' using errcode='22023';end if;
 update public.mt_online_orders set state='cancelled',delivery_state=case when delivery_method='delivery' then 'cancelled' else null end,finished_by=auth.uid(),finished_at=now() where store_id=p_store and id=p_order;
 return null;
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.guest_finish_with_invoice(p_store uuid, p_id uuid, p_action text, p_confirm boolean, p_meta jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o tenant_private.guest_orders%rowtype;r jsonb;sid uuid;begin
 perform tenant_private.owner_write(p_store);
 if p_action is null or p_action not in ('cancel','fulfill') or p_confirm is distinct from true then raise exception 'Confirm action' using errcode='22023';end if;
 select * into o from tenant_private.guest_orders where store_id=p_store and id=p_id for update;
 if not found then raise exception 'Unknown order' using errcode='22023';end if;
 if p_action='cancel' and p_meta is not null then raise exception 'Cancellation cannot issue invoice';end if;
 if o.state='fulfilled' and p_action='fulfill' then perform tenant_private.channel_invoice_retry(p_store,o.sale_id,'guest',p_id,p_meta);return p_id;end if;
 if o.state='cancelled' and p_action='cancel' then return p_id;end if;
 if o.state<>'pending' then raise exception 'Order already closed' using errcode='22023';end if;
 if p_action='fulfill' then
 if not exists(select 1 from tenant_private.shop_order_confirmations where store_id=p_store and channel='guest' and order_id=p_id) then raise exception 'Confirm order before fulfillment' using errcode='22023';end if;
 perform tenant_private.check_shop_order_stock(p_store,o.currency,o.lines);
 if exists(select 1 from public.mt_sales where store_id=p_store and request_id=p_id) then raise exception 'Conflicting sale request' using errcode='22023';end if;
 r:=tenant_private.record_currency_sale(p_store,p_id,o.currency,o.lines);sid:=(r->>'id')::uuid;
 if (r->>'total_minor')::bigint<>o.total_minor then raise exception 'Order total changed' using errcode='22023';end if;
 perform tenant_private.snapshot_channel_invoice(p_store,sid,'guest',p_id,p_meta,o.customer_name,o.phone);
 end if;
 update tenant_private.guest_orders set state=case when p_action='fulfill' then 'fulfilled' else 'cancelled' end,sale_id=sid,finished_at=now() where store_id=p_store and id=p_id;return p_id;
end
$function$
;

CREATE OR REPLACE FUNCTION tenant_private.online_order(p_slug text, p_request uuid, p_currency text, p_lines jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if not found or coalesce(tenant_private.main_available(t,product),0)<u then raise exception 'Product unavailable' using errcode='22023';end if;
  select price_minor into price from public.mt_product_prices where store_id=t and product_id=product and currency=p_currency;
  if not found or price<>(x->>'expected_price_minor')::bigint then raise exception 'Price changed' using errcode='22023';end if;
  total:=total+u*price;
 end loop;
 insert into public.mt_online_orders(store_id,request_id,buyer,currency,lines,total_minor) values(t,p_request,auth.uid(),p_currency,norm,total) returning * into o;
 return o.id;
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.public_catalog(p_slug text, p_currency text, p_after uuid, p_limit integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid;n text;r jsonb;
begin
 if p_slug is null or p_slug !~ '^[a-z][a-z0-9-]{2,39}$' or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_limit is null or p_limit not between 1 and 50 then raise exception 'Invalid catalog query' using errcode='22023';end if;
 select s.id,s.name into t,n from public.saas_stores s where s.slug=p_slug and tenant_private.storefront_active(s.id);
 if not found then return null;end if;
 select jsonb_build_object('name',n,'slug',p_slug,'currency',p_currency,'products',coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb)) into r from (select p.id,p.name,p.sku,pp.price_minor from public.mt_products p join tenant_private.storefront_products l on l.store_id=p.store_id and l.product_id=p.id and l.listed join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=t and tenant_private.main_available(t,p.id)>0 and (p_after is null or p.id>p_after) order by p.id limit p_limit) x;
 return r;
end $function$
;

CREATE OR REPLACE FUNCTION tenant_private.record_discounted_order_sale(p_store uuid, p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.mt_online_orders%rowtype;d tenant_private.order_discounts%rowtype;v_settings tenant_private.sales_settings%rowtype;s public.mt_sales%rowtype;x jsonb;pr public.mt_products%rowtype;pid uuid;u bigint;price bigint;net bigint;total bigint:=0;
begin
 perform tenant_private.owner_write(p_store);
 select * into strict o from public.mt_online_orders where store_id=p_store and id=p_order and state='pending';
 select * into strict d from tenant_private.order_discounts where store_id=p_store and order_id=p_order;
 select * into strict v_settings from tenant_private.sales_settings where store_id=p_store for update;
 for x in select value from jsonb_array_elements(o.lines) loop
  pid:=(x->>'product_id')::uuid;u:=(x->>'units')::bigint;
  select * into pr from public.mt_products where store_id=p_store and id=pid for update;
  if not found or coalesce(tenant_private.main_available(p_store,pid),0)<u then raise exception 'Insufficient stock' using errcode='22023';end if;
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
end $function$
;

create function tenant_private.shop_order_details(s uuid,o uuid,ch text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.mt_online_orders%rowtype;g tenant_private.guest_orders%rowtype;d tenant_private.order_discounts%rowtype;owner boolean;items jsonb;details jsonb;history jsonb;v jsonb;
begin
 if not coalesce(saas_private.live_session(),false) then raise exception 'Live session required' using errcode='42501';end if;
 owner:=tenant_private.member_role(s) is not distinct from 'owner';
 if ch='online' then
  select * into a from public.mt_online_orders where store_id=s and id=o;
  if not found or not (owner or a.buyer=auth.uid()) then raise exception 'Order unavailable' using errcode='42501';end if;
  items:=a.lines;
  select * into d from tenant_private.order_discounts where store_id=s and order_id=o;
  v:=jsonb_build_object('id',a.id,'currency',a.currency,'state',a.state,'total_minor',a.total_minor,'delivery_method',a.delivery_method,'delivery_state',a.delivery_state,'tracking_reference',a.tracking_reference,'address',a.delivery_address,'phone',a.delivery_phone,'created_at',a.created_at,'finished_at',a.finished_at,'sale_id',a.sale_id,'discount_minor',coalesce(d.discount_minor,0),'gross_minor',coalesce(d.gross_minor,a.total_minor));
 elsif ch='guest' and owner then
  select * into g from tenant_private.guest_orders where store_id=s and id=o;
  if not found then raise exception 'Order unavailable' using errcode='42501';end if;
  items:=g.lines;
  v:=jsonb_build_object('id',g.id,'currency',g.currency,'state',g.state,'total_minor',g.total_minor,'delivery_method','pickup','delivery_state',null,'tracking_reference',null,'address',null,'phone',g.phone,'customer_name',g.customer_name,'created_at',g.created_at,'finished_at',g.finished_at,'sale_id',g.sale_id,'discount_minor',0,'gross_minor',g.total_minor);
 else raise exception 'Order unavailable' using errcode='42501';end if;
 select coalesce(jsonb_agg(jsonb_build_object('product_id',(x->>'product_id')::uuid,'name',coalesce(i.product_name,p.name,x->>'product_id'),'sku',coalesce(i.sku,p.sku,''),'snapshot',i.product_id is not null,'units',(x->>'units')::bigint,'unit_minor',(x->>'expected_price_minor')::bigint,'net_minor',case when d.order_id is null then (x->>'expected_price_minor')::bigint when d.line_prices is not null then (d.line_prices->>(x->>'product_id'))::bigint else (x->>'expected_price_minor')::bigint-(x->>'expected_price_minor')::bigint*d.basis_points/10000 end) order by x->>'product_id'),'[]'::jsonb) into details from jsonb_array_elements(items) x left join tenant_private.shop_order_items i on i.store_id=s and i.channel=ch and i.order_id=o and i.product_id=(x->>'product_id')::uuid left join public.mt_products p on p.store_id=s and p.id=(x->>'product_id')::uuid;
 select coalesce(jsonb_agg(jsonb_build_object('event',event,'created_at',created_at) order by created_at,id),'[]'::jsonb) into history from tenant_private.shop_order_history where store_id=s and channel=ch and order_id=o;
 return v||jsonb_build_object('channel',ch,'confirmed',exists(select 1 from tenant_private.shop_order_confirmations where store_id=s and channel=ch and order_id=o),'items',details,'history',history);
end $$;

create or replace function tenant_private.guest_track(p_slug text,p_code uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;
begin
 select jsonb_build_object('state',g.state,'total_minor',g.total_minor,'currency',g.currency,'created_at',g.created_at,'finished_at',g.finished_at,'confirmed',exists(select 1 from tenant_private.shop_order_confirmations c where c.store_id=g.store_id and c.channel='guest' and c.order_id=g.id)) into r from tenant_private.guest_orders g join public.saas_stores s on s.id=g.store_id where s.slug=p_slug and g.code=p_code and tenant_private.storefront_active(s.id);return r;
end $$;

create function public.mt_confirm_shop_order(s uuid,o uuid,ch text) returns boolean language sql set search_path='' as $$select tenant_private.confirm_shop_order(s,o,ch)$$;
create function public.mt_shop_order_details(s uuid,o uuid,ch text) returns jsonb language sql stable set search_path='' as $$select tenant_private.shop_order_details(s,o,ch)$$;
revoke all on function tenant_private.confirm_shop_order(uuid,uuid,text),public.mt_confirm_shop_order(uuid,uuid,text) from public,anon,authenticated;
grant execute on function tenant_private.confirm_shop_order(uuid,uuid,text),public.mt_confirm_shop_order(uuid,uuid,text) to authenticated;
revoke all on function tenant_private.shop_order_details(uuid,uuid,text),public.mt_shop_order_details(uuid,uuid,text) from public,anon,authenticated;
grant execute on function tenant_private.shop_order_details(uuid,uuid,text),public.mt_shop_order_details(uuid,uuid,text) to authenticated;
commit;
