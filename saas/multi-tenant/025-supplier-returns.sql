begin;
-- Exact original purchase layer required; refuse to infer links for historic purchases.
do $$ begin
 if to_regclass('public.mt_purchase_batches') is null or to_regclass('public.ts_workspace') is not null then raise exception 'Shared SaaS required';end if;
 if exists(select 1 from public.mt_purchases) then raise exception 'Historical purchase layer reconciliation required';end if;
end $$;
alter table public.mt_purchases add column intake_request uuid not null,
 add foreign key(store_id,intake_request) references tenant_private.cost_intakes(store_id,request_id),
 add unique(store_id,intake_request),
 add column returned_units bigint not null default 0 check(returned_units>=0 and returned_units<=units),
 add column refunded_minor bigint not null default 0 check(refunded_minor>=0 and refunded_minor<=paid_minor and refunded_minor<=returned_units*unit_cost_minor),
 add check(paid_minor-refunded_minor<=(units-returned_units)*unit_cost_minor);
create table public.mt_supplier_returns(
 store_id uuid not null,id uuid not null default gen_random_uuid(),request_id uuid not null,purchase_id uuid not null,
 units bigint not null check(units between 1 and 1000000),currency text not null,
 unit_cost_minor bigint not null check(unit_cost_minor between 1 and 100000000),
 debt_reduction_minor bigint not null check(debt_reduction_minor>=0),refund_minor bigint not null check(refund_minor>=0),
 reason text not null check(length(btrim(reason)) between 1 and 300),actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,request_id),foreign key(store_id,purchase_id) references public.mt_purchases(store_id,id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),
 check(debt_reduction_minor+refund_minor=units*unit_cost_minor)
);
create index mt_supplier_return_purchase on public.mt_supplier_returns(store_id,purchase_id,id);
alter table public.mt_supplier_returns enable row level security;
revoke all on public.mt_supplier_returns from public,anon,authenticated,service_role;
grant select on public.mt_supplier_returns to authenticated;
create policy owner_read on public.mt_supplier_returns for select to authenticated using (tenant_private.member_role(store_id)='owner');
alter table public.mt_stock_events add column supplier_return_id uuid,add foreign key(store_id,supplier_return_id) references public.mt_supplier_returns(store_id,id),add unique(store_id,supplier_return_id),add check(supplier_return_id is null or (sale_id is null and return_id is null and delta<0));
alter table public.mt_cash_movements drop constraint mt_cash_movements_kind_check,
 add constraint mt_cash_movements_kind_check check(kind in ('sale','funding','expense','exchange','debt_payment','return_refund','supplier_payment','repair_receipt','mixed_receipt','supplier_refund')),
 add column supplier_return_id uuid,add foreign key(store_id,supplier_return_id) references public.mt_supplier_returns(store_id,id),add unique(store_id,supplier_return_id),add check((kind='supplier_refund')=(supplier_return_id is not null));
