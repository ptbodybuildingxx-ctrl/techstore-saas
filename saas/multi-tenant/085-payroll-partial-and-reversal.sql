-- Partial disbursements settle the existing liability, never duplicate payroll expense.
-- The established final-payment RPC remains valid and settles only the remaining amount.
begin;
create table tenant_private.staff_payroll_disbursements(
 store_id uuid not null,id uuid not null,payroll_id uuid not null,amount_minor bigint not null check(amount_minor between 1 and 100000000000000),
 actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,id),foreign key(store_id,id) references tenant_private.branch_vouchers(store_id,request_id),foreign key(store_id,payroll_id) references tenant_private.staff_payroll(store_id,id)
);
alter table tenant_private.staff_payroll_disbursements enable row level security;
revoke all on tenant_private.staff_payroll_disbursements from public,anon,authenticated,service_role;
create index mt_payroll_disbursement_statement on tenant_private.staff_payroll_disbursements(store_id,payroll_id);
create trigger mt_guard_closed_period before insert on tenant_private.staff_payroll_disbursements for each row execute function tenant_private.guard_closed_period();
alter table tenant_private.staff_payroll_adjustments add column reverses uuid,
 add foreign key(store_id,reverses) references tenant_private.staff_payroll_adjustments(store_id,id),add unique(store_id,reverses),add check(reverses is distinct from id);
create or replace function tenant_private.payroll_due(p_store uuid,p_id uuid) returns bigint language sql stable security definer set search_path='' as $$
 select (p.total_minor+coalesce((select sum(case when a.kind='bonus' then a.amount_minor else -a.amount_minor end) from tenant_private.staff_payroll_adjustments a where a.store_id=p_store and a.payroll_id=p_id),0)-coalesce((select sum(o.amount_minor) from tenant_private.staff_advance_offsets o where o.store_id=p_store and o.payroll_id=p_id),0)-coalesce((select sum(d.amount_minor) from tenant_private.staff_payroll_disbursements d where d.store_id=p_store and d.payroll_id=p_id),0))::bigint from tenant_private.staff_payroll p where p.store_id=p_store and p.id=p_id
$$;

