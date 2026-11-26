-- Immutable, owner-approved management allocations, not statutory postings.
-- Source is the current open Damascus reporting month; no historical rewrite.
begin;
create table tenant_private.branch_expense_allocations(
 store_id uuid not null,request_id uuid not null,branch_id uuid not null,currency text not null,
 account text not null check(account in ('rent_expense','payroll_expense','utilities_expense','other_operating_expense','income_tax_expense','expense_unclassified')),
 amount_minor bigint not null check(amount_minor between 1 and 100000000000000),
 reference text not null check(length(btrim(reference)) between 1 and 160),
 reverses uuid,actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,request_id),unique(store_id,reverses),
 foreign key(store_id,branch_id) references tenant_private.branches(store_id,id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),
 foreign key(store_id,reverses) references tenant_private.branch_expense_allocations(store_id,request_id),
 check(reverses is distinct from request_id)
);
alter table tenant_private.branch_expense_allocations enable row level security;
revoke all on tenant_private.branch_expense_allocations from public,anon,authenticated,service_role;
create index mt_branch_expense_date on tenant_private.branch_expense_allocations(store_id,created_at desc,request_id desc);
create trigger mt_guard_closed_period before insert on tenant_private.branch_expense_allocations for each row execute function tenant_private.guard_closed_period();
create or replace function tenant_private.branch_journal_projection(p_store uuid,p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare lo timestamptz;hi timestamptz;result jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 or p_to>(now() at time zone 'Asia/Damascus')::date then raise exception 'Invalid period' using errcode='22023';end if;
 lo:=p_from::timestamp at time zone 'Asia/Damascus';hi:=(p_to+1)::timestamp at time zone 'Asia/Damascus';
 with sale_loc as (
  select s.id,b.branch_id from public.mt_sales s left join tenant_private.branch_sales b on b.store_id=s.store_id and b.sale_id=s.id where s.store_id=p_store
 ), purchase_loc as (
  select p.id,p.intake_request,b.branch_id from public.mt_purchases p left join tenant_private.branch_purchases b on b.store_id=p.store_id and b.purchase_id=p.id where p.store_id=p_store
 ), repair_loc as (
  select i.id,b.branch_id from public.mt_repair_invoices i left join tenant_private.branch_repairs b on b.store_id=i.store_id and b.repair_id=i.repair_id where i.store_id=p_store
 ), return_loc as (
  select r.id,s.branch_id from public.mt_returns r join sale_loc s on s.id=r.sale_id where r.store_id=p_store
 ), supplier_return_loc as (
  select r.id,p.branch_id from public.mt_supplier_returns r join purchase_loc p on p.id=r.purchase_id where r.store_id=p_store
 ), repair_refund_loc as (
  select r.id,i.branch_id from public.mt_repair_refunds r join repair_loc i on i.id=r.invoice_id where r.store_id=p_store
 ), cash_loc as (
  select m.id,m.request_id,case when a.posted then a.branch_id else coalesce(s.branch_id,ds.branch_id,ret.branch_id,p.branch_id,sr.branch_id,i.branch_id,rr.branch_id,bk.branch_id,v.branch_id) end branch_id
  from public.mt_cash_movements m
  left join tenant_private.branch_cash_attribution a on a.store_id=m.store_id and a.cash_id=m.id
  left join sale_loc s on s.id=coalesce(m.sale_id,m.mixed_sale_id)
  left join public.mt_debt_payments dp on dp.store_id=m.store_id and dp.id=m.debt_payment_id
  left join public.mt_debts d on d.store_id=dp.store_id and d.id=dp.debt_id
  left join sale_loc ds on ds.id=d.sale_id
  left join return_loc ret on ret.id=m.return_id
  left join public.mt_supplier_payments sp on sp.store_id=m.store_id and sp.id=m.supplier_payment_id
  left join purchase_loc p on p.id=sp.purchase_id
  left join supplier_return_loc sr on sr.id=m.supplier_return_id
  left join repair_loc i on i.id=m.repair_invoice_id
  left join repair_refund_loc rr on rr.id=m.repair_refund_id
  left join tenant_private.bank_transfers bt on bt.store_id=m.store_id and bt.cash_id=m.id
  left join tenant_private.bank_accounts bk on bk.store_id=bt.store_id and bk.id=bt.account_id
  left join tenant_private.branch_vouchers v on v.store_id=m.store_id and v.cash_id=m.id
  where m.store_id=p_store
 ), cost_loc as (
  select c.event_id id,coalesce(s.branch_id,i.branch_id) branch_id
  from tenant_private.cost_postings c left join sale_loc s on s.id=c.sale_id left join repair_loc i on i.id=c.repair_invoice_id where c.store_id=p_store
 ), sources(kind,id,branch_id) as (
  select k,c.id,c.branch_id from cash_loc c cross join unnest(array['cash','exchange_target']) k
  union all select k,s.id,s.branch_id from sale_loc s cross join unnest(array['credit_sale','mixed_sale']) k
  union all select k,r.id,r.branch_id from return_loc r cross join unnest(array['sale_return_debt','sale_return_cash','return_cost_source','return_cost_conversion']) k
  union all select 'repair_refund',id,branch_id from repair_refund_loc
  union all select 'purchase',id,branch_id from purchase_loc
  union all select 'supplier_return',id,branch_id from supplier_return_loc
  union all select k,c.id,c.branch_id from cost_loc c cross join unnest(array['cost_source','cost_conversion']) k
  union all select 'accounting_adjustment',a.id,coalesce(v.branch_id,c.branch_id) from public.mt_accounting_adjustments a left join tenant_private.branch_vouchers v on v.store_id=a.store_id and v.adjustment_id=a.id left join cash_loc c on c.request_id=a.source_request where a.store_id=p_store
  union all select 'payroll_accrual',id,branch_id from tenant_private.staff_payroll where store_id=p_store
  union all select 'payroll_adjustment',a.id,p.branch_id from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id where a.store_id=p_store
  union all select 'payroll_advance_offset',o.id,case when p.branch_id is not distinct from a.branch_id then p.branch_id end from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id join tenant_private.staff_advances a on a.store_id=o.store_id and a.id=o.advance_id where o.store_id=p_store
  union all select 'tradein_offset',t.id,case when s.branch_id is not distinct from p.branch_id then s.branch_id end from tenant_private.tradein_settlements t join sale_loc s on s.id=t.sale_id join purchase_loc p on p.id=t.purchase_id where t.store_id=p_store
  union all select 'indirect_tax',t.id,coalesce(s.branch_id,i.branch_id) from public.mt_indirect_tax_entries t left join sale_loc s on t.kind in ('sale','sale_return') and s.id=t.invoice_id left join repair_loc i on t.kind in ('repair','repair_refund') and i.id=t.invoice_id where t.store_id=p_store
 ), unique_sources as (
  select kind,id,case when count(distinct coalesce(branch_id::text,''))=1 then min(branch_id::text)::uuid end branch_id from sources group by kind,id
 ), canonical as (
  select j.posted_at,j.currency,j.debit_account,j.credit_account,j.amount,s.branch_id
  from tenant_private.journal_pairs(p_store,hi) j left join unique_sources s on s.kind=j.source_type and s.id=j.source_id
 ), internal_moves as (
  select t.created_at posted_at,t.currency,t.amount_minor::numeric amount,t.source,t.target,'cash'::text account
  from tenant_private.branch_cash_transfers t where t.store_id=p_store and t.created_at<hi
  union all
  select t.created_at,l.currency,m.units::numeric*l.unit_cost_minor,t.source,t.target,'inventory'
  from tenant_private.branch_fifo_moves m join tenant_private.branch_transfers t on t.store_id=m.store_id and t.request_id=m.request_id
  join tenant_private.stock_layers l on l.store_id=m.store_id and l.product_id=m.product_id and l.id=m.layer_id
  where m.store_id=p_store and t.created_at<hi and l.currency is not null and l.unit_cost_minor is not null
 ), pairs as (
  select * from canonical
  union all select posted_at,currency,'interbranch_clearing',account,amount,source from internal_moves where amount>0
  union all select posted_at,currency,account,'interbranch_clearing',amount,target from internal_moves where amount>0
  -- Management allocations affect branch results, never consolidated cash, tax or statutory accounts.
  union all select a.created_at,a.currency,case when a.reverses is null then 'interbranch_clearing' else a.account end,
    case when a.reverses is null then a.account else 'interbranch_clearing' end,a.amount_minor::numeric,null::uuid
    from tenant_private.branch_expense_allocations a where a.store_id=p_store and a.created_at<hi
  union all select a.created_at,a.currency,case when a.reverses is null then a.account else 'interbranch_clearing' end,
    case when a.reverses is null then 'interbranch_clearing' else a.account end,a.amount_minor::numeric,a.branch_id
    from tenant_private.branch_expense_allocations a where a.store_id=p_store and a.created_at<hi
 ), legs as (
  select branch_id,currency,debit_account account,posted_at,amount debit,0::numeric credit from pairs
  union all select branch_id,currency,credit_account,posted_at,0::numeric,amount from pairs
 ), grouped as (
  select branch_id,currency,account,coalesce(sum(debit-credit) filter(where posted_at<lo),0) opening,
    coalesce(sum(debit) filter(where posted_at>=lo),0) debit,coalesce(sum(credit) filter(where posted_at>=lo),0) credit,
    sum(debit-credit) closing
  from legs group by branch_id,currency,account
 ), rows as (
  select g.branch_id,coalesce(b.name,'المركزي / غير الموزع') name,g.currency,g.account,g.opening::text,g.debit::text,g.credit::text,g.closing::text
  from grouped g left join tenant_private.branches b on b.store_id=p_store and b.id=g.branch_id
 )
 select jsonb_build_object('mode','branch_journal_projection','from',p_from,'to',p_to,
  'unallocated_pair_count',(select count(*) from canonical where branch_id is null),
  'unknown_transfer_units',coalesce((select sum(m.units) from tenant_private.branch_fifo_moves m join tenant_private.branch_transfers t on t.store_id=m.store_id and t.request_id=m.request_id join tenant_private.stock_layers l on l.store_id=m.store_id and l.product_id=m.product_id and l.id=m.layer_id where m.store_id=p_store and t.created_at<hi and (l.currency is null or l.unit_cost_minor is null)),0)::text,
  'opening_verified',false,
  'rows',coalesce((select jsonb_agg(to_jsonb(r) order by r.name,r.currency,r.account) from rows r),'[]'::jsonb)) into result;
 return result;
end $$;

create function tenant_private.branch_expense_allocate(p_store uuid,p_request uuid,p_branch uuid,p_currency text,p_account text,p_amount bigint,p_reference text) returns uuid
language plpgsql security definer set search_path='' as $$
declare old tenant_private.branch_expense_allocations%rowtype;today date:=(now() at time zone 'Asia/Damascus')::date;first_day date;cutoff date;r jsonb;available numeric;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_branch is null or p_currency is null or p_account is null or p_account not in ('rent_expense','payroll_expense','utilities_expense','other_operating_expense','income_tax_expense','expense_unclassified') or p_amount is null or p_amount not between 1 and 100000000000000 or p_reference is null or length(btrim(p_reference)) not between 1 and 160 then raise exception 'Invalid allocation' using errcode='22023';end if;
 select * into old from tenant_private.branch_expense_allocations where store_id=p_store and request_id=p_request;
 if found then
  if old.actor is distinct from auth.uid() or old.branch_id is distinct from p_branch or old.currency is distinct from p_currency or old.account is distinct from p_account or old.amount_minor is distinct from p_amount or old.reference is distinct from btrim(p_reference) or old.reverses is not null then raise exception 'Conflicting request' using errcode='22023';end if;
  return old.request_id;
 end if;
 perform tenant_private.require_branch(p_store,p_branch);
 if not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_currency) then raise exception 'Currency unavailable' using errcode='22023';end if;
 first_day:=date_trunc('month',today::timestamp)::date;
 select max(period_to) into cutoff from public.mt_period_closes where store_id=p_store;
 -- Existing closed periods use UTC. Exclude the entire Damascus day following a closed UTC day.
 if cutoff is not null then first_day:=greatest(first_day,cutoff+2);end if;
 if first_day>today then raise exception 'No open reporting day' using errcode='22023';end if;
 r:=tenant_private.branch_journal_projection(p_store,first_day,today);
 select coalesce(sum((v->>'debit')::numeric-(v->>'credit')::numeric),0) into available from jsonb_array_elements(r->'rows') v
 where v->>'branch_id' is null and v->>'currency'=p_currency and v->>'account'=p_account;
 if available<p_amount then raise exception 'Allocation exceeds available central expense' using errcode='22023';end if;
 insert into tenant_private.branch_expense_allocations(store_id,request_id,branch_id,currency,account,amount_minor,reference,actor)
 values(p_store,p_request,p_branch,p_currency,p_account,p_amount,btrim(p_reference),auth.uid());return p_request;