create or replace function tenant_private.purchase(p_store uuid,p_request uuid,p_supplier uuid,p_product uuid,p_currency text,p_units bigint,p_cost bigint,p_paid bigint,p_note text) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.mt_purchases%rowtype; v_payment uuid; intake_id uuid:=gen_random_uuid();
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_supplier is null or p_product is null or p_currency is null or p_units is null or p_units not between 1 and 1000000 or p_cost is null or p_cost not between 1 and 100000000 or p_paid is null or p_paid<0 or p_paid>p_units*p_cost or p_note is null or length(btrim(p_note)) not between 1 and 300 then raise exception 'Invalid purchase' using errcode='22023';end if;
 select * into r from public.mt_purchases where store_id=p_store and request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.supplier_id<>p_supplier or r.product_id<>p_product or r.currency<>p_currency or r.units<>p_units or r.unit_cost_minor<>p_cost or r.initial_paid_minor<>p_paid or r.note<>btrim(p_note) then raise exception 'Conflicting purchase request' using errcode='22023';end if;
  return r.id;
 end if;
 if not exists(select 1 from public.mt_suppliers where store_id=p_store and id=p_supplier) or not exists(select 1 from public.mt_products where store_id=p_store and id=p_product) or not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_currency) then raise exception 'Invalid purchase references' using errcode='22023';end if;
 -- A dedicated internal stock event ID cannot alias a prior standalone intake.
 perform tenant_private.receive_costed_stock(p_store,p_product,intake_id,p_units,p_currency,p_cost,btrim(p_note));
 insert into public.mt_purchases(store_id,request_id,supplier_id,product_id,currency,units,unit_cost_minor,paid_minor,initial_paid_minor,note,actor,intake_request) values(p_store,p_request,p_supplier,p_product,p_currency,p_units,p_cost,p_paid,p_paid,btrim(p_note),auth.uid(),intake_id) returning * into r;
 if p_paid>0 then
  insert into public.mt_supplier_payments(store_id,request_id,purchase_id,amount_minor,is_initial,actor) values(p_store,gen_random_uuid(),r.id,p_paid,true,auth.uid()) returning id into v_payment;
  insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,supplier_payment_id) values(p_store,gen_random_uuid(),'supplier_payment',p_currency,p_paid,'Purchase initial payment',auth.uid(),v_payment);
 end if;
 return r.id;
end $$;
create or replace function tenant_private.pay_supplier(p_store uuid,p_request uuid,p_purchase uuid,p_currency text,p_amount bigint) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.mt_purchases%rowtype; v public.mt_supplier_payments%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_purchase is null or p_currency is null or p_amount is null or p_amount not between 1 and 100000000000000 then raise exception 'Invalid payment' using errcode='22023';end if;
 select * into r from public.mt_purchases where store_id=p_store and id=p_purchase for update;
 if not found or r.currency<>p_currency then raise exception 'Purchase or currency mismatch' using errcode='22023';end if;
 select * into v from public.mt_supplier_payments where store_id=p_store and request_id=p_request;
 if found then
  if v.is_initial or v.actor<>auth.uid() or v.purchase_id<>p_purchase or v.amount_minor<>p_amount then raise exception 'Conflicting payment' using errcode='22023';end if;
  return v.id;
 end if;
 if p_amount>r.total_minor-r.returned_units*r.unit_cost_minor-r.paid_minor+r.refunded_minor then raise exception 'Payment exceeds payable' using errcode='22023';end if;
 insert into public.mt_supplier_payments(store_id,request_id,purchase_id,amount_minor,actor) values(p_store,p_request,p_purchase,p_amount,auth.uid()) returning * into v;
 update public.mt_purchases set paid_minor=paid_minor+p_amount where store_id=p_store and id=p_purchase;
 insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,supplier_payment_id) values(p_store,gen_random_uuid(),'supplier_payment',r.currency,p_amount,'Supplier settlement',auth.uid(),v.id);
 return v.id;