create function tenant_private.payroll_partial(p_store uuid,p_id uuid,p_request uuid,p_amount bigint,p_confirm boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare p tenant_private.staff_payroll%rowtype;d tenant_private.staff_payroll_disbursements%rowtype;due bigint;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_id is null or p_amount is null or p_amount not between 1 and 100000000000000 or p_confirm is distinct from true then raise exception 'Confirm actual partial disbursement' using errcode='22023';end if;
 select * into d from tenant_private.staff_payroll_disbursements where store_id=p_store and id=p_request;
 if found then
  if d.actor is distinct from auth.uid() or d.payroll_id is distinct from p_id or d.amount_minor is distinct from p_amount then raise exception 'Conflicting partial disbursement' using errcode='22023';end if;
  return p_request;
 end if;
 select * into p from tenant_private.staff_payroll where store_id=p_store and id=p_id for update;
 if not found or p.paid_at is not null then raise exception 'Unpaid statement required' using errcode='22023';end if;
 due:=tenant_private.payroll_due(p_store,p_id);
 if p_amount>=due then raise exception 'Partial payment must be less than remaining due; use final settlement' using errcode='22023';end if;
 if exists(select 1 from tenant_private.branch_vouchers where store_id=p_store and request_id=p_request) then raise exception 'Request used' using errcode='22023';end if;
 perform tenant_private.branch_voucher(p_store,p_request,p.branch_id,'salary',p.currency,p_amount,p.user_id::text,'Partial payroll '||p.id::text);
 insert into tenant_private.staff_payroll_disbursements(store_id,id,payroll_id,amount_minor,actor) values(p_store,p_request,p_id,p_amount,auth.uid());
 return p_request;
end $$;
create function tenant_private.payroll_adjust_reverse(p_store uuid,p_id uuid,p_original uuid,p_reason text) returns uuid language plpgsql security definer set search_path='' as $$
declare a tenant_private.staff_payroll_adjustments%rowtype;old tenant_private.staff_payroll_adjustments%rowtype;k text;
begin
 perform tenant_private.owner_write(p_store);
 if p_id is null or p_original is null or p_id=p_original or p_reason is null or length(btrim(p_reason)) not between 1 and 160 then raise exception 'Invalid reversal' using errcode='22023';end if;
 select * into old from tenant_private.staff_payroll_adjustments where store_id=p_store and id=p_id;
 if found then
  if old.actor is distinct from auth.uid() or old.reverses is distinct from p_original or old.reason is distinct from btrim(p_reason) then raise exception 'Conflicting reversal' using errcode='22023';end if;return p_id;
 end if;
 select * into a from tenant_private.staff_payroll_adjustments where store_id=p_store and id=p_original and reverses is null;
 if not found or exists(select 1 from tenant_private.staff_payroll_adjustments where store_id=p_store and reverses=p_original) then raise exception 'Unknown or already reversed adjustment' using errcode='22023';end if;
 k:=case when a.kind='bonus' then 'deduction' else 'bonus' end;
 perform tenant_private.payroll_adjust(p_store,p_id,a.payroll_id,k,a.amount_minor,p_reason);
 update tenant_private.staff_payroll_adjustments set reverses=p_original where store_id=p_store and id=p_id;
 return p_id;
end $$;
create or replace function tenant_private.journal_pairs(p_store uuid,p_until timestamptz)
returns table(posted_at timestamptz,source_type text,source_id uuid,currency text,debit_account text,credit_account text,amount numeric)
language sql stable security definer set search_path='' as $$
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
 case when b.direction='deposit' then 'bank' else case c.kind when 'expense' then 'expense_unclassified' when 'supplier_payment' then 'accounts_payable' when 'exchange' then 'fx_clearing' else 'cash' end end,
 case when b.direction='withdrawal' then 'bank' else case c.kind when 'sale' then 'sales_revenue' when 'funding' then 'funding_unclassified' when 'debt_payment' then 'accounts_receivable' when 'repair_receipt' then 'repair_revenue' when 'mixed_receipt' then 'fx_clearing' when 'supplier_refund' then 'accounts_payable' else 'cash' end end,c.amount_minor::numeric
 from cash c left join tenant_private.bank_transfers b on b.store_id=c.store_id and b.cash_id=c.id where c.kind in ('sale','funding','expense','exchange','debt_payment','supplier_payment','repair_receipt','mixed_receipt','supplier_refund')
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
 union all select a.created_at,'accounting_adjustment',a.id,a.currency,case when adv.id is not null then 'employee_advances' when p.id is not null or dis.id is not null then 'payroll_payable' else a.debit_account end,a.credit_account,a.amount_minor from public.mt_accounting_adjustments a left join tenant_private.branch_vouchers v on v.store_id=a.store_id and v.adjustment_id=a.id left join tenant_private.staff_payroll p on p.store_id=v.store_id and p.payment_request=v.request_id left join tenant_private.staff_payroll_disbursements dis on dis.store_id=v.store_id and dis.id=v.request_id left join tenant_private.staff_advances adv on adv.store_id=v.store_id and adv.id=v.request_id where a.store_id=p_store and a.created_at<p_until
 union all select a.created_at,'payroll_adjustment',a.id,p.currency,case when a.kind='bonus' then 'payroll_expense' else 'payroll_payable' end,case when a.kind='bonus' then 'payroll_payable' else 'payroll_expense' end,a.amount_minor from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id where a.store_id=p_store and a.created_at<p_until
 union all select o.created_at,'payroll_advance_offset',o.id,p.currency,'payroll_payable','employee_advances',o.amount_minor from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id where o.store_id=p_store and o.created_at<p_until
 union all select created_at,'payroll_accrual',id,currency,'payroll_expense','payroll_payable',total_minor from tenant_private.staff_payroll where store_id=p_store and created_at<p_until
 union all select created_at,'indirect_tax',id,currency,case kind when 'sale' then 'sales_revenue' when 'repair' then 'repair_revenue' else 'indirect_tax_payable' end,case when kind in ('sale','repair') then 'indirect_tax_payable' else 'sales_returns' end,tax_minor from public.mt_indirect_tax_entries where store_id=p_store and created_at<p_until
)
select * from pairs where pairs.amount>0;
$$;

create or replace function tenant_private.branch_operating_result(p_store uuid,p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
 union all select v.branch_id,m.currency,0,0,m.amount_minor,0 from tenant_private.branch_vouchers v join public.mt_cash_movements m on m.store_id=v.store_id and m.id=v.cash_id where v.store_id=p_store and v.branch_id is not null and v.kind<>'receipt' and not exists(select 1 from tenant_private.staff_advances a where a.store_id=v.store_id and a.id=v.request_id) and not exists(select 1 from tenant_private.staff_payroll p where p.store_id=v.store_id and p.payment_request=v.request_id) and not exists(select 1 from tenant_private.staff_payroll_disbursements d where d.store_id=v.store_id and d.id=v.request_id) and m.created_at>=lo and m.created_at<hi
 union all select branch_id,currency,0,0,total_minor,0 from tenant_private.staff_payroll where store_id=p_store and branch_id is not null and created_at>=lo and created_at<hi
 union all select p.branch_id,p.currency,0,0,case when a.kind='bonus' then a.amount_minor else -a.amount_minor end,0 from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id where a.store_id=p_store and p.branch_id is not null and a.created_at>=lo and a.created_at<hi
 ), grouped as (select branch_id,currency,sum(revenue) as revenue,sum(cost) as cost,sum(expense) as expense,sum(unknown)::bigint as unknown from events group by branch_id,currency)
 select coalesce(jsonb_agg(jsonb_build_object('branch',g.branch_id,'name',b.name,'currency',g.currency,'revenue',trunc(g.revenue)::text,'cost',case when g.unknown=0 then trunc(g.cost)::text end,'expenses',trunc(g.expense)::text,'result',case when g.unknown=0 then trunc(g.revenue-g.cost-g.expense)::text end,'unknown',g.unknown) order by b.name,g.currency),'[]') into r from grouped g join tenant_private.branches b on b.store_id=p_store and b.id=g.branch_id;
 return r;
