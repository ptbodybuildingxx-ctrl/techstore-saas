-- Multiple independent sale currencies; no automatic conversion or mixed tender.
begin;
do $$ begin
 if to_regclass('tenant_private.sales_settings') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required';end if;
end $$;
create table tenant_private.sale_currencies(
 store_id uuid not null references tenant_private.sales_settings(store_id),
 currency text not null check(currency in ('SYP','USD','EUR')),
 primary key(store_id,currency)
);
insert into tenant_private.sale_currencies select store_id,currency from tenant_private.sales_settings;
create table public.mt_product_prices(
 store_id uuid not null,
 product_id uuid not null,
 currency text not null,
 price_minor bigint not null check(price_minor between 1 and 100000000),
 primary key(store_id,product_id,currency),
 foreign key(store_id,product_id) references public.mt_products(store_id,id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency)
);
insert into public.mt_product_prices select p.store_id,p.id,s.currency,p.unit_price_minor from public.mt_products p join tenant_private.sales_settings s on s.store_id=p.store_id where p.unit_price_minor is not null;
alter table tenant_private.sale_currencies enable row level security;
alter table public.mt_product_prices enable row level security;
revoke all on tenant_private.sale_currencies,public.mt_product_prices from public,anon,authenticated,service_role;
grant select on public.mt_product_prices to authenticated;
create policy mt_price_member_read on public.mt_product_prices for select to authenticated using (tenant_private.member_role(store_id) is not null);
create or replace function tenant_private.configure_sales(p_store uuid,p_currency text) returns text
language plpgsql security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_currency is null or p_currency not in ('SYP','USD','EUR') then raise exception 'Unsupported currency' using errcode='22023';end if;
 insert into tenant_private.sales_settings(store_id,currency) values(p_store,p_currency) on conflict(store_id) do nothing;
 insert into tenant_private.sale_currencies(store_id,currency) values(p_store,p_currency) on conflict do nothing;
 return p_currency;
end $$;
create or replace function tenant_private.sale_context(p_store uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare c text; cs jsonb;
begin
 if tenant_private.member_role(p_store) is null then raise exception 'Tenant access required' using errcode='42501';end if;
 select currency into c from tenant_private.sales_settings where store_id=p_store;
 select coalesce(jsonb_agg(currency order by currency),'[]'::jsonb) into cs from tenant_private.sale_currencies where store_id=p_store;
 return jsonb_build_object('currency',c,'currencies',cs,'can_sell',tenant_private.can_sell(p_store),'can_price',coalesce(tenant_private.member_role(p_store)='owner' and tenant_private.can_sell(p_store),false));
end $$;
create function tenant_private.set_currency_price(p_store uuid,p_product uuid,p_currency text,p_price bigint) returns bigint
language plpgsql security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_price is null or p_price not between 1 and 100000000 or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_currency) or not exists(select 1 from public.mt_products where store_id=p_store and id=p_product) then raise exception 'Invalid price, product or currency' using errcode='22023';end if;
 insert into public.mt_product_prices(store_id,product_id,currency,price_minor) values(p_store,p_product,p_currency,p_price) on conflict(store_id,product_id,currency) do update set price_minor=excluded.price_minor;
 return p_price;