end $$;
create or replace function tenant_private.post_stock_cost() returns trigger
language plpgsql security definer set search_path='' as $$
declare intake tenant_private.cost_intakes%rowtype; l tenant_private.stock_layers%rowtype; c tenant_private.stock_consumptions%rowtype; remaining bigint; used bigint; original_event uuid; intake_id uuid;
begin
 if new.supplier_return_id is not null then
  select p.intake_request into strict intake_id from public.mt_supplier_returns sr join public.mt_purchases p on p.store_id=sr.store_id and p.id=sr.purchase_id where sr.store_id=new.store_id and sr.id=new.supplier_return_id and p.product_id=new.product_id and sr.units=-new.delta;
  select * into l from tenant_private.stock_layers where store_id=new.store_id and product_id=new.product_id and intake_request=intake_id for update;
  if not found or l.remaining_units< -new.delta then raise exception 'Original purchase layer has insufficient stock' using errcode='22023';end if;
  update tenant_private.stock_layers set remaining_units=remaining_units+new.delta where store_id=l.store_id and product_id=l.product_id and id=l.id;
  insert into tenant_private.stock_consumptions(store_id,product_id,event_id,layer_id,units) values(l.store_id,l.product_id,new.request_id,l.id,-new.delta);
 elsif new.return_id is not null then
  select e.request_id into strict original_event from public.mt_returns r join public.mt_stock_events e on e.store_id=r.store_id and e.sale_id=r.sale_id and e.product_id=r.product_id where r.store_id=new.store_id and r.id=new.return_id and r.product_id=new.product_id;
  remaining:=new.delta;
  for c in select * from tenant_private.stock_consumptions where store_id=new.store_id and product_id=new.product_id and event_id=original_event and restored_units<units order by layer_id for update loop
   exit when remaining=0;
   used:=least(remaining,c.units-c.restored_units);
   update tenant_private.stock_consumptions set restored_units=restored_units+used where store_id=c.store_id and product_id=c.product_id and event_id=c.event_id and layer_id=c.layer_id;
   update tenant_private.stock_layers set remaining_units=remaining_units+used where store_id=c.store_id and product_id=c.product_id and id=c.layer_id;
   remaining:=remaining-used;
  end loop;
  if remaining<>0 then raise exception 'Return cost allocation mismatch';end if;
 elsif new.delta>0 then
  select * into intake from tenant_private.cost_intakes where store_id=new.store_id and request_id=new.request_id;
  if found and (intake.product_id<>new.product_id or intake.units<>new.delta or intake.actor<>new.actor) then raise exception 'Cost intake mismatch';end if;
  insert into tenant_private.stock_layers(store_id,product_id,intake_request,original_units,remaining_units,currency,unit_cost_minor) values(new.store_id,new.product_id,new.request_id,new.delta,new.delta,intake.currency,intake.unit_cost_minor);
 else
  remaining:=-new.delta;
  for l in select * from tenant_private.stock_layers where store_id=new.store_id and product_id=new.product_id and remaining_units>0 order by id for update loop
   exit when remaining=0;
   used:=least(remaining,l.remaining_units);
   update tenant_private.stock_layers set remaining_units=remaining_units-used where store_id=l.store_id and product_id=l.product_id and id=l.id;
   insert into tenant_private.stock_consumptions(store_id,product_id,event_id,layer_id,units) values(l.store_id,l.product_id,new.request_id,l.id,used);
   remaining:=remaining-used;
  end loop;
  if remaining<>0 then raise exception 'Insufficient tracked stock layers';end if;
 end if;
 if (select coalesce(sum(remaining_units),0) from tenant_private.stock_layers where store_id=new.store_id and product_id=new.product_id and remaining_units>0)<>new.balance then raise exception 'Stock layer balance mismatch';end if;
 return new;
end $$;
create or replace function tenant_private.cash_post() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.saas_stores where id=new.store_id for update;
 if new.kind in ('sale','funding','debt_payment','repair_receipt','mixed_receipt','supplier_refund') then
  insert into tenant_private.cash_balances(store_id,currency,balance_minor) values(new.store_id,new.currency,new.amount_minor) on conflict(store_id,currency) do update set balance_minor=cash_balances.balance_minor+excluded.balance_minor;
 else
  update tenant_private.cash_balances set balance_minor=balance_minor-new.amount_minor where store_id=new.store_id and currency=new.currency and balance_minor>=new.amount_minor;
  if not found then raise exception 'Insufficient cash in source currency' using errcode='22023';end if;
  if new.kind='exchange' then insert into tenant_private.cash_balances(store_id,currency,balance_minor) values(new.store_id,new.target_currency,new.target_amount_minor) on conflict(store_id,currency) do update set balance_minor=cash_balances.balance_minor+excluded.balance_minor;end if;
 end if;return new;
