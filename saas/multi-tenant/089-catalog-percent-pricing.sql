-- Atomic currency-specific percentage pricing; preserve existing owner/license checks and request replay.
create or replace function tenant_private.catalog_bulk(p_store uuid,p_request uuid,p_products uuid[],p_action text,p_value text,p_currency text) returns jsonb language plpgsql security definer set search_path='' as $$
declare v uuid;old tenant_private.catalog_requests%rowtype;payload jsonb;r jsonb;price bigint;percentage numeric;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_products is null or cardinality(p_products) not between 1 and 50 or (select count(distinct x) from unnest(p_products)x)<>cardinality(p_products) or p_action is null or p_action not in ('show','hide','brand','category','price','percent') or p_value is null or length(p_value)>100 then raise exception 'Invalid bulk action' using errcode='22023';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 payload:=jsonb_build_object('products',to_jsonb(p_products),'action',p_action,'value',p_value,'currency',p_currency);
 select * into old from tenant_private.catalog_requests where store_id=p_store and request_id=p_request;
 if found then if old.actor<>auth.uid() or old.payload is distinct from payload then raise exception 'Conflicting request' using errcode='22023';end if;return old.result;end if;
 if (select count(*) from public.mt_products where store_id=p_store and id=any(p_products))<>cardinality(p_products) then raise exception 'Unknown product' using errcode='22023';end if;
 if p_action='price' then if p_value !~ '^[0-9]{1,9}$' then raise exception 'Invalid price' using errcode='22023';end if;price:=p_value::bigint;end if;
 if p_action='percent' then
  if p_currency is null or p_value !~ '^-?[0-9]{1,4}([.][0-9]{1,2})?$' then raise exception 'Invalid percentage' using errcode='22023';end if;
  percentage:=p_value::numeric;
  if percentage<=-100 or percentage>1000 then raise exception 'Invalid percentage' using errcode='22023';end if;
 end if;
 foreach v in array p_products loop
 if p_action in ('show','hide') then perform tenant_private.storefront_list_product(p_store,v,p_action='show');
 elsif p_action='price' then perform tenant_private.set_currency_price(p_store,v,p_currency,price);
 elsif p_action='percent' then
  select price_minor into price from public.mt_product_prices where store_id=p_store and product_id=v and currency=p_currency;
  if not found then raise exception 'Selected product has no price in this currency' using errcode='22023';end if;
  price:=round(price::numeric*(100+percentage)/100)::bigint;
  perform tenant_private.set_currency_price(p_store,v,p_currency,price);
 else update public.mt_products set catalog=jsonb_set(catalog,array[p_action],to_jsonb(btrim(p_value))) where store_id=p_store and id=v;end if;
 end loop;
 r:=jsonb_build_object('count',cardinality(p_products));insert into tenant_private.catalog_requests values(p_store,p_request,auth.uid(),payload,r,now());return r;
end $$;
