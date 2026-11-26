-- 115: immutable payroll correction events; apply after 114, only to the SaaS database.
begin;
create table tenant_private.staff_payroll_finalizations (
 store_id uuid not null, id uuid not null, payroll_id uuid not null,
 amount_minor bigint not null check(amount_minor between 0 and 100000000000000),
 actor uuid, created_at timestamptz not null default now(),
 primary key(store_id,id),
 foreign key(store_id,payroll_id) references tenant_private.staff_payroll(store_id,id)
);
-- Preserve actual historical cash amount, original closure timestamp and request.
-- Legacy actor is unavailable, so leave it null rather than inventing an identity.
insert into tenant_private.staff_payroll_finalizations(store_id,id,payroll_id,amount_minor,created_at)
select p.store_id,coalesce(p.payment_request,p.zero_payment_request),p.id,
 case when p.payment_request is null then 0 else c.amount_minor end,p.paid_at
from tenant_private.staff_payroll p
left join tenant_private.branch_vouchers v on v.store_id=p.store_id and v.request_id=p.payment_request
left join public.mt_cash_movements c on c.store_id=v.store_id and c.id=v.cash_id
where p.paid_at is not null;
do $$
begin
 if exists(select 1 from tenant_private.staff_payroll_finalizations f
 where f.amount_minor is distinct from tenant_private.payroll_due(f.store_id,f.payroll_id)) then
 raise exception 'Historical payroll requires reconciliation before reversal migration';
 end if;
end $$;
create table tenant_private.staff_payroll_reversals (
 store_id uuid not null, id uuid not null, kind text not null check(kind in ('partial','final','offset','advance')),
 original_id uuid not null, payroll_id uuid, advance_id uuid, cash_request uuid,
 amount_minor bigint not null check(amount_minor between 0 and 100000000000000),
 reason text not null check(length(btrim(reason)) between 1 and 160),
 actor uuid not null, created_at timestamptz not null default now(),
 primary key(store_id,id), unique(store_id,kind,original_id), unique(store_id,cash_request),
 foreign key(store_id,payroll_id) references tenant_private.staff_payroll(store_id,id),
 foreign key(store_id,advance_id) references tenant_private.staff_advances(store_id,id),
 foreign key(store_id,cash_request) references tenant_private.branch_vouchers(store_id,request_id),
 check(id<>original_id),
 check((kind in ('partial','final') and payroll_id is not null and advance_id is null) or
       (kind='offset' and payroll_id is not null and advance_id is not null) or
       (kind='advance' and payroll_id is null and advance_id is not null)),
 check((kind='offset' and cash_request is null and amount_minor>0) or
       (kind<>'offset' and ((amount_minor>0 and cash_request is not null and cash_request=id) or
                            (kind='final' and amount_minor=0 and cash_request is null))))
);
create index staff_payroll_finalizations_statement_idx on tenant_private.staff_payroll_finalizations(store_id,payroll_id);
create index staff_payroll_reversals_statement_idx on tenant_private.staff_payroll_reversals(store_id,payroll_id);
create index staff_payroll_reversals_advance_idx on tenant_private.staff_payroll_reversals(store_id,advance_id);
alter table tenant_private.staff_payroll_finalizations enable row level security;
alter table tenant_private.staff_payroll_reversals enable row level security;
revoke all on tenant_private.staff_payroll_finalizations,tenant_private.staff_payroll_reversals from public,anon,authenticated;
create trigger mt_guard_closed_period before insert on tenant_private.staff_payroll_finalizations for each row execute function tenant_private.guard_closed_period();
create trigger mt_guard_closed_period before insert on tenant_private.staff_payroll_reversals for each row execute function tenant_private.guard_closed_period();

create or replace function tenant_private.payroll_due(p_store uuid,p_id uuid)
returns bigint language sql stable security definer set search_path='' as $$
 select (p.total_minor+coalesce((select sum(case when a.kind='bonus' then a.amount_minor else -a.amount_minor end)
 from tenant_private.staff_payroll_adjustments a where a.store_id=p_store and a.payroll_id=p_id),0)
 -coalesce((select sum(o.amount_minor) from tenant_private.staff_advance_offsets o where o.store_id=p_store and o.payroll_id=p_id
 and not exists(select 1 from tenant_private.staff_payroll_reversals r where r.store_id=o.store_id and r.kind='offset' and r.original_id=o.id)),0)
 -coalesce((select sum(d.amount_minor) from tenant_private.staff_payroll_disbursements d where d.store_id=p_store and d.payroll_id=p_id
 and not exists(select 1 from tenant_private.staff_payroll_reversals r where r.store_id=d.store_id and r.kind='partial' and r.original_id=d.id)),0))::bigint
 from tenant_private.staff_payroll p where p.store_id=p_store and p.id=p_id
$$;

