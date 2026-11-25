begin;
do $$ begin if to_regclass('public.mt_repair_invoices') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required';end if;end $$;
alter table public.mt_sales drop constraint mt_sales_payment_mode_check,add constraint mt_sales_payment_mode_check check(payment_mode in ('cash','credit','mixed'));
create table public.mt_fx_rates(
 store_id uuid not null,id uuid not null default gen_random_uuid(),request_id uuid not null,from_currency text not null,to_currency text not null,
 numerator bigint not null check(numerator between 1 and 1000000000000),denominator bigint not null check(denominator between 1 and 1000000000000),
 note text not null check(length(btrim(note)) between 1 and 300),actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,request_id),foreign key(store_id,from_currency) references tenant_private.sale_currencies(store_id,currency),foreign key(store_id,to_currency) references tenant_private.sale_currencies(store_id,currency),check(from_currency<>to_currency)
);
create index mt_fx_pair_idx on public.mt_fx_rates(store_id,from_currency,to_currency,created_at desc);
create table public.mt_mixed_sales(
 store_id uuid not null,sale_id uuid not null,tenders jsonb not null check(jsonb_typeof(tenders)='array' and jsonb_array_length(tenders) between 2 and 3),refund_policy text not null check(refund_policy='invoice_currency'),primary key(store_id,sale_id),foreign key(store_id,sale_id) references public.mt_sales(store_id,id)
);
create table public.mt_mixed_tenders(
 store_id uuid not null,sale_id uuid not null,currency text not null,amount_minor bigint not null check(amount_minor between 1 and 100000000000000),invoice_amount_minor bigint not null check(invoice_amount_minor between 1 and 100000000000000),
 rate_id uuid,rate_numerator bigint not null check(rate_numerator>0),rate_denominator bigint not null check(rate_denominator>0),
 primary key(store_id,sale_id,currency),foreign key(store_id,sale_id) references public.mt_mixed_sales(store_id,sale_id),foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),foreign key(store_id,rate_id) references public.mt_fx_rates(store_id,id),
 check(invoice_amount_minor=round(amount_minor::numeric*rate_numerator/rate_denominator))
);
alter table public.mt_cash_movements drop constraint mt_cash_movements_kind_check;
alter table public.mt_cash_movements add constraint mt_cash_movements_kind_check check(kind in ('sale','funding','expense','exchange','debt_payment','return_refund','supplier_payment','repair_receipt','mixed_receipt'));
alter table public.mt_cash_movements add column mixed_sale_id uuid;
alter table public.mt_cash_movements add foreign key(store_id,mixed_sale_id,currency) references public.mt_mixed_tenders(store_id,sale_id,currency);
alter table public.mt_cash_movements add unique(store_id,mixed_sale_id,currency);
alter table public.mt_cash_movements add check((kind='mixed_receipt')=(mixed_sale_id is not null));
create or replace function tenant_private.cash_post() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.saas_stores where id=new.store_id for update;
 if new.kind in ('sale','funding','debt_payment','repair_receipt','mixed_receipt') then
  insert into tenant_private.cash_balances(store_id,currency,balance_minor) values(new.store_id,new.currency,new.amount_minor) on conflict(store_id,currency) do update set balance_minor=cash_balances.balance_minor+excluded.balance_minor;
 else
  update tenant_private.cash_balances set balance_minor=balance_minor-new.amount_minor where store_id=new.store_id and currency=new.currency and balance_minor>=new.amount_minor;
  if not found then raise exception 'Insufficient cash in source currency' using errcode='22023';end if;
  if new.kind='exchange' then insert into tenant_private.cash_balances(store_id,currency,balance_minor) values(new.store_id,new.target_currency,new.target_amount_minor) on conflict(store_id,currency) do update set balance_minor=cash_balances.balance_minor+excluded.balance_minor;end if;
 end if;return new;
