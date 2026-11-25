-- Development customer receivables, interest-free installments and cash collections.
begin;
do $$ begin
 if to_regclass('public.mt_cash_movements') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required';end if;
end $$;
alter table public.mt_sales add column payment_mode text not null default 'cash' check(payment_mode in ('cash','credit'));
create table public.mt_customers(
 store_id uuid not null references tenant_private.workspaces(store_id),
 id uuid not null default gen_random_uuid(),
 request_id uuid not null,
 name text not null check(length(btrim(name)) between 1 and 160),
 phone text not null default '' check(length(phone)<=60),
 actor uuid not null,
 created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,request_id)
);
create table public.mt_debts(
 store_id uuid not null,
 id uuid not null default gen_random_uuid(),
 sale_id uuid not null,
 customer_id uuid not null,
 currency text not null,
 principal_minor bigint not null check(principal_minor between 1 and 100000000000000),
 deposit_minor bigint not null check(deposit_minor>=0 and deposit_minor<principal_minor),
 remaining_minor bigint not null check(remaining_minor>=0 and remaining_minor<=principal_minor-deposit_minor),
 installment_count integer not null check(installment_count between 1 and 60),
 first_due date not null,
 created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,sale_id),
 foreign key(store_id,sale_id) references public.mt_sales(store_id,id),
 foreign key(store_id,customer_id) references public.mt_customers(store_id,id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency)
);
create index mt_debt_customer_idx on public.mt_debts(store_id,customer_id,id);
create table public.mt_installments(
 store_id uuid not null,
 debt_id uuid not null,
 number integer not null check(number between 1 and 60),
 due_date date not null,
 amount_minor bigint not null check(amount_minor>0),
 paid_minor bigint not null default 0 check(paid_minor>=0 and paid_minor<=amount_minor),
 primary key(store_id,debt_id,number),
 foreign key(store_id,debt_id) references public.mt_debts(store_id,id)
);
create table public.mt_debt_payments(
 store_id uuid not null,
 id uuid not null default gen_random_uuid(),
 debt_id uuid not null,
 request_id uuid not null,
 amount_minor bigint not null check(amount_minor between 1 and 100000000000000),
 is_deposit boolean not null default false,
 actor uuid not null,
 created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,request_id),
 foreign key(store_id,debt_id) references public.mt_debts(store_id,id)
);
create index mt_debt_payment_idx on public.mt_debt_payments(store_id,debt_id,id);
create unique index mt_one_deposit_per_debt on public.mt_debt_payments(store_id,debt_id) where is_deposit;
create table public.mt_payment_allocations(
 store_id uuid not null,
 payment_id uuid not null,
 debt_id uuid not null,
 installment_number integer not null,
 amount_minor bigint not null check(amount_minor>0),
 primary key(store_id,payment_id,installment_number),
 foreign key(store_id,payment_id) references public.mt_debt_payments(store_id,id),
 foreign key(store_id,debt_id,installment_number) references public.mt_installments(store_id,debt_id,number)
);
-- Ensure payment allocation cannot point to a different debt within the same store.
alter table public.mt_debt_payments add unique(store_id,id,debt_id);
alter table public.mt_payment_allocations add foreign key(store_id,payment_id,debt_id) references public.mt_debt_payments(store_id,id,debt_id);
alter table public.mt_cash_movements drop constraint mt_cash_movements_kind_check;
alter table public.mt_cash_movements add constraint mt_cash_movements_kind_check check(kind in ('sale','funding','expense','exchange','debt_payment'));
alter table public.mt_cash_movements add column debt_payment_id uuid;
alter table public.mt_cash_movements add foreign key(store_id,debt_payment_id) references public.mt_debt_payments(store_id,id);
alter table public.mt_cash_movements add unique(store_id,debt_payment_id);
alter table public.mt_cash_movements add constraint mt_cash_payment_link check((kind='debt_payment')=(debt_payment_id is not null));
create or replace function tenant_private.cash_post() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.saas_stores where id=new.store_id for update;
 if new.kind in ('sale','funding','debt_payment') then
  insert into tenant_private.cash_balances(store_id,currency,balance_minor) values(new.store_id,new.currency,new.amount_minor)
  on conflict(store_id,currency) do update set balance_minor=cash_balances.balance_minor+excluded.balance_minor;
 else
  update tenant_private.cash_balances set balance_minor=balance_minor-new.amount_minor where store_id=new.store_id and currency=new.currency and balance_minor>=new.amount_minor;
  if not found then raise exception 'Insufficient cash in source currency' using errcode='22023';end if;
  if new.kind='exchange' then
   insert into tenant_private.cash_balances(store_id,currency,balance_minor) values(new.store_id,new.target_currency,new.target_amount_minor)
   on conflict(store_id,currency) do update set balance_minor=cash_balances.balance_minor+excluded.balance_minor;
  end if;
 end if;
 return new;