create or replace function tenant_private.advance_remaining(p_store uuid,p_id uuid)
returns bigint language sql stable security definer set search_path='' as $$
 select case when exists(select 1 from tenant_private.staff_payroll_reversals r where r.store_id=p_store and r.kind='advance' and r.original_id=p_id) then 0::bigint
 else (a.amount_minor-coalesce((select sum(o.amount_minor) from tenant_private.staff_advance_offsets o where o.store_id=p_store and o.advance_id=p_id
 and not exists(select 1 from tenant_private.staff_payroll_reversals r where r.store_id=o.store_id and r.kind='offset' and r.original_id=o.id)),0))::bigint end
 from tenant_private.staff_advances a where a.store_id=p_store and a.id=p_id
$$;

create or replace function tenant_private.staff_payroll_pay(p_store uuid,p_id uuid,p_request uuid,p_confirm boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare p tenant_private.staff_payroll%rowtype; f tenant_private.staff_payroll_finalizations%rowtype; due bigint;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_id is null or p_confirm is distinct from true then raise exception 'Confirm actual disbursement' using errcode='22023';end if;
 select * into f from tenant_private.staff_payroll_finalizations where store_id=p_store and id=p_request;
 if found then
  if f.payroll_id is distinct from p_id or (f.actor is not null and f.actor is distinct from auth.uid()) then raise exception 'Conflicting settlement' using errcode='22023';end if;
  return p_id;
 end if;
 select * into p from tenant_private.staff_payroll where store_id=p_store and id=p_id for update;
 if not found or p.paid_at is not null then raise exception 'Unpaid statement required' using errcode='22023';end if;
 if exists(select 1 from tenant_private.branch_vouchers where store_id=p_store and request_id=p_request)
 or exists(select 1 from tenant_private.staff_payroll_reversals where store_id=p_store and id=p_request) then raise exception 'Request used' using errcode='22023';end if;
 due:=tenant_private.payroll_due(p_store,p_id);
 if due not between 0 and 100000000000000 then raise exception 'Invalid payroll due' using errcode='22023';end if;
 if due>0 then
  perform tenant_private.branch_voucher(p_store,p_request,p.branch_id,'salary',p.currency,due,p.user_id::text,'Payroll '||p.period::text||' / '||p.id::text);
 end if;
 insert into tenant_private.staff_payroll_finalizations(store_id,id,payroll_id,amount_minor,actor) values(p_store,p_request,p_id,due,auth.uid());
 update tenant_private.staff_payroll set paid_at=now(),payment_request=case when due>0 then p_request end,
 zero_payment_request=case when due=0 then p_request end where store_id=p_store and id=p_id;
 return p_id;
end $$;

create function tenant_private.payroll_reverse(p_store uuid,p_id uuid,p_kind text,p_original uuid,p_reason text,p_confirm boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare r tenant_private.staff_payroll_reversals%rowtype; p tenant_private.staff_payroll%rowtype;
 a tenant_private.staff_advances%rowtype; o tenant_private.staff_advance_offsets%rowtype;
 d tenant_private.staff_payroll_disbursements%rowtype; f tenant_private.staff_payroll_finalizations%rowtype;
 pid uuid; aid uuid; cash_id uuid; amount bigint; location_id uuid; employee_id uuid; cur text;
begin
 perform tenant_private.owner_write(p_store);
 if p_id is null or p_original is null or p_id=p_original or p_kind is null or p_kind not in ('partial','final','offset','advance')
 or p_reason is null or length(btrim(p_reason)) not between 1 and 160 or p_confirm is distinct from true then
 raise exception 'Confirm reversal and provide reason' using errcode='22023';end if;
 select * into r from tenant_private.staff_payroll_reversals where store_id=p_store and id=p_id;
 if found then
  if r.kind is distinct from p_kind or r.original_id is distinct from p_original or r.reason is distinct from btrim(p_reason) or r.actor is distinct from auth.uid() then raise exception 'Conflicting reversal' using errcode='22023';end if;
  return p_id;
 end if;
 if exists(select 1 from tenant_private.staff_payroll_reversals where store_id=p_store and kind=p_kind and original_id=p_original)
 or exists(select 1 from tenant_private.branch_vouchers where store_id=p_store and request_id=p_id)
 or exists(select 1 from tenant_private.staff_payroll_finalizations where store_id=p_store and id=p_id)
 or exists(select 1 from public.mt_cash_movements where store_id=p_store and request_id=p_id)
 then raise exception 'Reversal or request already recorded' using errcode='22023';end if;
 if p_kind='partial' then
  select * into d from tenant_private.staff_payroll_disbursements where store_id=p_store and id=p_original;
  if not found then raise exception 'Unknown partial payment' using errcode='22023';end if;
  pid:=d.payroll_id;amount:=d.amount_minor;
 elsif p_kind='final' then
  select * into f from tenant_private.staff_payroll_finalizations where store_id=p_store and id=p_original;
  if not found then raise exception 'Unknown settlement' using errcode='22023';end if;
  pid:=f.payroll_id;amount:=f.amount_minor;
 elsif p_kind='offset' then
  select * into o from tenant_private.staff_advance_offsets where store_id=p_store and id=p_original;
  if not found then raise exception 'Unknown advance offset' using errcode='22023';end if;
  pid:=o.payroll_id;aid:=o.advance_id;amount:=o.amount_minor;
 else
  select * into a from tenant_private.staff_advances where store_id=p_store and id=p_original for update;
  if not found then raise exception 'Unknown advance' using errcode='22023';end if;
  aid:=a.id;amount:=a.amount_minor;location_id:=a.branch_id;employee_id:=a.user_id;cur:=a.currency;
  if tenant_private.advance_remaining(p_store,aid) is distinct from amount then raise exception 'Reverse all offsets before returning an advance' using errcode='22023';end if;
 end if;
 if pid is not null then
  select * into p from tenant_private.staff_payroll where store_id=p_store and id=pid for update;
  if not found then raise exception 'Unknown payroll' using errcode='22023';end if;
  location_id:=p.branch_id;employee_id:=p.user_id;cur:=p.currency;
  if p_kind='final' then
   if p.paid_at is null or coalesce(p.payment_request,p.zero_payment_request) is distinct from p_original then raise exception 'Current final settlement required' using errcode='22023';end if;
   if tenant_private.payroll_due(p_store,pid) is distinct from amount then raise exception 'Settlement amount mismatch' using errcode='22023';end if;
  else
   if p.paid_at is not null then raise exception 'Reverse final settlement first' using errcode='22023';end if;
   if tenant_private.payroll_due(p_store,pid)+amount>100000000000000 then raise exception 'Payroll payable limit exceeded' using errcode='22023';end if;
  end if;
 end if;
 if p_kind<>'offset' and amount>0 then
  -- Owner confirms actual repayment in the original currency/location; not a new sale or income.
  perform tenant_private.branch_voucher(p_store,p_id,location_id,'receipt',cur,amount,employee_id::text,btrim(p_reason));
  cash_id:=p_id;
 end if;
 insert into tenant_private.staff_payroll_reversals(store_id,id,kind,original_id,payroll_id,advance_id,cash_request,amount_minor,reason,actor)
 values(p_store,p_id,p_kind,p_original,pid,aid,cash_id,amount,btrim(p_reason),auth.uid());
 if p_kind='final' then
  -- Mutable current status only; all original finalizations and their original cash entries are retained.
  update tenant_private.staff_payroll set paid_at=null,payment_request=null,zero_payment_request=null where store_id=p_store and id=pid;
 end if;
 return p_id;
end $$;

create function public.mt_payroll_reverse(p_store uuid,p_id uuid,p_kind text,p_original uuid,p_reason text,p_confirm boolean)
returns uuid language sql set search_path='' as $$select tenant_private.payroll_reverse(p_store,p_id,p_kind,p_original,p_reason,p_confirm)$$;
revoke all on function tenant_private.payroll_reverse(uuid,uuid,text,uuid,text,boolean),public.mt_payroll_reverse(uuid,uuid,text,uuid,text,boolean) from public,anon,authenticated;
grant execute on function tenant_private.payroll_reverse(uuid,uuid,text,uuid,text,boolean),public.mt_payroll_reverse(uuid,uuid,text,uuid,text,boolean) to authenticated;

create or replace function tenant_private.payroll_details(p_store uuid,p_user uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare role_now text:=tenant_private.member_role(p_store);u uuid:=coalesce(p_user,auth.uid());
begin
 if auth.uid() is null or role_now is null or (role_now<>'owner' and u is distinct from auth.uid()) then raise exception 'Access denied' using errcode='42501';end if;
 return jsonb_build_object(
 'advances',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,id desc) from (
 select a.id,a.currency,a.branch_id,a.amount_minor,tenant_private.advance_remaining(a.store_id,a.id) remaining_minor,a.reference,a.created_at,
 r.id is not null reversed,r.id reversal_id
 from tenant_private.staff_advances a left join tenant_private.staff_payroll_reversals r on r.store_id=a.store_id and r.kind='advance' and r.original_id=a.id
 where a.store_id=p_store and a.user_id=u order by a.created_at desc,a.id desc limit 100)x),'[]'),
 'statements',coalesce((select jsonb_agg(to_jsonb(x) order by period desc) from (
 select p.id,p.period,p.currency,p.total_minor,p.paid_at,
 coalesce((select sum(amount_minor) from tenant_private.staff_payroll_adjustments a where a.store_id=p.store_id and a.payroll_id=p.id and a.kind='bonus'),0) bonus_minor,
 coalesce((select sum(amount_minor) from tenant_private.staff_payroll_adjustments a where a.store_id=p.store_id and a.payroll_id=p.id and a.kind='deduction'),0) deduction_minor,
 coalesce((select sum(o.amount_minor) from tenant_private.staff_advance_offsets o where o.store_id=p.store_id and o.payroll_id=p.id and not exists(select 1 from tenant_private.staff_payroll_reversals r where r.store_id=o.store_id and r.kind='offset' and r.original_id=o.id)),0) advance_minor,
 tenant_private.payroll_due(p.store_id,p.id)+d.amount net_minor,
 d.amount+case when p.paid_at is not null then tenant_private.payroll_due(p.store_id,p.id) else 0 end paid_minor,
 case when p.paid_at is not null then 0 else tenant_private.payroll_due(p.store_id,p.id) end remaining_minor
 from tenant_private.staff_payroll p
 cross join lateral (select coalesce(sum(x.amount_minor),0) amount from tenant_private.staff_payroll_disbursements x where x.store_id=p.store_id and x.payroll_id=p.id and not exists(select 1 from tenant_private.staff_payroll_reversals r where r.store_id=x.store_id and r.kind='partial' and r.original_id=x.id)) d
 where p.store_id=p_store and p.user_id=u order by p.period desc limit 36)x),'[]'),
 'adjustments',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,id desc) from (
 select a.id,a.payroll_id,p.currency,a.kind,a.amount_minor,a.reason,a.reverses,a.created_at,
 exists(select 1 from tenant_private.staff_payroll_adjustments r where r.store_id=a.store_id and r.reverses=a.id) reversed
 from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id
 where a.store_id=p_store and p.user_id=u order by a.created_at desc,a.id desc limit 100)x),'[]'),
 'payments',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,id desc) from (
 select d.id,d.payroll_id,p.currency,d.amount_minor,d.created_at,d.kind,r.id is not null reversed,r.id reversal_id
 from (select store_id,id,payroll_id,amount_minor,created_at,'partial'::text kind from tenant_private.staff_payroll_disbursements where store_id=p_store
 union all select store_id,id,payroll_id,amount_minor,created_at,'final' from tenant_private.staff_payroll_finalizations where store_id=p_store) d
 join tenant_private.staff_payroll p on p.store_id=d.store_id and p.id=d.payroll_id
 left join tenant_private.staff_payroll_reversals r on r.store_id=d.store_id and r.kind=d.kind and r.original_id=d.id
 where p.user_id=u order by d.created_at desc,d.id desc limit 100)x),'[]'),
 'offsets',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,id desc) from (
 select o.id,o.payroll_id,o.advance_id,p.currency,o.amount_minor,o.created_at,r.id is not null reversed,r.id reversal_id
 from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id
 left join tenant_private.staff_payroll_reversals r on r.store_id=o.store_id and r.kind='offset' and r.original_id=o.id
 where o.store_id=p_store and p.user_id=u order by o.created_at desc,o.id desc limit 100)x),'[]'),
 'reversals',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,id desc) from (
 select r.id,r.kind,r.original_id,r.payroll_id,r.advance_id,r.amount_minor,r.reason,r.created_at,coalesce(p.currency,a.currency) currency
 from tenant_private.staff_payroll_reversals r left join tenant_private.staff_payroll p on p.store_id=r.store_id and p.id=r.payroll_id
 left join tenant_private.staff_advances a on a.store_id=r.store_id and a.id=r.advance_id
 where r.store_id=p_store and coalesce(p.user_id,a.user_id)=u order by r.created_at desc,r.id desc limit 100)x),'[]'));