end $$;

create or replace function tenant_private.payroll_details(p_store uuid,p_user uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r text:=tenant_private.member_role(p_store);u uuid:=coalesce(p_user,auth.uid());begin
 if auth.uid() is null or r is null or (r<>'owner' and u is distinct from auth.uid()) then raise exception 'Access denied' using errcode='42501';end if;
 return jsonb_build_object(
 'advances',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,id desc) from (select id,currency,branch_id,amount_minor,tenant_private.advance_remaining(store_id,id) remaining_minor,reference,created_at from tenant_private.staff_advances where store_id=p_store and user_id=u order by created_at desc,id desc limit 100)x),'[]'),
 'statements',coalesce((select jsonb_agg(to_jsonb(x) order by period desc) from (
 select p.id,p.period,p.currency,p.total_minor,p.paid_at,
 coalesce((select sum(amount_minor) from tenant_private.staff_payroll_adjustments a where a.store_id=p.store_id and a.payroll_id=p.id and a.kind='bonus'),0) bonus_minor,
 coalesce((select sum(amount_minor) from tenant_private.staff_payroll_adjustments a where a.store_id=p.store_id and a.payroll_id=p.id and a.kind='deduction'),0) deduction_minor,
 coalesce((select sum(amount_minor) from tenant_private.staff_advance_offsets o where o.store_id=p.store_id and o.payroll_id=p.id),0) advance_minor,
 tenant_private.payroll_due(p.store_id,p.id)+coalesce((select sum(d.amount_minor) from tenant_private.staff_payroll_disbursements d where d.store_id=p.store_id and d.payroll_id=p.id),0) net_minor,
 coalesce((select sum(d.amount_minor) from tenant_private.staff_payroll_disbursements d where d.store_id=p.store_id and d.payroll_id=p.id),0)+case when p.paid_at is not null then tenant_private.payroll_due(p.store_id,p.id) else 0 end paid_minor,
 case when p.paid_at is not null then 0 else tenant_private.payroll_due(p.store_id,p.id) end remaining_minor
 from tenant_private.staff_payroll p where store_id=p_store and user_id=u order by period desc limit 36)x),'[]'),
 'adjustments',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,id desc) from (select a.id,a.payroll_id,p.currency,a.kind,a.amount_minor,a.reason,a.reverses,a.created_at,
 exists(select 1 from tenant_private.staff_payroll_adjustments rev where rev.store_id=a.store_id and rev.reverses=a.id) reversed
 from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id where a.store_id=p_store and p.user_id=u order by a.created_at desc,a.id desc limit 100)x),'[]'),
 'payments',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,id desc) from (select d.id,d.payroll_id,p.currency,d.amount_minor,d.created_at from tenant_private.staff_payroll_disbursements d join tenant_private.staff_payroll p on p.store_id=d.store_id and p.id=d.payroll_id where d.store_id=p_store and p.user_id=u order by d.created_at desc,d.id desc limit 100)x),'[]'));
end $$;
create function public.mt_payroll_partial(p_store uuid,p_id uuid,p_request uuid,p_amount bigint,p_confirm boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.payroll_partial(p_store,p_id,p_request,p_amount,p_confirm)$$;
create function public.mt_payroll_adjust_reverse(p_store uuid,p_id uuid,p_original uuid,p_reason text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.payroll_adjust_reverse(p_store,p_id,p_original,p_reason)$$;
revoke all on function tenant_private.payroll_partial(uuid,uuid,uuid,bigint,boolean),tenant_private.payroll_adjust_reverse(uuid,uuid,uuid,text),public.mt_payroll_partial(uuid,uuid,uuid,bigint,boolean),public.mt_payroll_adjust_reverse(uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.payroll_partial(uuid,uuid,uuid,bigint,boolean),tenant_private.payroll_adjust_reverse(uuid,uuid,uuid,text),public.mt_payroll_partial(uuid,uuid,uuid,bigint,boolean),public.mt_payroll_adjust_reverse(uuid,uuid,uuid,text) to authenticated;
commit;
