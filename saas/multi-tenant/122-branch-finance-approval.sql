begin;
create table tenant_private.opening_debt_equity(
 store_id uuid not null,debt_id uuid not null,request_id uuid not null,branch_id uuid,direction text not null check(direction in ('receivable','payable')),currency text not null,amount_minor bigint not null check(amount_minor>0),reference text not null,actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,debt_id),unique(store_id,request_id),foreign key(store_id,debt_id) references tenant_private.standalone_debts(store_id,id));
create table tenant_private.branch_opening_anchors(
 store_id uuid not null,request_id uuid not null,opening_day date not null,reference text not null,actor uuid not null,opening_rows jsonb not null,created_at timestamptz not null default now(),primary key(store_id,request_id),unique(store_id,opening_day),foreign key(store_id,request_id) references tenant_private.branch_opening_checks(store_id,request_id));
create table tenant_private.branch_result_approvals(
 store_id uuid not null,request_id uuid not null,from_day date not null,to_day date not null,previous uuid,reference text not null,actor uuid not null,snapshot jsonb not null,created_at timestamptz not null default now(),primary key(store_id,request_id),foreign key(store_id,previous) references tenant_private.branch_result_approvals(store_id,request_id),check(to_day>=from_day));
alter table tenant_private.opening_debt_equity enable row level security;
alter table tenant_private.branch_opening_anchors enable row level security;
alter table tenant_private.branch_result_approvals enable row level security;
revoke all on tenant_private.opening_debt_equity,tenant_private.branch_opening_anchors,tenant_private.branch_result_approvals from public,anon,authenticated;
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
 union all select created_at,'opening_debt_equity',request_id,currency,case when direction='receivable' then 'funding_unclassified' else 'capital' end,case when direction='receivable' then 'capital' else 'funding_unclassified' end,amount_minor from tenant_private.opening_debt_equity where store_id=p_store and created_at<p_until
)
select * from pairs where pairs.amount>0;
$function$
;
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
  select 'stock_adjustment',e.request_id,c.branch_id from public.mt_stock_events e left join tenant_private.stock_count_lines c on c.store_id=e.store_id and c.event_id=e.request_id where e.store_id=p_store
  union all select 'standalone_intake',i.request_id,c.branch_id from tenant_private.cost_intakes i left join tenant_private.stock_count_lines c on c.store_id=i.store_id and c.event_id=i.request_id where i.store_id=p_store
  union all select 'opening_debt_equity',request_id,branch_id from tenant_private.opening_debt_equity where store_id=p_store
  union all
  select k,c.id,c.branch_id from cash_loc c cross join unnest(array['cash','exchange_target']) k
  union all select k,s.id,s.branch_id from sale_loc s cross join unnest(array['credit_sale','mixed_sale']) k
  union all select k,r.id,r.branch_id from return_loc r cross join unnest(array['sale_return_debt','sale_return_cash','return_cost_source','return_cost_conversion']) k
  union all select 'repair_refund',id,branch_id from repair_refund_loc
  union all select 'purchase',id,branch_id from purchase_loc
  union all select 'supplier_return',id,branch_id from supplier_return_loc
  union all select k,c.id,c.branch_id from cost_loc c cross join unnest(array['cost_source','cost_conversion']) k
  union all select 'accounting_adjustment',a.id,coalesce(v.branch_id,c.branch_id,sc.branch_id) from public.mt_accounting_adjustments a left join tenant_private.branch_vouchers v on v.store_id=a.store_id and v.adjustment_id=a.id left join cash_loc c on c.request_id=a.source_request left join tenant_private.stock_count_lines sc on sc.store_id=a.store_id and sc.event_id=a.source_request where a.store_id=p_store
  union all select 'standalone_debt_opening',id,branch_id from tenant_private.standalone_debts where store_id=p_store
  union all select 'payroll_accrual',id,branch_id from tenant_private.staff_payroll where store_id=p_store
  union all select 'payroll_adjustment',a.id,p.branch_id from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id where a.store_id=p_store
  union all select 'payroll_advance_offset',o.id,case when p.branch_id is not distinct from a.branch_id then p.branch_id end from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id join tenant_private.staff_advances a on a.store_id=o.store_id and a.id=o.advance_id where o.store_id=p_store
  union all select 'payroll_offset_reversal',r.id,case when a.branch_id is not distinct from p.branch_id then a.branch_id end from tenant_private.staff_payroll_reversals r join tenant_private.staff_payroll p on p.store_id=r.store_id and p.id=r.payroll_id join tenant_private.staff_advances a on a.store_id=r.store_id and a.id=r.advance_id where r.store_id=p_store and r.kind='offset'
  union all select 'tradein_offset',t.id,case when s.branch_id is not distinct from p.branch_id then s.branch_id end from tenant_private.tradein_settlements t join sale_loc s on s.id=t.sale_id join purchase_loc p on p.id=t.purchase_id where t.store_id=p_store
  union all select 'indirect_tax',t.id,coalesce(s.branch_id,i.branch_id) from public.mt_indirect_tax_entries t left join sale_loc s on t.kind in ('sale','sale_return') and s.id=t.invoice_id left join repair_loc i on t.kind in ('repair','repair_refund') and i.id=t.invoice_id where t.store_id=p_store
 ), unique_sources as (
  select kind,id,case when count(distinct coalesce(branch_id::text,''))=1 then min(branch_id::text)::uuid end branch_id,count(distinct coalesce(branch_id::text,''))=1 mapped from sources group by kind,id
 ), offset_locations as (
  select 'payroll_advance_offset'::text kind,o.id,p.branch_id debit_branch,a.branch_id credit_branch
  from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id join tenant_private.staff_advances a on a.store_id=o.store_id and a.id=o.advance_id where o.store_id=p_store
  union all select 'payroll_offset_reversal',r.id,a.branch_id,p.branch_id from tenant_private.staff_payroll_reversals r join tenant_private.staff_payroll p on p.store_id=r.store_id and p.id=r.payroll_id join tenant_private.staff_advances a on a.store_id=r.store_id and a.id=r.advance_id where r.store_id=p_store and r.kind='offset'
  union all select 'tradein_offset',t.id,p.branch_id,s.branch_id from tenant_private.tradein_settlements t join sale_loc s on s.id=t.sale_id join purchase_loc p on p.id=t.purchase_id where t.store_id=p_store
 ), journal as (
  select j.*,s.branch_id,coalesce(s.mapped,false) mapped,o.id is not null and o.debit_branch is distinct from o.credit_branch as split,o.debit_branch,o.credit_branch
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
  'unmapped_pair_count',(select count(*) from journal where not split and not mapped),
  'unknown_transfer_units',coalesce((select sum(m.units) from tenant_private.branch_fifo_moves m join tenant_private.branch_transfers t on t.store_id=m.store_id and t.request_id=m.request_id join tenant_private.stock_layers l on l.store_id=m.store_id and l.product_id=m.product_id and l.id=m.layer_id where m.store_id=p_store and t.created_at<hi and (l.currency is null or l.unit_cost_minor is null)),0)::text,
  'opening_verified',false,
  'rows',coalesce((select jsonb_agg(to_jsonb(r) order by r.name,r.currency,r.account) from rows r),'[]'::jsonb)) into result;
 return result;