end $$;
create function tenant_private.record_currency_sale(p_store uuid,p_request uuid,p_currency text,p_lines jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare x jsonb; v_product uuid; v_units bigint; v_expected bigint; v_price bigint; v_sum bigint:=0; v_norm jsonb; v_previous jsonb; v_settings tenant_private.sales_settings%rowtype; v_sale public.mt_sales%rowtype; pr public.mt_products%rowtype;
begin
 if tenant_private.member_role(p_store) is null then raise exception 'Tenant access required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Sale not permitted' using errcode='42501';end if;
 if p_currency is null or p_currency not in ('SYP','USD','EUR') or p_request is null or jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid sale' using errcode='22023';end if;
 if jsonb_array_length(p_lines) not between 1 and 100 or octet_length(p_lines::text)>50000 then raise exception 'Invalid sale size' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
  if jsonb_typeof(x) is distinct from 'object' then raise exception 'Invalid line' using errcode='22023';end if;
  if (select count(*) from jsonb_object_keys(x))<>3 or not (x ?& array['product_id','units','expected_price_minor']) or jsonb_typeof(x->'product_id') is distinct from 'string' or jsonb_typeof(x->'units') is distinct from 'number' or jsonb_typeof(x->'expected_price_minor') is distinct from 'number' or coalesce(x->>'product_id','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(x->>'units','') !~ '^[0-9]{1,5}$' or coalesce(x->>'expected_price_minor','') !~ '^[0-9]{1,9}$' then raise exception 'Invalid line values' using errcode='22023';end if;
  v_units:=(x->>'units')::bigint;v_expected:=(x->>'expected_price_minor')::bigint;
  if v_units not between 1 and 10000 or v_expected not between 1 and 100000000 then raise exception 'Invalid line amount' using errcode='22023';end if;
 end loop;
 if (select count(distinct (value->>'product_id')::uuid) from jsonb_array_elements(p_lines))<>jsonb_array_length(p_lines) then raise exception 'Duplicate product' using errcode='22023';end if;
 select jsonb_agg(jsonb_build_object('product_id',(value->>'product_id')::uuid,'units',(value->>'units')::bigint,'expected_price_minor',(value->>'expected_price_minor')::bigint) order by (value->>'product_id')::uuid) into v_norm from jsonb_array_elements(p_lines);
 select * into v_sale from public.mt_sales where store_id=p_store and request_id=p_request;
 if found then
  select jsonb_agg(jsonb_build_object('product_id',l.product_id,'units',l.units,'expected_price_minor',l.unit_price_minor) order by l.product_id) into v_previous from public.mt_sale_lines l where l.store_id=p_store and l.sale_id=v_sale.id;
  if v_sale.actor<>auth.uid() or v_sale.currency<>p_currency or v_previous is distinct from v_norm then raise exception 'Conflicting sale request' using errcode='22023';end if;
  return jsonb_build_object('id',v_sale.id,'number',v_sale.number,'currency',v_sale.currency,'total_minor',v_sale.total_minor,'request_id',v_sale.request_id);
 end if;
 select * into v_settings from tenant_private.sales_settings where store_id=p_store for update;
 if not found or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_currency) then raise exception 'Enable sale currency first' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(v_norm) loop
  v_product:=(x->>'product_id')::uuid;v_units:=(x->>'units')::bigint;v_expected:=(x->>'expected_price_minor')::bigint;
  select * into pr from public.mt_products where store_id=p_store and id=v_product for update;
  if not found or pr.quantity<v_units then raise exception 'Insufficient stock or unknown product' using errcode='22023';end if;
  select price_minor into v_price from public.mt_product_prices where store_id=p_store and product_id=v_product and currency=p_currency;
  if not found or v_price is distinct from v_expected then raise exception 'Unavailable product, price changed or insufficient stock' using errcode='22023';end if;
  v_sum:=v_sum+v_units*v_price;
 end loop;
 insert into public.mt_sales(store_id,number,request_id,actor,currency,total_minor) values(p_store,v_settings.next_number,p_request,auth.uid(),p_currency,v_sum) returning * into v_sale;
 update tenant_private.sales_settings set next_number=next_number+1 where store_id=p_store;
 for x in select value from jsonb_array_elements(v_norm) loop
  v_product:=(x->>'product_id')::uuid;v_units:=(x->>'units')::bigint;
  update public.mt_products set quantity=quantity-v_units where store_id=p_store and id=v_product returning * into pr;
  insert into public.mt_sale_lines(store_id,sale_id,product_id,sku,product_name,units,unit_price_minor) values(p_store,v_sale.id,pr.id,pr.sku,pr.name,v_units,(x->>'expected_price_minor')::bigint);
  insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor,sale_id) values(p_store,gen_random_uuid(),pr.id,-v_units,pr.quantity,auth.uid(),v_sale.id);
 end loop;
 insert into public.mt_cash_receipts(store_id,sale_id,currency,amount_minor) values(p_store,v_sale.id,v_sale.currency,v_sum);
 return jsonb_build_object('id',v_sale.id,'number',v_sale.number,'currency',v_sale.currency,'total_minor',v_sale.total_minor,'request_id',v_sale.request_id);
end $$;
create function public.mt_set_currency_price(p_store uuid,p_product uuid,p_currency text,p_price bigint) returns bigint
language sql security invoker set search_path='' as $$ select tenant_private.set_currency_price(p_store,p_product,p_currency,p_price) $$;
create function public.mt_record_currency_sale(p_store uuid,p_request uuid,p_currency text,p_lines jsonb) returns jsonb
language sql security invoker set search_path='' as $$ select tenant_private.record_currency_sale(p_store,p_request,p_currency,p_lines) $$;
create function public.mt_list_currency_products(p_store uuid,p_currency text,p_after uuid default null,p_limit integer default 50)
returns table(store_id uuid,id uuid,sku text,name text,quantity bigint,unit_price_minor bigint)
language plpgsql stable security invoker set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is null then raise exception 'Tenant access required' using errcode='42501';end if;
 if (p_currency is not null and p_currency not in ('SYP','USD','EUR')) or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid query' using errcode='22023';end if;
 return query select p.store_id,p.id,p.sku,p.name,p.quantity,pp.price_minor from public.mt_products p left join public.mt_product_prices pp on pp.store_id=p.store_id and pp.product_id=p.id and pp.currency=p_currency where p.store_id=p_store and (p_after is null or p.id>p_after) order by p.id limit p_limit;
end $$;
-- Retire ambiguous single-currency mutation endpoints; no stale client may write.
revoke all on function public.mt_set_price(uuid,uuid,bigint),public.mt_record_sale(uuid,uuid,jsonb),tenant_private.set_price(uuid,uuid,bigint),tenant_private.record_sale(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function tenant_private.set_currency_price(uuid,uuid,text,bigint),tenant_private.record_currency_sale(uuid,uuid,text,jsonb),public.mt_set_currency_price(uuid,uuid,text,bigint),public.mt_record_currency_sale(uuid,uuid,text,jsonb),public.mt_list_currency_products(uuid,text,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.set_currency_price(uuid,uuid,text,bigint),tenant_private.record_currency_sale(uuid,uuid,text,jsonb),public.mt_set_currency_price(uuid,uuid,text,bigint),public.mt_record_currency_sale(uuid,uuid,text,jsonb),public.mt_list_currency_products(uuid,text,uuid,integer) to authenticated;
commit;
