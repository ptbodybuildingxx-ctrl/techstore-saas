-- Shared tenant development POS: cash records only, no payment collection or tax invoice.
begin;
do $$ begin
 if to_regclass('tenant_private.placements') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required';end if;
end $$;
create table tenant_private.sales_settings(
 store_id uuid primary key references tenant_private.workspaces(store_id),
 currency text not null check(currency in ('SEK','EUR','USD')),
 next_number bigint not null default 1 check(next_number between 1 and 9007199254740991)
);
alter table public.mt_products add column unit_price_minor bigint check(unit_price_minor between 1 and 100000000);
create table public.mt_sales(
 store_id uuid not null references tenant_private.workspaces(store_id),
 id uuid not null default gen_random_uuid(),
 number bigint not null check(number>0),
 request_id uuid not null,
 actor uuid not null,
 currency text not null check(currency in ('SEK','EUR','USD')),
 total_minor bigint not null check(total_minor between 1 and 100000000000000),
 created_at timestamptz not null default now(),
 primary key(store_id,id), unique(store_id,number),unique(store_id,request_id)
);
create table public.mt_sale_lines(
 store_id uuid not null,
 sale_id uuid not null,
 product_id uuid not null,
 sku text not null,
 product_name text not null,
 units bigint not null check(units between 1 and 10000),
 unit_price_minor bigint not null check(unit_price_minor between 1 and 100000000),
 line_total_minor bigint generated always as (units*unit_price_minor) stored,
 primary key(store_id,sale_id,product_id),
 foreign key(store_id,sale_id) references public.mt_sales(store_id,id),
 foreign key(store_id,product_id) references public.mt_products(store_id,id)
);
create index mt_sale_lines_product_idx on public.mt_sale_lines(store_id,product_id);
create index mt_sales_actor_idx on public.mt_sales(store_id,actor,number desc);
create table public.mt_cash_receipts(
 store_id uuid not null,
 sale_id uuid not null,
 currency text not null check(currency in ('SEK','EUR','USD')),
 amount_minor bigint not null check(amount_minor between 1 and 100000000000000),
 recorded_at timestamptz not null default now(),
 primary key(store_id,sale_id),
 foreign key(store_id,sale_id) references public.mt_sales(store_id,id)
);
alter table public.mt_stock_events add column sale_id uuid;
alter table public.mt_stock_events add foreign key(store_id,sale_id) references public.mt_sales(store_id,id);
create unique index mt_sale_stock_once on public.mt_stock_events(store_id,sale_id,product_id) where sale_id is not null;
alter table tenant_private.sales_settings enable row level security;
alter table public.mt_sales enable row level security;
alter table public.mt_sale_lines enable row level security;
alter table public.mt_cash_receipts enable row level security;
revoke all on tenant_private.sales_settings,public.mt_sales,public.mt_sale_lines,public.mt_cash_receipts from public,anon,authenticated,service_role;
grant select on public.mt_sales,public.mt_sale_lines,public.mt_cash_receipts to authenticated;
create policy mt_sales_member_read on public.mt_sales for select to authenticated using (tenant_private.member_role(store_id)='owner' or (tenant_private.member_role(store_id)='cashier' and actor=(select auth.uid())));
create policy mt_lines_member_read on public.mt_sale_lines for select to authenticated using (exists(select 1 from public.mt_sales s where s.store_id=mt_sale_lines.store_id and s.id=mt_sale_lines.sale_id));
create policy mt_cash_owner_read on public.mt_cash_receipts for select to authenticated using (tenant_private.member_role(store_id)='owner');
create function tenant_private.can_sell(p_store uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce(tenant_private.member_role(p_store) in ('owner','cashier'),false) and exists(
 select 1 from tenant_private.workspaces w join public.saas_stores s on s.id=w.store_id
 join public.saas_subscriptions sub on sub.store_id=s.id
 where w.store_id=p_store and s.state='provisioning' and s.project_ref is null and s.origin is null and sub.state='trial' and sub.valid_until>now())
$$;
create function tenant_private.configure_sales(p_store uuid,p_currency text) returns text
language plpgsql security definer set search_path='' as $$
declare c text;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_currency is null or p_currency not in ('SEK','EUR','USD') then raise exception 'Unsupported currency' using errcode='22023';end if;
 insert into tenant_private.sales_settings(store_id,currency) values(p_store,p_currency) on conflict(store_id) do nothing;
 select currency into c from tenant_private.sales_settings where store_id=p_store;
 if c<>p_currency then raise exception 'Currency is immutable in development' using errcode='22023';end if;
 return c;
end $$;
create function tenant_private.set_price(p_store uuid,p_product uuid,p_price bigint) returns bigint
language plpgsql security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_price is null or p_price not between 1 and 100000000 or not exists(select 1 from tenant_private.sales_settings where store_id=p_store) then raise exception 'Invalid price or missing currency' using errcode='22023';end if;
 update public.mt_products set unit_price_minor=p_price where store_id=p_store and id=p_product;
 if not found then raise exception 'Unknown product' using errcode='22023';end if;
 return p_price;
end $$;
create function tenant_private.sale_context(p_store uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare c text;
begin
 if tenant_private.member_role(p_store) is null then raise exception 'Tenant access required' using errcode='42501';end if;
 select currency into c from tenant_private.sales_settings where store_id=p_store;
 return jsonb_build_object('currency',c,'can_sell',tenant_private.can_sell(p_store),'can_price',coalesce(tenant_private.member_role(p_store)='owner' and tenant_private.can_sell(p_store),false));
end $$;
create function tenant_private.record_sale(p_store uuid,p_request uuid,p_lines jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare x jsonb; v_product uuid; v_units bigint; v_expected bigint; v_sum bigint:=0; v_norm jsonb; v_previous jsonb; v_settings tenant_private.sales_settings%rowtype; v_sale public.mt_sales%rowtype; pr public.mt_products%rowtype;
begin
 if tenant_private.member_role(p_store) is null then raise exception 'Tenant access required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Sale not permitted' using errcode='42501';end if;
 if p_request is null or jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid sale' using errcode='22023';end if;
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
  if v_sale.actor<>auth.uid() or v_previous is distinct from v_norm then raise exception 'Conflicting sale request' using errcode='22023';end if;
  return jsonb_build_object('id',v_sale.id,'number',v_sale.number,'currency',v_sale.currency,'total_minor',v_sale.total_minor,'request_id',v_sale.request_id);
 end if;
 select * into v_settings from tenant_private.sales_settings where store_id=p_store for update;
 if not found then raise exception 'Configure store currency first' using errcode='22023';end if;
 for x in select value from jsonb_array_elements(v_norm) loop
  v_product:=(x->>'product_id')::uuid;v_units:=(x->>'units')::bigint;v_expected:=(x->>'expected_price_minor')::bigint;
  select * into pr from public.mt_products where store_id=p_store and id=v_product for update;
  if not found or pr.quantity<v_units or pr.unit_price_minor is distinct from v_expected then raise exception 'Unavailable product, price changed or insufficient stock' using errcode='22023';end if;
  v_sum:=v_sum+v_units*pr.unit_price_minor;
 end loop;
 insert into public.mt_sales(store_id,number,request_id,actor,currency,total_minor) values(p_store,v_settings.next_number,p_request,auth.uid(),v_settings.currency,v_sum) returning * into v_sale;
 update tenant_private.sales_settings set next_number=next_number+1 where store_id=p_store;
 for x in select value from jsonb_array_elements(v_norm) loop
  v_product:=(x->>'product_id')::uuid;v_units:=(x->>'units')::bigint;
  update public.mt_products set quantity=quantity-v_units where store_id=p_store and id=v_product returning * into pr;
  insert into public.mt_sale_lines(store_id,sale_id,product_id,sku,product_name,units,unit_price_minor) values(p_store,v_sale.id,pr.id,pr.sku,pr.name,v_units,pr.unit_price_minor);
  insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor,sale_id) values(p_store,gen_random_uuid(),pr.id,-v_units,pr.quantity,auth.uid(),v_sale.id);
 end loop;
 insert into public.mt_cash_receipts(store_id,sale_id,currency,amount_minor) values(p_store,v_sale.id,v_sale.currency,v_sum);
 return jsonb_build_object('id',v_sale.id,'number',v_sale.number,'currency',v_sale.currency,'total_minor',v_sale.total_minor,'request_id',v_sale.request_id);
end $$;
create function public.mt_configure_sales(p_store uuid,p_currency text) returns text
language sql security invoker set search_path='' as $$ select tenant_private.configure_sales(p_store,p_currency) $$;
create function public.mt_set_price(p_store uuid,p_product uuid,p_price bigint) returns bigint
language sql security invoker set search_path='' as $$ select tenant_private.set_price(p_store,p_product,p_price) $$;
create function public.mt_sale_context(p_store uuid) returns jsonb
language sql stable security invoker set search_path='' as $$ select tenant_private.sale_context(p_store) $$;
create function public.mt_record_sale(p_store uuid,p_request uuid,p_lines jsonb) returns jsonb
language sql security invoker set search_path='' as $$ select tenant_private.record_sale(p_store,p_request,p_lines) $$;
create function public.mt_list_sales(p_store uuid,p_before bigint default null,p_limit integer default 50) returns setof public.mt_sales
language plpgsql stable security invoker set search_path='' as $$
begin
 if coalesce(tenant_private.member_role(p_store),'') not in ('owner','cashier') then raise exception 'Sales access required' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 or (p_before is not null and p_before<=0) then raise exception 'Invalid page' using errcode='22023';end if;
 return query select * from public.mt_sales where store_id=p_store and (p_before is null or number<p_before) order by number desc limit p_limit;
end $$;
revoke all on function tenant_private.can_sell(uuid),tenant_private.configure_sales(uuid,text),tenant_private.set_price(uuid,uuid,bigint),tenant_private.sale_context(uuid),tenant_private.record_sale(uuid,uuid,jsonb),public.mt_configure_sales(uuid,text),public.mt_set_price(uuid,uuid,bigint),public.mt_sale_context(uuid),public.mt_record_sale(uuid,uuid,jsonb),public.mt_list_sales(uuid,bigint,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.configure_sales(uuid,text),tenant_private.set_price(uuid,uuid,bigint),tenant_private.sale_context(uuid),tenant_private.record_sale(uuid,uuid,jsonb),public.mt_configure_sales(uuid,text),public.mt_set_price(uuid,uuid,bigint),public.mt_sale_context(uuid),public.mt_record_sale(uuid,uuid,jsonb),public.mt_list_sales(uuid,bigint,integer) to authenticated;
commit;