end $function$
;
create function tenant_private.opening_debt_classify(s uuid,req uuid,debt uuid,proof text) returns uuid language plpgsql security definer set search_path='' as $$
declare d tenant_private.standalone_debts%rowtype;e tenant_private.opening_debt_equity%rowtype;
begin
 perform tenant_private.owner_write(s);
 if req is null or debt is null or proof is null or length(btrim(proof)) not between 1 and 160 then raise exception 'Opening debt evidence required';end if;
 select * into e from tenant_private.opening_debt_equity where store_id=s and request_id=req;
 if found then if e.debt_id<>debt or e.reference<>btrim(proof) or e.actor<>auth.uid() then raise exception 'Conflicting request';end if;return req;end if;
 select * into d from tenant_private.standalone_debts where store_id=s and id=debt;
 if not found or d.principal_minor<=0 then raise exception 'Debt not found';end if;
 insert into tenant_private.opening_debt_equity(store_id,debt_id,request_id,branch_id,direction,currency,amount_minor,reference,actor) values(s,debt,req,d.branch_id,d.direction,d.currency,d.principal_minor,btrim(proof),auth.uid());
 return req;
end $$;
create function tenant_private.opening_rows(j jsonb) returns jsonb language sql immutable set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_array(x->'branch_id',x->>'currency',x->>'account',((x->>'opening')::numeric)::text) order by coalesce(x->>'branch_id',''),x->>'currency',x->>'account'),'[]'::jsonb) from jsonb_array_elements(j->'rows') x where (x->>'opening')::numeric<>0
$$;
create function tenant_private.branch_anchor_record(s uuid,req uuid,proof text,confirmed boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare d date:=(now() at time zone 'Asia/Damascus')::date;j jsonb;e tenant_private.branch_opening_anchors%rowtype;
begin
 perform tenant_private.owner_write(s);
 if req is null or confirmed is distinct from true or proof is null or length(btrim(proof)) not between 1 and 160 then raise exception 'Confirm opening evidence';end if;
 select * into e from tenant_private.branch_opening_anchors where store_id=s and request_id=req;
 if found then if e.reference<>btrim(proof) or e.actor<>auth.uid() then raise exception 'Conflicting request';end if;return req;end if;
 j:=tenant_private.branch_journal_projection(s,d,d);
 if (j->>'unmapped_pair_count')::numeric<>0 or exists(select 1 from jsonb_array_elements(j->'rows') x where (x->>'debit')::numeric<>0 or (x->>'credit')::numeric<>0) then raise exception 'Opening approval requires a reconciled day before journal movements';end if;
 perform tenant_private.branch_opening_confirm(s,req,proof,true);
 insert into tenant_private.branch_opening_anchors(store_id,request_id,opening_day,reference,actor,opening_rows) values(s,req,d,btrim(proof),auth.uid(),tenant_private.opening_rows(j));
 return req;
end $$;
create function tenant_private.branch_result_compute(s uuid,d1 date,d2 date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare j jsonb;t jsonb;a tenant_private.branch_opening_anchors%rowtype;unknowns bigint;unclassified bigint;clearing boolean;matched boolean;reconciled boolean;ready boolean;results jsonb;hi timestamptz;
begin
 j:=tenant_private.branch_journal_projection(s,d1,d2);
 hi:=(d2+1)::timestamp at time zone 'Asia/Damascus';
 select * into a from tenant_private.branch_opening_anchors where store_id=s and opening_day=d1;
 matched:=a.request_id is not null and a.opening_rows=tenant_private.opening_rows(j);
 reconciled:=coalesce((tenant_private.branch_opening_review(s)->>'ready')::boolean,false);
 t:=tenant_private.sy_tax_period_review(s,d1,d2);
 select (select count(*) from tenant_private.cost_postings where store_id=s and created_at<hi and invoice_cost_minor is null)+(select count(*) from tenant_private.return_cost_postings where store_id=s and created_at<hi and invoice_cost_minor is null)+(select count(*) from public.mt_stock_events e where e.store_id=s and e.created_at<hi and e.delta>0 and e.return_id is null and not exists(select 1 from tenant_private.cost_intakes i where i.store_id=s and i.request_id=e.request_id)) into unknowns;
 select count(*) into unclassified from jsonb_array_elements(j->'rows') x where x->>'account' in ('expense_unclassified','funding_unclassified','stock_intake_unclassified') and ((x->>'closing')::numeric<>0 or (x->>'opening')::numeric<>0);
 select not exists(select 1 from jsonb_array_elements(j->'rows') x where x->>'account'='interbranch_clearing' group by x->>'currency' having sum((x->>'closing')::numeric)<>0) into clearing;
 with rows as (select x->>'branch_id' branch_id,x->>'name' name,x->>'currency' currency,x->>'account' account,(x->>'debit')::numeric-(x->>'credit')::numeric movement,(x->>'closing')::numeric closing from jsonb_array_elements(j->'rows') x),
 totals as (select branch_id,name,currency,-coalesce(sum(movement) filter(where account in ('sales_revenue','repair_revenue','sales_returns')),0) revenue,coalesce(sum(movement) filter(where account='cost_of_goods_services'),0) cost,coalesce(sum(movement) filter(where account in ('expense_unclassified','stock_adjustment_expense','rent_expense','payroll_expense','utilities_expense','other_operating_expense')),0) expenses,coalesce(sum(movement) filter(where account='income_tax_expense'),0) income_tax,coalesce(sum(closing) filter(where account='fx_clearing'),0) fx_clearing from rows group by branch_id,name,currency)
 select coalesce(jsonb_agg(jsonb_build_object('branch_id',branch_id,'name',name,'currency',currency,'revenue',revenue::text,'cost',cost::text,'expenses',expenses::text,'income_tax',income_tax::text,'before_tax',(revenue-cost-expenses)::text,'after_recorded_tax',(revenue-cost-expenses-income_tax)::text,'fx_clearing',fx_clearing::text) order by coalesce(branch_id,''),currency),'[]'::jsonb) into results from totals;
 ready:=matched and reconciled and unknowns=0 and unclassified=0 and clearing and (j->>'unmapped_pair_count')::numeric=0 and (j->>'unknown_transfer_units')::numeric=0 and (t->>'output_unclassified')::numeric=0 and (t->>'input_unclassified')::numeric=0 and (t->>'late_output_postings')::numeric=0 and d2<(now() at time zone 'Asia/Damascus')::date;
 return jsonb_build_object('from',d1,'to',d2,'anchor',a.request_id,'opening_matched',matched,'reconciled',reconciled,'unknown_costs',unknowns,'unclassified_accounts',unclassified,'clearing_balanced',clearing,'unmapped_pairs',j->'unmapped_pair_count','unknown_transfer_units',j->'unknown_transfer_units','tax',t,'ready',ready,'statutory_certified',false,'rows',results,'journal',j->'rows');
end $$;
create function tenant_private.branch_result_review(s uuid,d1 date,d2 date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb;e tenant_private.branch_result_approvals%rowtype;
begin r:=tenant_private.branch_result_compute(s,d1,d2);select * into e from tenant_private.branch_result_approvals where store_id=s and from_day=d1 and to_day=d2 order by created_at desc,request_id desc limit 1;return r||jsonb_build_object('approval',e.request_id,'approval_reference',e.reference,'matches_approval',e.request_id is not null and e.snapshot=r);end $$;
create function tenant_private.branch_result_approve(s uuid,req uuid,d1 date,d2 date,previous uuid,proof text,confirmed boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare r jsonb;e tenant_private.branch_result_approvals%rowtype;latest uuid;
begin perform tenant_private.owner_write(s);
 if req is null or proof is null or length(btrim(proof)) not between 1 and 160 or confirmed is distinct from true then raise exception 'Confirm taxes and shared expenses';end if;
 select * into e from tenant_private.branch_result_approvals where store_id=s and request_id=req;
 if found then if e.from_day<>d1 or e.to_day<>d2 or e.reference<>btrim(proof) or e.previous is distinct from previous or e.actor<>auth.uid() then raise exception 'Conflicting request';end if;return req;end if;
 select request_id into latest from tenant_private.branch_result_approvals where store_id=s and from_day=d1 and to_day=d2 order by created_at desc,request_id desc limit 1;
 if latest is distinct from previous then raise exception 'Review latest approval';end if;
 r:=tenant_private.branch_result_compute(s,d1,d2);
 if r->>'ready' is distinct from 'true' then raise exception 'Financial readiness incomplete';end if;
 if octet_length(r::text)>2000000 then raise exception 'Report too large';end if;
 insert into tenant_private.branch_result_approvals(store_id,request_id,from_day,to_day,previous,reference,actor,snapshot) values(s,req,d1,d2,previous,btrim(proof),auth.uid(),r);return req;
end $$;
create function public.mt_opening_debt_classify(s uuid,req uuid,debt uuid,proof text) returns uuid language sql set search_path='' as $$select tenant_private.opening_debt_classify(s,req,debt,proof)$$;
create function public.mt_branch_anchor_record(s uuid,req uuid,proof text,confirmed boolean) returns uuid language sql set search_path='' as $$select tenant_private.branch_anchor_record(s,req,proof,confirmed)$$;
create function public.mt_branch_result_review(s uuid,d1 date,d2 date) returns jsonb language sql stable set search_path='' as $$select tenant_private.branch_result_review(s,d1,d2)$$;
create function public.mt_branch_result_approve(s uuid,req uuid,d1 date,d2 date,previous uuid,proof text,confirmed boolean) returns uuid language sql set search_path='' as $$select tenant_private.branch_result_approve(s,req,d1,d2,previous,proof,confirmed)$$;
revoke all on function tenant_private.opening_debt_classify(uuid,uuid,uuid,text),public.mt_opening_debt_classify(uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function tenant_private.opening_debt_classify(uuid,uuid,uuid,text),public.mt_opening_debt_classify(uuid,uuid,uuid,text) to authenticated;
revoke all on function tenant_private.branch_anchor_record(uuid,uuid,text,boolean),public.mt_branch_anchor_record(uuid,uuid,text,boolean) from public,anon,authenticated;
grant execute on function tenant_private.branch_anchor_record(uuid,uuid,text,boolean),public.mt_branch_anchor_record(uuid,uuid,text,boolean) to authenticated;
revoke all on function tenant_private.branch_result_review(uuid,date,date),public.mt_branch_result_review(uuid,date,date) from public,anon,authenticated;
grant execute on function tenant_private.branch_result_review(uuid,date,date),public.mt_branch_result_review(uuid,date,date) to authenticated;
revoke all on function tenant_private.branch_result_approve(uuid,uuid,date,date,uuid,text,boolean),public.mt_branch_result_approve(uuid,uuid,date,date,uuid,text,boolean) from public,anon,authenticated;
grant execute on function tenant_private.branch_result_approve(uuid,uuid,date,date,uuid,text,boolean),public.mt_branch_result_approve(uuid,uuid,date,date,uuid,text,boolean) to authenticated;
revoke all on function tenant_private.opening_rows(jsonb),tenant_private.branch_result_compute(uuid,date,date) from public,anon,authenticated;
commit;