end $$;
do $$ declare t text; begin
 foreach t in array array['mt_customers','mt_debts','mt_installments','mt_debt_payments','mt_payment_allocations'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('create policy mt_owner_read on public.%I for select to authenticated using (tenant_private.member_role(store_id)=''owner'')',t);
 end loop;
end $$;
create function tenant_private.add_customer(p_store uuid,p_request uuid,p_name text,p_phone text) returns uuid
language plpgsql security definer set search_path='' as $$
declare c public.mt_customers%rowtype;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_request is null or p_name is null or length(btrim(p_name)) not between 1 and 160 or p_phone is null or length(btrim(p_phone))>60 then raise exception 'Invalid customer' using errcode='22023';end if;
 select * into c from public.mt_customers where store_id=p_store and request_id=p_request;
 if found then
  if c.actor<>auth.uid() or c.name<>btrim(p_name) or c.phone<>btrim(p_phone) then raise exception 'Conflicting customer request' using errcode='22023';end if;
  return c.id;
 end if;
 insert into public.mt_customers(store_id,request_id,name,phone,actor) values(p_store,p_request,btrim(p_name),btrim(p_phone),auth.uid()) returning * into c;
 return c.id;
end $$;
create function tenant_private.record_sale_core(p_store uuid,p_request uuid,p_currency text,p_lines jsonb,p_customer uuid,p_deposit bigint,p_count integer,p_due date) returns jsonb
language plpgsql security definer set search_path='' as $$
declare x jsonb; v_product uuid; v_units bigint; v_expected bigint; v_price bigint; v_sum bigint:=0; v_norm jsonb; v_previous jsonb; v_settings tenant_private.sales_settings%rowtype; v_sale public.mt_sales%rowtype; pr public.mt_products%rowtype; d public.mt_debts%rowtype; v_payment uuid; v_remaining bigint; v_part bigint; i integer;
begin
 if tenant_private.member_role(p_store) is null then raise exception 'Tenant access required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Sale not permitted' using errcode='42501';end if;
 if p_customer is not null then
  if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required for credit sale' using errcode='42501';end if;
  if p_deposit is null or p_deposit<0 or p_count is null or p_count not between 1 and 60 or p_due is null then raise exception 'Invalid credit terms' using errcode='22023';end if;
 elsif p_deposit is not null or p_count is not null or p_due is not null then raise exception 'Unexpected credit terms' using errcode='22023';end if;
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
  if v_sale.payment_mode<>case when p_customer is null then 'cash' else 'credit' end then raise exception 'Conflicting payment mode' using errcode='22023';end if;
  if p_customer is not null then
   select * into d from public.mt_debts where store_id=p_store and sale_id=v_sale.id;
   if not found or d.customer_id<>p_customer or d.deposit_minor<>p_deposit or d.installment_count<>p_count or d.first_due<>p_due then raise exception 'Conflicting credit terms' using errcode='22023';end if;
  end if;
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
 if p_customer is not null then
  if not exists(select 1 from public.mt_customers where store_id=p_store and id=p_customer) or p_deposit>=v_sum or v_sum-p_deposit<p_count or p_due<(now() at time zone 'UTC')::date or p_due>(now() at time zone 'UTC')::date+366 then raise exception 'Invalid customer, deposit or due date' using errcode='22023';end if;
 end if;
 insert into public.mt_sales(store_id,number,request_id,actor,currency,total_minor,payment_mode) values(p_store,v_settings.next_number,p_request,auth.uid(),p_currency,v_sum,case when p_customer is null then 'cash' else 'credit' end) returning * into v_sale;
 update tenant_private.sales_settings set next_number=next_number+1 where store_id=p_store;
 for x in select value from jsonb_array_elements(v_norm) loop
  v_product:=(x->>'product_id')::uuid;v_units:=(x->>'units')::bigint;
  update public.mt_products set quantity=quantity-v_units where store_id=p_store and id=v_product returning * into pr;
  insert into public.mt_sale_lines(store_id,sale_id,product_id,sku,product_name,units,unit_price_minor) values(p_store,v_sale.id,pr.id,pr.sku,pr.name,v_units,(x->>'expected_price_minor')::bigint);
  insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor,sale_id) values(p_store,gen_random_uuid(),pr.id,-v_units,pr.quantity,auth.uid(),v_sale.id);
 end loop;
 if p_customer is null then
  insert into public.mt_cash_receipts(store_id,sale_id,currency,amount_minor) values(p_store,v_sale.id,v_sale.currency,v_sum);
 else
  v_remaining:=v_sum-p_deposit;
  insert into public.mt_debts(store_id,sale_id,customer_id,currency,principal_minor,deposit_minor,remaining_minor,installment_count,first_due) values(p_store,v_sale.id,p_customer,p_currency,v_sum,p_deposit,v_remaining,p_count,p_due) returning * into d;
  for i in 1..p_count loop
   v_part:=v_remaining/p_count+case when i<=v_remaining%p_count then 1 else 0 end;
   insert into public.mt_installments(store_id,debt_id,number,due_date,amount_minor) values(p_store,d.id,i,(p_due+make_interval(months=>i-1))::date,v_part);
  end loop;
  if p_deposit>0 then
   insert into public.mt_debt_payments(store_id,debt_id,request_id,amount_minor,is_deposit,actor) values(p_store,d.id,gen_random_uuid(),p_deposit,true,auth.uid()) returning id into v_payment;
   insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,debt_payment_id) values(p_store,gen_random_uuid(),'debt_payment',p_currency,p_deposit,'Credit sale deposit',auth.uid(),v_payment);
  end if;
 end if;
 return jsonb_build_object('id',v_sale.id,'number',v_sale.number,'currency',v_sale.currency,'total_minor',v_sale.total_minor,'request_id',v_sale.request_id);