end $$;
create function tenant_private.branch_expense_reverse(p_store uuid,p_request uuid,p_original uuid,p_reference text) returns uuid
language plpgsql security definer set search_path='' as $$
declare old tenant_private.branch_expense_allocations%rowtype;original tenant_private.branch_expense_allocations%rowtype;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_original is null or p_request=p_original or p_reference is null or length(btrim(p_reference)) not between 1 and 160 then raise exception 'Invalid reversal' using errcode='22023';end if;
 select * into old from tenant_private.branch_expense_allocations where store_id=p_store and request_id=p_request;
 if found then
  if old.actor is distinct from auth.uid() or old.reverses is distinct from p_original or old.reference is distinct from btrim(p_reference) then raise exception 'Conflicting reversal' using errcode='22023';end if;return old.request_id;
 end if;
 select * into original from tenant_private.branch_expense_allocations where store_id=p_store and request_id=p_original and reverses is null;
 if not found or exists(select 1 from tenant_private.branch_expense_allocations where store_id=p_store and reverses=p_original) then raise exception 'Unknown or already reversed allocation' using errcode='22023';end if;
 insert into tenant_private.branch_expense_allocations(store_id,request_id,branch_id,currency,account,amount_minor,reference,reverses,actor)
 values(p_store,p_request,original.branch_id,original.currency,original.account,original.amount_minor,btrim(p_reference),p_original,auth.uid());return p_request;