end $$;

CREATE OR REPLACE FUNCTION tenant_private.payroll_offset(p_store uuid, p_id uuid, p_payroll uuid, p_advance uuid, p_amount bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o tenant_private.staff_advance_offsets%rowtype;p tenant_private.staff_payroll%rowtype;a tenant_private.staff_advances%rowtype;begin
 perform tenant_private.owner_write(p_store);
 if p_id is null or p_amount is null or p_amount not between 1 and 100000000000000 then raise exception 'Invalid offset' using errcode='22023';end if;
 select * into o from tenant_private.staff_advance_offsets where store_id=p_store and id=p_id;
 if found then if o.actor<>auth.uid() or o.payroll_id<>p_payroll or o.advance_id<>p_advance or o.amount_minor<>p_amount then raise exception 'Conflicting offset' using errcode='22023';end if;return p_id;end if;
 select * into p from tenant_private.staff_payroll where store_id=p_store and id=p_payroll for update;
 if not found or p.paid_at is not null then raise exception 'Unpaid statement required' using errcode='22023';end if;
 select * into a from tenant_private.staff_advances where store_id=p_store and id=p_advance for update;
 if not found or a.user_id<>p.user_id or a.currency<>p.currency or p_amount>tenant_private.advance_remaining(p_store,p_advance) or p_amount>tenant_private.payroll_due(p_store,p_payroll) then raise exception 'Incompatible or insufficient advance' using errcode='22023';end if;
 insert into tenant_private.staff_advance_offsets(store_id,id,advance_id,payroll_id,amount_minor,actor) values(p_store,p_id,p_advance,p_payroll,p_amount,auth.uid());return p_id;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.journal_pairs(p_store uuid, p_until timestamp with time zone)
 RETURNS TABLE(posted_at timestamp with time zone, source_type text, source_id uuid, currency text, debit_account text, credit_account text, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
with cash as (
 select * from public.mt_cash_movements where store_id=p_store and created_at<p_until
),costs as (
 select * from tenant_private.cost_postings where store_id=p_store and created_at<p_until
),return_costs as (
 select r.*,l.currency as source_currency,r.units::numeric*l.unit_cost_minor as source_cost
 from tenant_private.return_cost_postings r join tenant_private.stock_layers l on l.store_id=r.store_id and l.product_id=r.product_id and l.id=r.layer_id
 where r.store_id=p_store and r.created_at<p_until
),pairs(posted_at,source_type,source_id,currency,debit_account,credit_account,amount) as (
 select c.created_at,'cash',c.id,c.currency,
 case when sd.direction='payable' then 'accounts_payable' when sd.direction='receivable' then 'cash' when b.direction='deposit' then 'bank' else case c.kind when 'expense' then 'expense_unclassified' when 'supplier_payment' then 'accounts_payable' when 'exchange' then 'fx_clearing' else 'cash' end end,
 case when rev.kind='advance' then 'employee_advances' when rev.kind in ('partial','final') then 'payroll_payable' when sd.direction='receivable' then 'accounts_receivable' when sd.direction='payable' then 'cash' when b.direction='withdrawal' then 'bank' else case c.kind when 'sale' then 'sales_revenue' when 'funding' then 'funding_unclassified' when 'debt_payment' then 'accounts_receivable' when 'repair_receipt' then 'repair_revenue' when 'mixed_receipt' then 'fx_clearing' when 'supplier_refund' then 'accounts_payable' else 'cash' end end,c.amount_minor::numeric
 from cash c left join tenant_private.staff_payroll_reversals rev on rev.store_id=c.store_id and rev.cash_request=c.request_id left join tenant_private.bank_transfers b on b.store_id=c.store_id and b.cash_id=c.id left join tenant_private.standalone_debt_payments sdp on sdp.store_id=c.store_id and sdp.cash_id=c.id left join tenant_private.standalone_debts sd on sd.store_id=sdp.store_id and sd.id=sdp.debt_id where c.kind in ('sale','funding','expense','exchange','debt_payment','supplier_payment','repair_receipt','mixed_receipt','supplier_refund')
 union all select created_at,'standalone_debt_opening',id,currency,case when direction='receivable' then 'accounts_receivable' else 'funding_unclassified' end,case when direction='receivable' then 'funding_unclassified' else 'accounts_payable' end,principal_minor from tenant_private.standalone_debts where store_id=p_store and created_at<p_until
 union all select created_at,'exchange_target',id,target_currency,'cash','fx_clearing',target_amount_minor from cash where kind='exchange'
 union all select created_at,'credit_sale',id,currency,'accounts_receivable','sales_revenue',total_minor from public.mt_sales where store_id=p_store and payment_mode='credit' and created_at<p_until
 union all select created_at,'mixed_sale',id,currency,'fx_clearing','sales_revenue',total_minor from public.mt_sales where store_id=p_store and payment_mode='mixed' and created_at<p_until
 union all select created_at,'sale_return_debt',id,currency,'sales_returns','accounts_receivable',debt_reduction_minor from public.mt_returns where store_id=p_store and created_at<p_until
 union all select created_at,'sale_return_cash',id,currency,'sales_returns','cash',refund_minor from public.mt_returns where store_id=p_store and created_at<p_until
 union all select created_at,'repair_refund',id,currency,'sales_returns','cash',amount_minor from public.mt_repair_refunds where store_id=p_store and created_at<p_until
 union all select created_at,'purchase',id,currency,'inventory','accounts_payable',total_minor from public.mt_purchases where store_id=p_store and created_at<p_until
 union all select created_at,'supplier_return',id,currency,'accounts_payable','inventory',units::numeric*unit_cost_minor from public.mt_supplier_returns where store_id=p_store and created_at<p_until
 union all select e.created_at,'standalone_intake',e.request_id,i.currency,'inventory','stock_intake_unclassified',i.units::numeric*i.unit_cost_minor
 from tenant_private.cost_intakes i join public.mt_stock_events e on e.store_id=i.store_id and e.request_id=i.request_id
 where i.store_id=p_store and e.created_at<p_until and not exists(select 1 from public.mt_purchases p where p.store_id=i.store_id and p.intake_request=i.request_id)
 union all select e.created_at,'stock_adjustment',e.request_id,l.currency,'stock_adjustment_expense','inventory',a.units::numeric*l.unit_cost_minor
 from public.mt_stock_events e join tenant_private.stock_consumptions a on a.store_id=e.store_id and a.product_id=e.product_id and a.event_id=e.request_id
 join tenant_private.stock_layers l on l.store_id=a.store_id and l.product_id=a.product_id and l.id=a.layer_id
 where e.store_id=p_store and e.created_at<p_until and e.delta<0 and e.sale_id is null and e.supplier_return_id is null and not exists(select 1 from tenant_private.cost_postings r where r.store_id=e.store_id and r.event_id=e.request_id)
 union all select created_at,'cost_source',event_id,source_currency,
 case when source_currency<>invoice_currency and invoice_cost_minor is not null then 'fx_clearing' else 'cost_of_goods_services' end,'inventory',source_cost_minor from costs
 union all select created_at,'cost_conversion',event_id,invoice_currency,'cost_of_goods_services','fx_clearing',invoice_cost_minor from costs where source_currency<>invoice_currency and invoice_cost_minor is not null
 union all select created_at,'return_cost_source',return_id,source_currency,'inventory',
 case when source_currency<>invoice_currency and invoice_cost_minor is not null then 'fx_clearing' else 'cost_of_goods_services' end,source_cost from return_costs
 union all select created_at,'return_cost_conversion',return_id,invoice_currency,'fx_clearing','cost_of_goods_services',invoice_cost_minor from return_costs where source_currency<>invoice_currency and invoice_cost_minor is not null
 union all select created_at,'tradein_offset',id,currency,'accounts_payable','accounts_receivable',offset_minor from tenant_private.tradein_settlements where store_id=p_store and created_at<p_until
 union all select a.created_at,'accounting_adjustment',a.id,a.currency,case when adv.id is not null then 'employee_advances' when p.id is not null or dis.id is not null then 'payroll_payable' else a.debit_account end,a.credit_account,a.amount_minor from public.mt_accounting_adjustments a left join tenant_private.branch_vouchers v on v.store_id=a.store_id and v.adjustment_id=a.id left join tenant_private.staff_payroll_finalizations p on p.store_id=v.store_id and p.id=v.request_id left join tenant_private.staff_payroll_disbursements dis on dis.store_id=v.store_id and dis.id=v.request_id left join tenant_private.staff_advances adv on adv.store_id=v.store_id and adv.id=v.request_id where a.store_id=p_store and a.created_at<p_until
 union all select a.created_at,'payroll_adjustment',a.id,p.currency,case when a.kind='bonus' then 'payroll_expense' else 'payroll_payable' end,case when a.kind='bonus' then 'payroll_payable' else 'payroll_expense' end,a.amount_minor from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id where a.store_id=p_store and a.created_at<p_until
 union all select o.created_at,'payroll_advance_offset',o.id,p.currency,'payroll_payable','employee_advances',o.amount_minor from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id where o.store_id=p_store and o.created_at<p_until
 union all select r.created_at,'payroll_offset_reversal',r.id,p.currency,'employee_advances','payroll_payable',r.amount_minor from tenant_private.staff_payroll_reversals r join tenant_private.staff_payroll p on p.store_id=r.store_id and p.id=r.payroll_id where r.store_id=p_store and r.kind='offset' and r.created_at<p_until
 union all select created_at,'payroll_accrual',id,currency,'payroll_expense','payroll_payable',total_minor from tenant_private.staff_payroll where store_id=p_store and created_at<p_until
 union all select created_at,'indirect_tax',id,currency,case kind when 'sale' then 'sales_revenue' when 'repair' then 'repair_revenue' else 'indirect_tax_payable' end,case when kind in ('sale','repair') then 'indirect_tax_payable' else 'sales_returns' end,tax_minor from public.mt_indirect_tax_entries where store_id=p_store and created_at<p_until
)
select * from pairs where pairs.amount>0;
$function$;

CREATE OR REPLACE FUNCTION tenant_private.branch_journal_projection(p_store uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  select m.id,m.request_id,case when a.posted then a.branch_id else coalesce(s.branch_id,ds.branch_id,ret.branch_id,p.branch_id,sr.branch_id,i.branch_id,rr.branch_id,bk.branch_id,v.branch_id,sd.branch_id) end branch_id
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
  left join tenant_private.standalone_debt_payments sdp on sdp.store_id=m.store_id and sdp.cash_id=m.id left join tenant_private.standalone_debts sd on sd.store_id=sdp.store_id and sd.id=sdp.debt_id
  where m.store_id=p_store
 ), cost_loc as (
  select c.event_id id,coalesce(s.branch_id,i.branch_id) branch_id
  from tenant_private.cost_postings c left join sale_loc s on s.id=c.sale_id left join repair_loc i on i.id=c.repair_invoice_id where c.store_id=p_store
 ), sources(kind,id,branch_id) as (
  select 'stock_adjustment',event_id,branch_id from tenant_private.stock_count_lines where store_id=p_store
  union all
  select k,c.id,c.branch_id from cash_loc c cross join unnest(array['cash','exchange_target']) k
  union all select k,s.id,s.branch_id from sale_loc s cross join unnest(array['credit_sale','mixed_sale']) k
  union all select k,r.id,r.branch_id from return_loc r cross join unnest(array['sale_return_debt','sale_return_cash','return_cost_source','return_cost_conversion']) k
  union all select 'repair_refund',id,branch_id from repair_refund_loc
  union all select 'purchase',id,branch_id from purchase_loc
  union all select 'supplier_return',id,branch_id from supplier_return_loc
  union all select k,c.id,c.branch_id from cost_loc c cross join unnest(array['cost_source','cost_conversion']) k
  union all select 'accounting_adjustment',a.id,coalesce(v.branch_id,c.branch_id) from public.mt_accounting_adjustments a left join tenant_private.branch_vouchers v on v.store_id=a.store_id and v.adjustment_id=a.id left join cash_loc c on c.request_id=a.source_request where a.store_id=p_store
  union all select 'standalone_debt_opening',id,branch_id from tenant_private.standalone_debts where store_id=p_store
  union all select 'payroll_accrual',id,branch_id from tenant_private.staff_payroll where store_id=p_store
  union all select 'payroll_adjustment',a.id,p.branch_id from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id where a.store_id=p_store
  union all select 'payroll_advance_offset',o.id,case when p.branch_id is not distinct from a.branch_id then p.branch_id end from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id join tenant_private.staff_advances a on a.store_id=o.store_id and a.id=o.advance_id where o.store_id=p_store
  union all select 'payroll_offset_reversal',r.id,case when a.branch_id is not distinct from p.branch_id then a.branch_id end from tenant_private.staff_payroll_reversals r join tenant_private.staff_payroll p on p.store_id=r.store_id and p.id=r.payroll_id join tenant_private.staff_advances a on a.store_id=r.store_id and a.id=r.advance_id where r.store_id=p_store and r.kind='offset'
  union all select 'tradein_offset',t.id,case when s.branch_id is not distinct from p.branch_id then s.branch_id end from tenant_private.tradein_settlements t join sale_loc s on s.id=t.sale_id join purchase_loc p on p.id=t.purchase_id where t.store_id=p_store
  union all select 'indirect_tax',t.id,coalesce(s.branch_id,i.branch_id) from public.mt_indirect_tax_entries t left join sale_loc s on t.kind in ('sale','sale_return') and s.id=t.invoice_id left join repair_loc i on t.kind in ('repair','repair_refund') and i.id=t.invoice_id where t.store_id=p_store
 ), unique_sources as (
  select kind,id,case when count(distinct coalesce(branch_id::text,''))=1 then min(branch_id::text)::uuid end branch_id from sources group by kind,id
 ), offset_locations as (
  select 'payroll_advance_offset'::text kind,o.id,p.branch_id debit_branch,a.branch_id credit_branch
  from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id join tenant_private.staff_advances a on a.store_id=o.store_id and a.id=o.advance_id where o.store_id=p_store
  union all select 'payroll_offset_reversal',r.id,a.branch_id,p.branch_id from tenant_private.staff_payroll_reversals r join tenant_private.staff_payroll p on p.store_id=r.store_id and p.id=r.payroll_id join tenant_private.staff_advances a on a.store_id=r.store_id and a.id=r.advance_id where r.store_id=p_store and r.kind='offset'
  union all select 'tradein_offset',t.id,p.branch_id,s.branch_id from tenant_private.tradein_settlements t join sale_loc s on s.id=t.sale_id join purchase_loc p on p.id=t.purchase_id where t.store_id=p_store
 ), journal as (
  select j.*,s.branch_id,o.id is not null and o.debit_branch is distinct from o.credit_branch as split,o.debit_branch,o.credit_branch
  from tenant_private.journal_pairs(p_store,hi) j left join unique_sources s on s.kind=j.source_type and s.id=j.source_id
  left join offset_locations o on o.kind=j.source_type and o.id=j.source_id
 ), canonical as (
  select posted_at,currency,debit_account,credit_account,amount,branch_id from journal where not split
 ), offset_pairs as (
  -- Split cross-location noncash offsets across the exact original debit/credit locations.
  select posted_at,currency,debit_account,'interbranch_clearing'::text credit_account,amount,debit_branch branch_id from journal where split
  union all select posted_at,currency,'interbranch_clearing',credit_account,amount,credit_branch from journal where split
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
  union all select * from offset_pairs
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
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.branch_operating_result(p_store uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb;lo timestamptz;hi timestamptz;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 then raise exception 'Invalid period' using errcode='22023';end if;
 lo:=p_from::timestamp at time zone 'Asia/Damascus';hi:=(p_to+1)::timestamp at time zone 'Asia/Damascus';
 with sale_branch as (select s.id,s.created_at,s.currency,s.total_minor,b.branch_id from public.mt_sales s join tenant_private.branch_sales b on b.store_id=s.store_id and b.sale_id=s.id where s.store_id=p_store),
 repair_branch as (select i.id,i.created_at,i.currency,i.total_minor,b.branch_id from public.mt_repair_invoices i join tenant_private.branch_repairs b on b.store_id=i.store_id and b.repair_id=i.repair_id where i.store_id=p_store),
 events(branch_id,currency,revenue,cost,expense,unknown) as (
 select branch_id,currency,total_minor::numeric,0::numeric,0::numeric,0 from sale_branch where created_at>=lo and created_at<hi
 union all select branch_id,currency,total_minor,0,0,0 from repair_branch where created_at>=lo and created_at<hi
 union all select b.branch_id,r.currency,-r.total_minor,0,0,0 from public.mt_returns r join sale_branch b on b.id=r.sale_id where r.store_id=p_store and r.created_at>=lo and r.created_at<hi
 union all select b.branch_id,r.currency,-r.amount_minor,0,0,0 from public.mt_repair_refunds r join repair_branch b on b.id=r.invoice_id where r.store_id=p_store and r.created_at>=lo and r.created_at<hi
 union all select coalesce(s.branch_id,b.branch_id),c.invoice_currency,0,coalesce(c.invoice_cost_minor,0),0,case when c.invoice_cost_minor is null then 1 else 0 end from tenant_private.cost_postings c left join sale_branch s on s.id=c.sale_id left join repair_branch b on b.id=c.repair_invoice_id where c.store_id=p_store and c.created_at>=lo and c.created_at<hi and coalesce(s.branch_id,b.branch_id) is not null
 union all select s.branch_id,c.invoice_currency,0,-coalesce(c.invoice_cost_minor,0),0,case when c.invoice_cost_minor is null then 1 else 0 end from tenant_private.return_cost_postings c join public.mt_returns r on r.store_id=c.store_id and r.id=c.return_id join sale_branch s on s.id=r.sale_id where c.store_id=p_store and c.created_at>=lo and c.created_at<hi
 union all select v.branch_id,m.currency,0,0,m.amount_minor,0 from tenant_private.branch_vouchers v join public.mt_cash_movements m on m.store_id=v.store_id and m.id=v.cash_id where v.store_id=p_store and v.branch_id is not null and v.kind<>'receipt' and not exists(select 1 from tenant_private.staff_advances a where a.store_id=v.store_id and a.id=v.request_id) and not exists(select 1 from tenant_private.staff_payroll_finalizations p where p.store_id=v.store_id and p.id=v.request_id) and not exists(select 1 from tenant_private.staff_payroll_disbursements d where d.store_id=v.store_id and d.id=v.request_id) and m.created_at>=lo and m.created_at<hi
 union all select branch_id,currency,0,0,total_minor,0 from tenant_private.staff_payroll where store_id=p_store and branch_id is not null and created_at>=lo and created_at<hi
 union all select p.branch_id,p.currency,0,0,case when a.kind='bonus' then a.amount_minor else -a.amount_minor end,0 from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id where a.store_id=p_store and p.branch_id is not null and a.created_at>=lo and a.created_at<hi
 ), grouped as (select branch_id,currency,sum(revenue) as revenue,sum(cost) as cost,sum(expense) as expense,sum(unknown)::bigint as unknown from events group by branch_id,currency)
 select coalesce(jsonb_agg(jsonb_build_object('branch',g.branch_id,'name',b.name,'currency',g.currency,'revenue',trunc(g.revenue)::text,'cost',case when g.unknown=0 then trunc(g.cost)::text end,'expenses',trunc(g.expense)::text,'result',case when g.unknown=0 then trunc(g.revenue-g.cost-g.expense)::text end,'unknown',g.unknown) order by b.name,g.currency),'[]') into r from grouped g join tenant_private.branches b on b.store_id=p_store and b.id=g.branch_id;
 return r;
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.business_export(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t text;v jsonb;out_data jsonb:='{}';n bigint;total_rows bigint:=0;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' or not tenant_private.shared_licensed(p_store) or auth.jwt()->>'aal' is distinct from 'aal2' then raise exception 'Owner and AAL2 required' using errcode='42501';end if;
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.staff_advances','tenant_private.staff_advance_offsets','tenant_private.staff_payroll_adjustments','tenant_private.staff_payroll_disbursements','tenant_private.staff_payroll_finalizations','tenant_private.staff_payroll_reversals','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines','tenant_private.stock_count_cancellations','tenant_private.procurement_grants','tenant_private.procurement_requests','tenant_private.sale_invoice_details','tenant_private.sale_warranty_claims','tenant_private.sale_warranty_events','tenant_private.pos_loyalty_sales','tenant_private.customer_profile_edits','tenant_private.standalone_debts','tenant_private.standalone_installments','tenant_private.standalone_debt_payments','tenant_private.standalone_payment_allocations','tenant_private.receivable_grants','tenant_private.receivable_resolutions','tenant_private.membership_rates','tenant_private.membership_directory','tenant_private.buyer_product_prices','tenant_private.product_tier_prices','tenant_private.local_membership_terms','tenant_private.local_customer_prices','tenant_private.local_membership_sales','tenant_private.spend_loyalty_policy','tenant_private.spend_loyalty_sales','tenant_private.spend_checkout','tenant_private.order_discounts','tenant_private.spend_pos_redemptions'] loop
 -- Fixed relation allowlist; no user-supplied table or SQL text.
 execute format('select count(*) from (select 1 from %I.%I where store_id=$1 limit 5001)x',split_part(t,'.',1),split_part(t,'.',2)) into n using p_store;
 if n>5000 or total_rows+n>20000 then raise exception 'Export exceeds browser snapshot limit; use controlled server backup' using errcode='22023';end if;
 -- Limit before building the aggregate, including large image-containing product rows.
 execute format('select coalesce(sum(octet_length(to_jsonb(r)::text)),0) from %I.%I r where store_id=$1',split_part(t,'.',1),split_part(t,'.',2)) into n using p_store;
 if n>4000000 or octet_length(out_data::text)+n>8000000 then raise exception 'Export exceeds browser byte limit' using errcode='22023';end if;
 execute format('select coalesce(jsonb_agg(to_jsonb(r)),''[]''::jsonb) from %I.%I r where store_id=$1',split_part(t,'.',1),split_part(t,'.',2)) into v using p_store;
 total_rows:=total_rows+jsonb_array_length(v);out_data:=out_data||jsonb_build_object(t,v);
 end loop;
 return jsonb_build_object('version',1,'scope','business_export_only','store',p_store,'captured_at',now(),'rows',total_rows,'tables',out_data);
end $function$;
commit;