end $$;
do $$ declare t text;begin
 foreach t in array array['mt_fx_rates','mt_mixed_sales','mt_mixed_tenders'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('create policy mt_owner_read on public.%I for select to authenticated using (tenant_private.member_role(store_id)=''owner'')',t);
 end loop;
end $$;
create function tenant_private.add_fx_rate(p_store uuid,p_request uuid,p_from text,p_to text,p_numerator bigint,p_denominator bigint,p_note text) returns uuid language plpgsql security definer set search_path='' as $$
declare q public.mt_fx_rates%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_from is null or p_to is null or p_from=p_to or p_numerator is null or p_numerator not between 1 and 1000000000000 or p_denominator is null or p_denominator not between 1 and 1000000000000 or p_note is null or length(btrim(p_note)) not between 1 and 300 or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_from) or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_to) then raise exception 'Invalid FX quote' using errcode='22023';end if;
 select * into q from public.mt_fx_rates where store_id=p_store and request_id=p_request;
 if found then
  if q.actor<>auth.uid() or q.from_currency<>p_from or q.to_currency<>p_to or q.numerator<>p_numerator or q.denominator<>p_denominator or q.note<>btrim(p_note) then raise exception 'Conflicting rate request' using errcode='22023';end if;return q.id;
 end if;
 insert into public.mt_fx_rates(store_id,request_id,from_currency,to_currency,numerator,denominator,note,actor) values(p_store,p_request,p_from,p_to,p_numerator,p_denominator,btrim(p_note),auth.uid()) returning * into q;return q.id;
