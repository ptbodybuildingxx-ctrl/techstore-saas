-- Development returns: one intact/restockable sale line per request, credit first then cash.
begin;
do $$ begin
 if to_regclass('public.mt_debts') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS project required';end if;
end $$;
alter table public.mt_installments add column waived_minor bigint not null default 0 check(waived_minor>=0 and waived_minor+paid_minor<=amount_minor);
create table public.mt_returns(
 store_id uuid not null,
 id uuid not null default gen_random_uuid(),
 request_id uuid not null,
 sale_id uuid not null,
 product_id uuid not null,
 units bigint not null check(units between 1 and 10000),
 currency text not null,
 unit_price_minor bigint not null check(unit_price_minor between 1 and 100000000),
 total_minor bigint generated always as (units*unit_price_minor) stored,
 debt_reduction_minor bigint not null check(debt_reduction_minor>=0),
 refund_minor bigint not null check(refund_minor>=0),
 reason text not null check(length(btrim(reason)) between 1 and 300),
 actor uuid not null,
 created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,request_id),
 foreign key(store_id,sale_id,product_id) references public.mt_sale_lines(store_id,sale_id,product_id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),
 check(debt_reduction_minor+refund_minor=units*unit_price_minor)
);
create index mt_returns_sale_line_idx on public.mt_returns(store_id,sale_id,product_id);
create table public.mt_return_allocations(
 store_id uuid not null,
 return_id uuid not null,
 debt_id uuid not null,
 installment_number integer not null,
 amount_minor bigint not null check(amount_minor>0),
 primary key(store_id,return_id,installment_number),
 foreign key(store_id,return_id) references public.mt_returns(store_id,id),
 foreign key(store_id,debt_id,installment_number) references public.mt_installments(store_id,debt_id,number)
);
alter table public.mt_returns enable row level security;
alter table public.mt_return_allocations enable row level security;
revoke all on public.mt_returns,public.mt_return_allocations from public,anon,authenticated,service_role;
grant select on public.mt_returns,public.mt_return_allocations to authenticated;
create policy mt_owner_read on public.mt_returns for select to authenticated using (tenant_private.member_role(store_id)='owner');
create policy mt_owner_read on public.mt_return_allocations for select to authenticated using (tenant_private.member_role(store_id)='owner');
alter table public.mt_cash_movements drop constraint mt_cash_movements_kind_check;
alter table public.mt_cash_movements add constraint mt_cash_movements_kind_check check(kind in ('sale','funding','expense','exchange','debt_payment','return_refund'));
alter table public.mt_cash_movements add column return_id uuid;
alter table public.mt_cash_movements add foreign key(store_id,return_id) references public.mt_returns(store_id,id);
alter table public.mt_cash_movements add unique(store_id,return_id);
alter table public.mt_cash_movements add check((kind='return_refund')=(return_id is not null));
alter table public.mt_stock_events add column return_id uuid;
alter table public.mt_stock_events add foreign key(store_id,return_id) references public.mt_returns(store_id,id);
alter table public.mt_stock_events add unique(store_id,return_id);
alter table public.mt_stock_events add check(return_id is null or (sale_id is null and delta>0));
create or replace function tenant_private.pay_debt(p_store uuid,p_debt uuid,p_request uuid,p_currency text,p_amount bigint) returns uuid
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
 for i in select * from public.mt_installments where store_id=p_store and debt_id=p_debt and paid_minor+waived_minor<amount_minor order by number for update loop
  exit when left_amount=0;
  applied:=least(left_amount,i.amount_minor-i.paid_minor-i.waived_minor);
  update public.mt_installments set paid_minor=paid_minor+applied where store_id=p_store and debt_id=p_debt and number=i.number;
  insert into public.mt_payment_allocations(store_id,payment_id,debt_id,installment_number,amount_minor) values(p_store,p.id,p_debt,i.number,applied);
  left_amount:=left_amount-applied;
 end loop;
 if left_amount<>0 then raise exception 'Installment allocation mismatch';end if;
 update public.mt_debts set remaining_minor=remaining_minor-p_amount where store_id=p_store and id=p_debt;
 insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,debt_payment_id) values(p_store,gen_random_uuid(),'debt_payment',d.currency,p_amount,'Debt collection',auth.uid(),p.id);
 return p.id;