end $$;
create or replace function tenant_private.record_currency_sale(p_store uuid,p_request uuid,p_currency text,p_lines jsonb) returns jsonb
language sql security definer set search_path='' as $$ select tenant_private.record_sale_core(p_store,p_request,p_currency,p_lines,null,null,null,null) $$;
create function tenant_private.record_credit_sale(p_store uuid,p_request uuid,p_currency text,p_lines jsonb,p_customer uuid,p_deposit bigint,p_count integer,p_due date) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if p_customer is null then raise exception 'Customer required' using errcode='22023';end if;
 return tenant_private.record_sale_core(p_store,p_request,p_currency,p_lines,p_customer,p_deposit,p_count,p_due);
end $$;
create function tenant_private.pay_debt(p_store uuid,p_debt uuid,p_request uuid,p_currency text,p_amount bigint) returns uuid
language plpgsql security definer set search_path='' as $$
declare d public.mt_debts%rowtype; p public.mt_debt_payments%rowtype; i public.mt_installments%rowtype; left_amount bigint; applied bigint;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_request is null or p_debt is null or p_currency is null or p_amount is null or p_amount not between 1 and 100000000000000 then raise exception 'Invalid payment' using errcode='22023';end if;
 select * into d from public.mt_debts where store_id=p_store and id=p_debt for update;
 if not found or d.currency<>p_currency then raise exception 'Debt or currency mismatch' using errcode='22023';end if;
 select * into p from public.mt_debt_payments where store_id=p_store and request_id=p_request;
 if found then
  if p.is_deposit or p.actor<>auth.uid() or p.debt_id<>p_debt or p.amount_minor<>p_amount then raise exception 'Conflicting payment request' using errcode='22023';end if;
  return p.id;
 end if;
 if p_amount>d.remaining_minor then raise exception 'Payment exceeds debt' using errcode='22023';end if;
 insert into public.mt_debt_payments(store_id,debt_id,request_id,amount_minor,actor) values(p_store,p_debt,p_request,p_amount,auth.uid()) returning * into p;
 left_amount:=p_amount;
 for i in select * from public.mt_installments where store_id=p_store and debt_id=p_debt and paid_minor<amount_minor order by number for update loop
  exit when left_amount=0;
  applied:=least(left_amount,i.amount_minor-i.paid_minor);
  update public.mt_installments set paid_minor=paid_minor+applied where store_id=p_store and debt_id=p_debt and number=i.number;
  insert into public.mt_payment_allocations(store_id,payment_id,debt_id,installment_number,amount_minor) values(p_store,p.id,p_debt,i.number,applied);
  left_amount:=left_amount-applied;
 end loop;
 if left_amount<>0 then raise exception 'Installment allocation mismatch';end if;
 update public.mt_debts set remaining_minor=remaining_minor-p_amount where store_id=p_store and id=p_debt;
 insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,debt_payment_id) values(p_store,gen_random_uuid(),'debt_payment',d.currency,p_amount,'Debt collection',auth.uid(),p.id);
 return p.id;