end $$;
create function tenant_private.normalize_tenders(p_tenders jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare t jsonb;r jsonb;
begin
 if jsonb_typeof(p_tenders) is distinct from 'array' then raise exception 'Invalid tenders' using errcode='22023';end if;
 if jsonb_array_length(p_tenders) not between 2 and 3 or octet_length(p_tenders::text)>4000 then raise exception 'Invalid tender count' using errcode='22023';end if;
 for t in select value from jsonb_array_elements(p_tenders) loop
  if jsonb_typeof(t) is distinct from 'object' then raise exception 'Invalid tender' using errcode='22023';end if;
  if (select count(*) from jsonb_object_keys(t))<>4 or not (t ?& array['currency','amount_minor','rate_id','expected_invoice_minor']) or jsonb_typeof(t->'currency') is distinct from 'string' or coalesce(t->>'currency','') not in ('SYP','USD','EUR') or jsonb_typeof(t->'amount_minor') is distinct from 'number' or jsonb_typeof(t->'expected_invoice_minor') is distinct from 'number' or coalesce(t->>'amount_minor','') !~ '^[0-9]{1,15}$' or coalesce(t->>'expected_invoice_minor','') !~ '^[0-9]{1,15}$' or not (jsonb_typeof(t->'rate_id')='null' or (jsonb_typeof(t->'rate_id')='string' and coalesce(t->>'rate_id','') ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')) then raise exception 'Invalid tender values' using errcode='22023';end if;
  if (t->>'amount_minor')::bigint not between 1 and 100000000000000 or (t->>'expected_invoice_minor')::bigint not between 1 and 100000000000000 then raise exception 'Invalid tender amounts' using errcode='22023';end if;
 end loop;
 if (select count(distinct value->>'currency') from jsonb_array_elements(p_tenders))<>jsonb_array_length(p_tenders) then raise exception 'Duplicate tender currency' using errcode='22023';end if;
 select jsonb_agg(jsonb_build_object('currency',value->>'currency','amount_minor',(value->>'amount_minor')::bigint,'rate_id',(value->>'rate_id')::uuid,'expected_invoice_minor',(value->>'expected_invoice_minor')::bigint) order by value->>'currency') into r from jsonb_array_elements(p_tenders);return r;
end $$;
create function tenant_private.verify_tenders(p_store uuid,p_currency text,p_tenders jsonb,p_total bigint) returns void language plpgsql security definer set search_path='' as $$
declare t jsonb;c text;amt bigint;rate uuid;q public.mt_fx_rates%rowtype;converted numeric;paid numeric:=0;
begin
 for t in select value from jsonb_array_elements(p_tenders) loop
  c:=t->>'currency';amt:=(t->>'amount_minor')::bigint;rate:=(t->>'rate_id')::uuid;
  if not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=c) then raise exception 'Tender currency unavailable' using errcode='22023';end if;
  if c=p_currency then
   if rate is not null then raise exception 'Same currency must not use a rate' using errcode='22023';end if;converted:=amt;
  else
   select * into q from public.mt_fx_rates where store_id=p_store and id=rate and from_currency=c and to_currency=p_currency and created_at>=now()-interval '24 hours';
   if not found then raise exception 'Current matching exchange rate required' using errcode='22023';end if;
   converted:=round(amt::numeric*q.numerator/q.denominator);
  end if;
  if converted not between 1 and 100000000000000 or converted<>(t->>'expected_invoice_minor')::bigint then raise exception 'Exchange conversion mismatch' using errcode='22023';end if;paid:=paid+converted;
 end loop;
 if paid<>p_total then raise exception 'Tenders must exactly equal invoice' using errcode='22023';end if;
end $$;
create function tenant_private.post_tenders(p_store uuid,p_sale uuid,p_currency text,p_tenders jsonb) returns void language plpgsql security definer set search_path='' as $$
declare t jsonb;c text;amt bigint;rate uuid;converted bigint;n bigint;d bigint;
begin
 insert into public.mt_mixed_sales(store_id,sale_id,tenders,refund_policy) values(p_store,p_sale,p_tenders,'invoice_currency');
 for t in select value from jsonb_array_elements(p_tenders) loop
  c:=t->>'currency';amt:=(t->>'amount_minor')::bigint;rate:=(t->>'rate_id')::uuid;converted:=(t->>'expected_invoice_minor')::bigint;
  if rate is null then n:=1;d:=1;else select r.numerator,r.denominator into strict n,d from public.mt_fx_rates r where r.store_id=p_store and r.id=rate;end if;
  insert into public.mt_mixed_tenders(store_id,sale_id,currency,amount_minor,invoice_amount_minor,rate_id,rate_numerator,rate_denominator) values(p_store,p_sale,c,amt,converted,rate,n,d);
  insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,mixed_sale_id) values(p_store,gen_random_uuid(),'mixed_receipt',c,amt,'Mixed tender receipt',auth.uid(),p_sale);
 end loop;
end $$;
create function tenant_private.record_mixed_sale(p_store uuid,p_request uuid,p_currency text,p_lines jsonb,p_tenders jsonb,p_refund_policy text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare x jsonb; v_product uuid; v_units bigint; v_expected bigint; v_price bigint; v_sum bigint:=0; v_norm jsonb; v_previous jsonb; v_settings tenant_private.sales_settings%rowtype; v_sale public.mt_sales%rowtype; pr public.mt_products%rowtype; tn jsonb; previous_tenders jsonb;
begin
 perform tenant_private.owner_write(p_store);
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Sale not permitted' using errcode='42501';end if;
 if p_refund_policy is distinct from 'invoice_currency' then raise exception 'Explicit invoice currency refund policy required' using errcode='22023';end if;
 tn:=tenant_private.normalize_tenders(p_tenders);
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
  select tenders into previous_tenders from public.mt_mixed_sales where store_id=p_store and sale_id=v_sale.id;
  if v_sale.payment_mode<>'mixed' or previous_tenders is distinct from tn then raise exception 'Conflicting tender request' using errcode='22023';end if;
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
 perform tenant_private.verify_tenders(p_store,p_currency,tn,v_sum);
 insert into public.mt_sales(store_id,number,request_id,actor,currency,total_minor,payment_mode) values(p_store,v_settings.next_number,p_request,auth.uid(),p_currency,v_sum,'mixed') returning * into v_sale;
 update tenant_private.sales_settings set next_number=next_number+1 where store_id=p_store;
 for x in select value from jsonb_array_elements(v_norm) loop
  v_product:=(x->>'product_id')::uuid;v_units:=(x->>'units')::bigint;
  update public.mt_products set quantity=quantity-v_units where store_id=p_store and id=v_product returning * into pr;
  insert into public.mt_sale_lines(store_id,sale_id,product_id,sku,product_name,units,unit_price_minor) values(p_store,v_sale.id,pr.id,pr.sku,pr.name,v_units,(x->>'expected_price_minor')::bigint);
  insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor,sale_id) values(p_store,gen_random_uuid(),pr.id,-v_units,pr.quantity,auth.uid(),v_sale.id);
 end loop;
 perform tenant_private.post_tenders(p_store,v_sale.id,p_currency,tn);
 return jsonb_build_object('id',v_sale.id,'number',v_sale.number,'currency',v_sale.currency,'total_minor',v_sale.total_minor,'request_id',v_sale.request_id);
end $$;
create or replace function tenant_private.cash_report(p_store uuid,p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 then raise exception 'Invalid date range' using errcode='22023';end if;
 with movements as (select * from public.mt_cash_movements where store_id=p_store and created_at>=p_from::timestamp at time zone 'UTC' and created_at<(p_to+1)::timestamp at time zone 'UTC'),
 flows as (select currency,kind,case when kind in ('sale','funding','debt_payment','repair_receipt','mixed_receipt') then amount_minor else -amount_minor end as value from movements union all select target_currency,'exchange_in',target_amount_minor from movements where kind='exchange'),
 totals as (select currency,sum(value) filter(where value>0) as incoming,sum(-value) filter(where value<0) as outgoing,sum(value) as net,sum(value) filter(where kind in ('sale','debt_payment','repair_receipt','mixed_receipt')) as collections,sum(-value) filter(where kind='return_refund') as refunds,sum(-value) filter(where kind='supplier_payment') as supplier_payments,sum(-value) filter(where kind='expense') as expenses from flows group by currency)
 select coalesce(jsonb_agg(jsonb_build_object('currency',c.currency,'incoming',coalesce(t.incoming,0)::text,'outgoing',coalesce(t.outgoing,0)::text,'net',coalesce(t.net,0)::text,'collections',coalesce(t.collections,0)::text,'refunds',coalesce(t.refunds,0)::text,'supplier_payments',coalesce(t.supplier_payments,0)::text,'expenses',coalesce(t.expenses,0)::text) order by c.currency),'[]'::jsonb) into r
 from tenant_private.sale_currencies c left join totals t on t.currency=c.currency where c.store_id=p_store;
 return r;
end $$;
create function public.mt_add_fx_rate(p_store uuid,p_request uuid,p_from text,p_to text,p_numerator bigint,p_denominator bigint,p_note text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.add_fx_rate(p_store,p_request,p_from,p_to,p_numerator,p_denominator,p_note)$$;
create function public.mt_record_mixed_sale(p_store uuid,p_request uuid,p_currency text,p_lines jsonb,p_tenders jsonb,p_refund_policy text) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.record_mixed_sale(p_store,p_request,p_currency,p_lines,p_tenders,p_refund_policy)$$;
create function public.mt_list_fx_rates(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.mt_fx_rates language plpgsql stable security invoker set search_path='' as $$
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;return query select * from public.mt_fx_rates where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;
end $$;
create function public.mt_sale_tenders(p_store uuid,p_sale uuid) returns setof public.mt_mixed_tenders language sql stable security invoker set search_path='' as $$select * from public.mt_mixed_tenders where store_id=p_store and sale_id=p_sale order by currency$$;
revoke all on function tenant_private.normalize_tenders(jsonb),tenant_private.verify_tenders(uuid,text,jsonb,bigint),tenant_private.post_tenders(uuid,uuid,text,jsonb),tenant_private.add_fx_rate(uuid,uuid,text,text,bigint,bigint,text),tenant_private.record_mixed_sale(uuid,uuid,text,jsonb,jsonb,text),public.mt_add_fx_rate(uuid,uuid,text,text,bigint,bigint,text),public.mt_record_mixed_sale(uuid,uuid,text,jsonb,jsonb,text),public.mt_list_fx_rates(uuid,uuid,integer),public.mt_sale_tenders(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.add_fx_rate(uuid,uuid,text,text,bigint,bigint,text),tenant_private.record_mixed_sale(uuid,uuid,text,jsonb,jsonb,text),public.mt_add_fx_rate(uuid,uuid,text,text,bigint,bigint,text),public.mt_record_mixed_sale(uuid,uuid,text,jsonb,jsonb,text),public.mt_list_fx_rates(uuid,uuid,integer),public.mt_sale_tenders(uuid,uuid) to authenticated;
commit;