end $$;
create or replace function tenant_private.cash_report(p_store uuid,p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 then raise exception 'Invalid date range' using errcode='22023';end if;
 with movements as (select * from public.mt_cash_movements where store_id=p_store and created_at>=p_from::timestamp at time zone 'UTC' and created_at<(p_to+1)::timestamp at time zone 'UTC'),
 flows as (select currency,kind,case when kind in ('sale','funding','debt_payment','repair_receipt','mixed_receipt','supplier_refund') then amount_minor else -amount_minor end as value from movements union all select target_currency,'exchange_in',target_amount_minor from movements where kind='exchange'),
 totals as (select currency,sum(value) filter(where value>0) as incoming,sum(-value) filter(where value<0) as outgoing,sum(value) as net,sum(value) filter(where kind in ('sale','debt_payment','repair_receipt','mixed_receipt')) as collections,sum(-value) filter(where kind='return_refund') as refunds,sum(-value) filter(where kind='supplier_payment') as supplier_payments,sum(value) filter(where kind='supplier_refund') as supplier_refunds,sum(-value) filter(where kind='expense') as expenses from flows group by currency)
 select coalesce(jsonb_agg(jsonb_build_object('currency',c.currency,'incoming',coalesce(t.incoming,0)::text,'outgoing',coalesce(t.outgoing,0)::text,'net',coalesce(t.net,0)::text,'collections',coalesce(t.collections,0)::text,'refunds',coalesce(t.refunds,0)::text,'supplier_payments',coalesce(t.supplier_payments,0)::text,'supplier_refunds',coalesce(t.supplier_refunds,0)::text,'expenses',coalesce(t.expenses,0)::text) order by c.currency),'[]'::jsonb) into r
 from tenant_private.sale_currencies c left join totals t on t.currency=c.currency where c.store_id=p_store;
 return r;
end $$;
create or replace function tenant_private.cash_reconciliation(p_store uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 with flows as (
 select currency,case when kind in ('sale','funding','debt_payment','repair_receipt','mixed_receipt','supplier_refund') then amount_minor::numeric else -amount_minor::numeric end amount from public.mt_cash_movements where store_id=p_store
 union all select target_currency,target_amount_minor::numeric from public.mt_cash_movements where store_id=p_store and kind='exchange'
 ), sums as (select currency,sum(amount) as computed from flows group by currency),
 vals as (select c.currency,coalesce(b.balance_minor,0)::numeric recorded,coalesce(s.computed,0) computed from tenant_private.sale_currencies c left join tenant_private.cash_balances b on b.store_id=c.store_id and b.currency=c.currency left join sums s on s.currency=c.currency where c.store_id=p_store)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'recorded',recorded::text,'computed',computed::text,'difference',(recorded-computed)::text,'balanced',recorded=computed) order by currency),'[]'::jsonb) into r from vals;
 return r;