end $$;
create function tenant_private.record_return(p_store uuid,p_request uuid,p_sale uuid,p_product uuid,p_units bigint,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.mt_returns%rowtype; s public.mt_sales%rowtype; l public.mt_sale_lines%rowtype; d public.mt_debts%rowtype; i public.mt_installments%rowtype; returned bigint; v_total bigint; v_reduce bigint:=0; v_refund bigint; left_amount bigint; applied bigint; q bigint;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 perform 1 from public.saas_stores where id=p_store for update;
 if not coalesce(tenant_private.can_sell(p_store),false) then raise exception 'Trial write denied' using errcode='42501';end if;
 if p_request is null or p_sale is null or p_product is null or p_units is null or p_units not between 1 and 10000 or p_reason is null or length(btrim(p_reason)) not between 1 and 300 then raise exception 'Invalid return' using errcode='22023';end if;
 select * into r from public.mt_returns where store_id=p_store and request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.sale_id<>p_sale or r.product_id<>p_product or r.units<>p_units or r.reason<>btrim(p_reason) then raise exception 'Conflicting return request' using errcode='22023';end if;
  return to_jsonb(r);
 end if;
 select * into s from public.mt_sales where store_id=p_store and id=p_sale;
 if not found then raise exception 'Unknown sale' using errcode='22023';end if;
 select * into l from public.mt_sale_lines where store_id=p_store and sale_id=p_sale and product_id=p_product;
 if not found then raise exception 'Unknown sale line' using errcode='22023';end if;
 select coalesce(sum(units),0)::bigint into returned from public.mt_returns where store_id=p_store and sale_id=p_sale and product_id=p_product;
 if returned+p_units>l.units then raise exception 'Return exceeds sold quantity' using errcode='22023';end if;
 v_total:=p_units*l.unit_price_minor;
 if s.payment_mode='credit' then
  select * into strict d from public.mt_debts where store_id=p_store and sale_id=p_sale for update;
  v_reduce:=least(v_total,d.remaining_minor);
 end if;
 v_refund:=v_total-v_reduce;
 insert into public.mt_returns(store_id,request_id,sale_id,product_id,units,currency,unit_price_minor,debt_reduction_minor,refund_minor,reason,actor)
 values(p_store,p_request,p_sale,p_product,p_units,s.currency,l.unit_price_minor,v_reduce,v_refund,btrim(p_reason),auth.uid()) returning * into r;
 if v_reduce>0 then
  left_amount:=v_reduce;
  -- Preserve historical payments; reduce unpaid installments starting with the last.
  for i in select * from public.mt_installments where store_id=p_store and debt_id=d.id and paid_minor+waived_minor<amount_minor order by number desc for update loop
   exit when left_amount=0;
   applied:=least(left_amount,i.amount_minor-i.paid_minor-i.waived_minor);
   update public.mt_installments set waived_minor=waived_minor+applied where store_id=p_store and debt_id=d.id and number=i.number;
   insert into public.mt_return_allocations(store_id,return_id,debt_id,installment_number,amount_minor) values(p_store,r.id,d.id,i.number,applied);
   left_amount:=left_amount-applied;
  end loop;
  if left_amount<>0 then raise exception 'Return allocation mismatch';end if;
  update public.mt_debts set remaining_minor=remaining_minor-v_reduce where store_id=p_store and id=d.id;
 end if;
 if v_refund>0 then
  insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,return_id)
  values(p_store,gen_random_uuid(),'return_refund',s.currency,v_refund,'Sale return refund',auth.uid(),r.id);
 end if;
 update public.mt_products set quantity=quantity+p_units where store_id=p_store and id=p_product returning quantity into q;
 insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor,return_id) values(p_store,gen_random_uuid(),p_product,p_units,q,auth.uid(),r.id);
 return to_jsonb(r);
end $$;
create function public.mt_record_return(p_store uuid,p_request uuid,p_sale uuid,p_product uuid,p_units bigint,p_reason text) returns jsonb
language sql security invoker set search_path='' as $$ select tenant_private.record_return(p_store,p_request,p_sale,p_product,p_units,p_reason) $$;
create function public.mt_returnable_lines(p_store uuid,p_sale uuid)
returns table(product_id uuid,sku text,product_name text,units bigint,returned_units bigint,unit_price_minor bigint,currency text)
language plpgsql stable security invoker set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return query select l.product_id,l.sku,l.product_name,l.units,coalesce((select sum(r.units)::bigint from public.mt_returns r where r.store_id=l.store_id and r.sale_id=l.sale_id and r.product_id=l.product_id),0),l.unit_price_minor,s.currency
 from public.mt_sale_lines l join public.mt_sales s on s.store_id=l.store_id and s.id=l.sale_id where l.store_id=p_store and l.sale_id=p_sale order by l.product_id;
end $$;
create function public.mt_list_returns(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.mt_returns
language plpgsql stable security invoker set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select * from public.mt_returns where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;
end $$;
revoke all on function tenant_private.record_return(uuid,uuid,uuid,uuid,bigint,text),public.mt_record_return(uuid,uuid,uuid,uuid,bigint,text),public.mt_returnable_lines(uuid,uuid),public.mt_list_returns(uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.record_return(uuid,uuid,uuid,uuid,bigint,text),public.mt_record_return(uuid,uuid,uuid,uuid,bigint,text),public.mt_returnable_lines(uuid,uuid),public.mt_list_returns(uuid,uuid,integer) to authenticated;
commit;