end $$;
create function public.mt_add_customer(p_store uuid,p_request uuid,p_name text,p_phone text) returns uuid language sql security invoker set search_path='' as $$ select tenant_private.add_customer(p_store,p_request,p_name,p_phone) $$;
create function public.mt_record_credit_sale(p_store uuid,p_request uuid,p_currency text,p_lines jsonb,p_customer uuid,p_deposit bigint,p_count integer,p_due date) returns jsonb language sql security invoker set search_path='' as $$ select tenant_private.record_credit_sale(p_store,p_request,p_currency,p_lines,p_customer,p_deposit,p_count,p_due) $$;
create function public.mt_pay_debt(p_store uuid,p_debt uuid,p_request uuid,p_currency text,p_amount bigint) returns uuid language sql security invoker set search_path='' as $$ select tenant_private.pay_debt(p_store,p_debt,p_request,p_currency,p_amount) $$;
create function public.mt_list_customers(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.mt_customers
language plpgsql stable security invoker set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select * from public.mt_customers where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;
end $$;
create function public.mt_list_debts(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.mt_debts
language plpgsql stable security invoker set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select * from public.mt_debts where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;
end $$;
create function public.mt_debt_schedule(p_store uuid,p_debt uuid) returns setof public.mt_installments
language plpgsql stable security invoker set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return query select * from public.mt_installments where store_id=p_store and debt_id=p_debt order by number;
end $$;
revoke all on function tenant_private.record_sale_core(uuid,uuid,text,jsonb,uuid,bigint,integer,date),tenant_private.add_customer(uuid,uuid,text,text),tenant_private.record_credit_sale(uuid,uuid,text,jsonb,uuid,bigint,integer,date),tenant_private.pay_debt(uuid,uuid,uuid,text,bigint),public.mt_add_customer(uuid,uuid,text,text),public.mt_record_credit_sale(uuid,uuid,text,jsonb,uuid,bigint,integer,date),public.mt_pay_debt(uuid,uuid,uuid,text,bigint),public.mt_list_customers(uuid,uuid,integer),public.mt_list_debts(uuid,uuid,integer),public.mt_debt_schedule(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.add_customer(uuid,uuid,text,text),tenant_private.record_credit_sale(uuid,uuid,text,jsonb,uuid,bigint,integer,date),tenant_private.pay_debt(uuid,uuid,uuid,text,bigint),public.mt_add_customer(uuid,uuid,text,text),public.mt_record_credit_sale(uuid,uuid,text,jsonb,uuid,bigint,integer,date),public.mt_pay_debt(uuid,uuid,uuid,text,bigint),public.mt_list_customers(uuid,uuid,integer),public.mt_list_debts(uuid,uuid,integer),public.mt_debt_schedule(uuid,uuid) to authenticated;
commit;