end $$;
create or replace function public.mt_list_purchase_batches(p_store uuid,p_after uuid default null,p_limit integer default 50) returns table(store_id uuid,id uuid,supplier_id uuid,currency text,reference text,total_minor bigint,paid_minor bigint,created_at timestamptz)
language plpgsql stable security invoker set search_path='' as $$
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select b.store_id,b.id,b.supplier_id,b.currency,b.reference,(b.total_minor-(select coalesce(sum(p.returned_units*p.unit_cost_minor),0)::bigint from public.mt_purchases p where p.store_id=b.store_id and p.batch_id=b.id)),(select coalesce(sum(p.paid_minor-p.refunded_minor),0)::bigint from public.mt_purchases p where p.store_id=b.store_id and p.batch_id=b.id),b.created_at from public.mt_purchase_batches b where b.store_id=p_store and (p_after is null or b.id>p_after) order by b.id limit p_limit;
end $$;
create function tenant_private.supplier_return(p_store uuid,p_request uuid,p_purchase uuid,p_units bigint,p_reason text,p_confirm_refund boolean) returns uuid
language plpgsql security definer set search_path='' as $$
declare p public.mt_purchases%rowtype; r public.mt_supplier_returns%rowtype; l tenant_private.stock_layers%rowtype; v_total bigint; v_reduce bigint; v_refund bigint; q bigint;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_purchase is null or p_units is null or p_units not between 1 and 1000000 or p_reason is null or length(btrim(p_reason)) not between 1 and 300 or p_confirm_refund is null then raise exception 'Invalid return' using errcode='22023';end if;
 select * into r from public.mt_supplier_returns where store_id=p_store and request_id=p_request;
 if found then
 if r.actor<>auth.uid() or r.purchase_id<>p_purchase or r.units<>p_units or r.reason<>btrim(p_reason) or (r.refund_minor>0 and not p_confirm_refund) then raise exception 'Conflicting return request' using errcode='22023';end if;return r.id;
 end if;
 select * into p from public.mt_purchases where store_id=p_store and id=p_purchase for update;
 if not found or p_units>p.units-p.returned_units then raise exception 'Invalid purchase or quantity' using errcode='22023';end if;
 select * into l from tenant_private.stock_layers where store_id=p_store and product_id=p.product_id and intake_request=p.intake_request for update;
 if not found or l.remaining_units<p_units then raise exception 'Original purchase stock unavailable' using errcode='22023';end if;
 v_total:=p_units*p.unit_cost_minor;
 v_reduce:=least(v_total,p.total_minor-p.returned_units*p.unit_cost_minor-p.paid_minor+p.refunded_minor);
 v_refund:=v_total-v_reduce;
 if v_refund>0 and not p_confirm_refund then raise exception 'Confirm actual cash received from supplier' using errcode='22023';end if;
 insert into public.mt_supplier_returns(store_id,request_id,purchase_id,units,currency,unit_cost_minor,debt_reduction_minor,refund_minor,reason,actor) values(p_store,p_request,p_purchase,p_units,p.currency,p.unit_cost_minor,v_reduce,v_refund,btrim(p_reason),auth.uid()) returning * into r;
 update public.mt_purchases set returned_units=returned_units+p_units,refunded_minor=refunded_minor+v_refund where store_id=p_store and id=p_purchase;
 update public.mt_products set quantity=quantity-p_units where store_id=p_store and id=p.product_id and quantity>=p_units returning quantity into q;
 if not found then raise exception 'Insufficient stock' using errcode='22023';end if;
 insert into public.mt_stock_events(store_id,request_id,product_id,delta,balance,actor,supplier_return_id) values(p_store,gen_random_uuid(),p.product_id,-p_units,q,auth.uid(),r.id);
 if v_refund>0 then insert into public.mt_cash_movements(store_id,request_id,kind,currency,amount_minor,note,actor,supplier_return_id) values(p_store,gen_random_uuid(),'supplier_refund',p.currency,v_refund,'Supplier refund received',auth.uid(),r.id);end if;
 return r.id;
end $$;
create function public.mt_supplier_return(p_store uuid,p_request uuid,p_purchase uuid,p_units bigint,p_reason text,p_confirm_refund boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.supplier_return(p_store,p_request,p_purchase,p_units,p_reason,p_confirm_refund)$$;
create function public.mt_list_supplier_returns(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.mt_supplier_returns language plpgsql stable security invoker set search_path='' as $$
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select * from public.mt_supplier_returns where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;
end $$;
revoke all on function tenant_private.supplier_return(uuid,uuid,uuid,bigint,text,boolean),public.mt_supplier_return(uuid,uuid,uuid,bigint,text,boolean),public.mt_list_supplier_returns(uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.supplier_return(uuid,uuid,uuid,bigint,text,boolean),public.mt_supplier_return(uuid,uuid,uuid,bigint,text,boolean),public.mt_list_supplier_returns(uuid,uuid,integer) to authenticated;
commit;