end $$;
create function tenant_private.branch_expense_list(p_store uuid,p_before timestamptz,p_before_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if (p_before is null)<>(p_before_id is null) then raise exception 'Invalid page' using errcode='22023';end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.request_id desc) from (
 select a.request_id,a.branch_id,a.currency,a.account,a.amount_minor::text amount_minor,a.reference,a.reverses,a.created_at,
 exists(select 1 from tenant_private.branch_expense_allocations r where r.store_id=a.store_id and r.reverses=a.request_id) reversed
 from tenant_private.branch_expense_allocations a where a.store_id=p_store and (p_before is null or (a.created_at,a.request_id)<(p_before,p_before_id)) order by a.created_at desc,a.request_id desc limit 50)x),'[]'::jsonb);
end $$;
create function public.mt_branch_expense_allocate(p_store uuid,p_request uuid,p_branch uuid,p_currency text,p_account text,p_amount bigint,p_reference text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.branch_expense_allocate(p_store,p_request,p_branch,p_currency,p_account,p_amount,p_reference)$$;
create function public.mt_branch_expense_reverse(p_store uuid,p_request uuid,p_original uuid,p_reference text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.branch_expense_reverse(p_store,p_request,p_original,p_reference)$$;
create function public.mt_branch_expense_list(p_store uuid,p_before timestamptz default null,p_before_id uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.branch_expense_list(p_store,p_before,p_before_id)$$;
revoke all on function tenant_private.branch_expense_allocate(uuid,uuid,uuid,text,text,bigint,text),tenant_private.branch_expense_reverse(uuid,uuid,uuid,text),tenant_private.branch_expense_list(uuid,timestamptz,uuid),public.mt_branch_expense_allocate(uuid,uuid,uuid,text,text,bigint,text),public.mt_branch_expense_reverse(uuid,uuid,uuid,text),public.mt_branch_expense_list(uuid,timestamptz,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.branch_expense_allocate(uuid,uuid,uuid,text,text,bigint,text),tenant_private.branch_expense_reverse(uuid,uuid,uuid,text),tenant_private.branch_expense_list(uuid,timestamptz,uuid),public.mt_branch_expense_allocate(uuid,uuid,uuid,text,text,bigint,text),public.mt_branch_expense_reverse(uuid,uuid,uuid,text),public.mt_branch_expense_list(uuid,timestamptz,uuid) to authenticated;
commit;
