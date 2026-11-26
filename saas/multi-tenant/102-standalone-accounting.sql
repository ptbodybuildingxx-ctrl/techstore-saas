-- Integrate independent debt balances into the double-entry journal, branch ledgers and exports.
-- Opening balance offset remains explicitly unclassified, not operating income or expenses.
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
 case when sd.direction='receivable' then 'accounts_receivable' when sd.direction='payable' then 'cash' when b.direction='withdrawal' then 'bank' else case c.kind when 'sale' then 'sales_revenue' when 'funding' then 'funding_unclassified' when 'debt_payment' then 'accounts_receivable' when 'repair_receipt' then 'repair_revenue' when 'mixed_receipt' then 'fx_clearing' when 'supplier_refund' then 'accounts_payable' else 'cash' end end,c.amount_minor::numeric
 from cash c left join tenant_private.bank_transfers b on b.store_id=c.store_id and b.cash_id=c.id left join tenant_private.standalone_debt_payments sdp on sdp.store_id=c.store_id and sdp.cash_id=c.id left join tenant_private.standalone_debts sd on sd.store_id=sdp.store_id and sd.id=sdp.debt_id where c.kind in ('sale','funding','expense','exchange','debt_payment','supplier_payment','repair_receipt','mixed_receipt','supplier_refund')
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
 union all select a.created_at,'accounting_adjustment',a.id,a.currency,case when adv.id is not null then 'employee_advances' when p.id is not null or dis.id is not null then 'payroll_payable' else a.debit_account end,a.credit_account,a.amount_minor from public.mt_accounting_adjustments a left join tenant_private.branch_vouchers v on v.store_id=a.store_id and v.adjustment_id=a.id left join tenant_private.staff_payroll p on p.store_id=v.store_id and p.payment_request=v.request_id left join tenant_private.staff_payroll_disbursements dis on dis.store_id=v.store_id and dis.id=v.request_id left join tenant_private.staff_advances adv on adv.store_id=v.store_id and adv.id=v.request_id where a.store_id=p_store and a.created_at<p_until
 union all select a.created_at,'payroll_adjustment',a.id,p.currency,case when a.kind='bonus' then 'payroll_expense' else 'payroll_payable' end,case when a.kind='bonus' then 'payroll_payable' else 'payroll_expense' end,a.amount_minor from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id where a.store_id=p_store and a.created_at<p_until
 union all select o.created_at,'payroll_advance_offset',o.id,p.currency,'payroll_payable','employee_advances',o.amount_minor from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id where o.store_id=p_store and o.created_at<p_until
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
  union all select 'tradein_offset',t.id,case when s.branch_id is not distinct from p.branch_id then s.branch_id end from tenant_private.tradein_settlements t join sale_loc s on s.id=t.sale_id join purchase_loc p on p.id=t.purchase_id where t.store_id=p_store
  union all select 'indirect_tax',t.id,coalesce(s.branch_id,i.branch_id) from public.mt_indirect_tax_entries t left join sale_loc s on t.kind in ('sale','sale_return') and s.id=t.invoice_id left join repair_loc i on t.kind in ('repair','repair_refund') and i.id=t.invoice_id where t.store_id=p_store
 ), unique_sources as (
  select kind,id,case when count(distinct coalesce(branch_id::text,''))=1 then min(branch_id::text)::uuid end branch_id from sources group by kind,id
 ), offset_locations as (
  select 'payroll_advance_offset'::text kind,o.id,p.branch_id debit_branch,a.branch_id credit_branch
  from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id join tenant_private.staff_advances a on a.store_id=o.store_id and a.id=o.advance_id where o.store_id=p_store
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

CREATE OR REPLACE FUNCTION tenant_private.financial_reconciliation(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rows jsonb;stock_mismatches bigint;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 with j as (
 select currency,account,sum(amount) balance from (
 select currency,debit_account account,amount from tenant_private.journal_pairs(p_store,'infinity'::timestamptz)
 union all select currency,credit_account,-amount from tenant_private.journal_pairs(p_store,'infinity'::timestamptz)) q group by currency,account
 ), source as (
 select currency,'cash' account,balance_minor::numeric amount from tenant_private.cash_balances where store_id=p_store
 union all select currency,'bank',balance_minor::numeric from tenant_private.bank_accounts where store_id=p_store
 union all select currency,'payroll_payable',-tenant_private.payroll_due(store_id,id)::numeric from tenant_private.staff_payroll where store_id=p_store and paid_at is null
 union all select currency,'employee_advances',tenant_private.advance_remaining(store_id,id)::numeric from tenant_private.staff_advances where store_id=p_store
 union all select currency,'inventory',remaining_units::numeric*unit_cost_minor from tenant_private.stock_layers where store_id=p_store
 union all select currency,'accounts_receivable',remaining_minor::numeric from public.mt_debts where store_id=p_store
 union all select currency,case when direction='receivable' then 'accounts_receivable' else 'accounts_payable' end,case when direction='receivable' then remaining_minor::numeric else -remaining_minor::numeric end from tenant_private.standalone_debts where store_id=p_store
 union all select currency,'accounts_payable',-(total_minor::numeric-returned_units::numeric*unit_cost_minor-paid_minor+refunded_minor) from public.mt_purchases where store_id=p_store
 union all select currency,'income_tax_payable',case when kind='income_tax_accrual' then -amount_minor::numeric else amount_minor::numeric end from public.mt_accounting_adjustments where store_id=p_store and kind in ('income_tax_accrual','income_tax_reverse','expense_tax_payment')
 union all select currency,'indirect_tax_payable',case when kind in ('sale','repair') then -tax_minor::numeric else tax_minor::numeric end from public.mt_indirect_tax_entries where store_id=p_store
 union all select currency,'indirect_tax_payable',amount_minor::numeric from public.mt_accounting_adjustments where store_id=p_store and kind='expense_indirect_tax_payment'
 ), s as (select currency,account,sum(amount) balance from source group by currency,account),
 vals as (select c.currency,a.account,coalesce(j.balance,0) journal,coalesce(s.balance,0) recorded from tenant_private.sale_currencies c cross join unnest(array['cash','employee_advances','bank','inventory','accounts_receivable','accounts_payable','payroll_payable','income_tax_payable','indirect_tax_payable']) a(account) left join j on j.currency=c.currency and j.account=a.account left join s on s.currency=c.currency and s.account=a.account where c.store_id=p_store)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'account',account,'journal',journal::text,'recorded',recorded::text,'difference',(recorded-journal)::text,'balanced',recorded=journal) order by currency,account),'[]'::jsonb) into rows from vals;
 select count(*) into stock_mismatches from public.mt_products p where p.store_id=p_store and p.quantity<>(select coalesce(sum(l.remaining_units),0) from tenant_private.stock_layers l where l.store_id=p.store_id and l.product_id=p.id);
 return jsonb_build_object('mode','current_subledger_reconciliation','rows',rows,'stock_quantity_mismatches',stock_mismatches,'balanced',stock_mismatches=0 and not exists(select 1 from jsonb_array_elements(rows) x where x->>'balanced'='false'));
end; $function$;

CREATE OR REPLACE FUNCTION tenant_private.branch_account_balances(p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return (with locations as (
 select null::uuid branch_id,'المستودع الرئيسي'::text name union all select id,name from tenant_private.branches where store_id=p_store
 ), entries as (
 select b.branch_id,d.currency,'receivable'::text account,d.remaining_minor::numeric amount from public.mt_debts d left join tenant_private.branch_sales b on b.store_id=d.store_id and b.sale_id=d.sale_id where d.store_id=p_store
 union all select branch_id,currency,direction,remaining_minor::numeric from tenant_private.standalone_debts where store_id=p_store
 union all select b.branch_id,p.currency,'payable',p.total_minor::numeric-p.returned_units::numeric*p.unit_cost_minor-p.paid_minor+p.refunded_minor from public.mt_purchases p left join tenant_private.branch_purchases b on b.store_id=p.store_id and b.purchase_id=p.id where p.store_id=p_store
 union all select branch_id,currency,'payroll',tenant_private.payroll_due(store_id,id)::numeric from tenant_private.staff_payroll where store_id=p_store and paid_at is null
 union all select branch_id,currency,'advance',tenant_private.advance_remaining(store_id,id)::numeric from tenant_private.staff_advances where store_id=p_store
 ), totals as (select branch_id,currency,sum(amount) filter(where account='receivable') receivable,sum(amount) filter(where account='payable') payable,sum(amount) filter(where account='payroll') payroll,sum(amount) filter(where account='advance') advances from entries group by branch_id,currency),
 units as (select branch_id,sum(units)::numeric units from tenant_private.branch_stock where store_id=p_store group by branch_id union all select null::uuid,coalesce(sum(p.quantity-tenant_private.branch_allocated(p.store_id,p.id)),0)::numeric from public.mt_products p where store_id=p_store),
 bank as (select branch_id,currency,sum(balance_minor)::numeric amount from tenant_private.bank_accounts where store_id=p_store group by branch_id,currency),
 valuation as (select a.branch_id,k.currency,sum(a.units::numeric*k.unit_cost_minor) amount from tenant_private.branch_fifo_lots a join tenant_private.stock_layers k on k.store_id=a.store_id and k.product_id=a.product_id and k.id=a.layer_id where a.store_id=p_store and a.units>0 and k.currency is not null group by a.branch_id,k.currency),
 unknown as (select a.branch_id,sum(a.units)::numeric units from tenant_private.branch_fifo_lots a join tenant_private.stock_layers k on k.store_id=a.store_id and k.product_id=a.product_id and k.id=a.layer_id where a.store_id=p_store and a.units>0 and k.currency is null group by a.branch_id),
 rows as (select l.branch_id,l.name,c.currency,case when exists(select 1 from tenant_private.branch_treasury_enabled where store_id=p_store) then coalesce(a.balance_minor,0)::text else null end cash,coalesce(bk.amount,0)::text bank,case when exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store) then coalesce(v.amount,0)::text else null end known_stock_cost,case when exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store) then coalesce(un.units,0)::text else null end unknown_cost_units,coalesce(t.receivable,0)::text receivable,coalesce(t.payable,0)::text payable,coalesce(t.payroll,0)::text payroll,coalesce(t.advances,0)::text advances,coalesce(u.units,0)::text stock_units from locations l cross join tenant_private.sale_currencies c left join totals t on t.branch_id is not distinct from l.branch_id and t.currency=c.currency left join tenant_private.branch_cash_accounts a on a.store_id=p_store and a.branch_id is not distinct from l.branch_id and a.currency=c.currency left join units u on u.branch_id is not distinct from l.branch_id left join bank bk on bk.branch_id is not distinct from l.branch_id and bk.currency=c.currency left join valuation v on v.branch_id is not distinct from l.branch_id and v.currency=c.currency left join unknown un on un.branch_id is not distinct from l.branch_id where c.store_id=p_store)
 select jsonb_build_object('mode','attributed_subledgers','stock_valuation_available',exists(select 1 from tenant_private.branch_fifo_enabled where store_id=p_store),'rows',coalesce(jsonb_agg(to_jsonb(r) order by r.name,r.currency),'[]'::jsonb)) from rows r);
end $function$;

CREATE OR REPLACE FUNCTION tenant_private.cash_report(p_store uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 then raise exception 'Invalid date range' using errcode='22023';end if;
 with movements as (select m.*,b.direction,sd.direction standalone_direction from public.mt_cash_movements m left join tenant_private.bank_transfers b on b.store_id=m.store_id and b.cash_id=m.id left join tenant_private.standalone_debt_payments sdp on sdp.store_id=m.store_id and sdp.cash_id=m.id left join tenant_private.standalone_debts sd on sd.store_id=sdp.store_id and sd.id=sdp.debt_id where m.store_id=p_store and m.created_at>=p_from::timestamp at time zone 'UTC' and m.created_at<(p_to+1)::timestamp at time zone 'UTC'),
 flows as (select currency,case when standalone_direction='receivable' then 'standalone_receipt' when standalone_direction='payable' then 'standalone_payment' when direction='deposit' then 'bank_deposit' when direction='withdrawal' then 'bank_withdrawal' else kind end as kind,case when kind in ('sale','funding','debt_payment','repair_receipt','mixed_receipt','supplier_refund') then amount_minor else -amount_minor end as value from movements union all select target_currency,'exchange_in',target_amount_minor from movements where kind='exchange'),
 totals as (select currency,sum(value) filter(where value>0) as incoming,sum(-value) filter(where value<0) as outgoing,sum(value) as net,sum(value) filter(where kind in ('sale','debt_payment','repair_receipt','mixed_receipt','standalone_receipt')) as collections,sum(-value) filter(where kind in ('return_refund','repair_refund')) as refunds,sum(-value) filter(where kind='supplier_payment') as supplier_payments,sum(value) filter(where kind='supplier_refund') as supplier_refunds,sum(-value) filter(where kind='expense') as expenses from flows group by currency)
 select coalesce(jsonb_agg(jsonb_build_object('currency',c.currency,'incoming',coalesce(t.incoming,0)::text,'outgoing',coalesce(t.outgoing,0)::text,'net',coalesce(t.net,0)::text,'collections',coalesce(t.collections,0)::text,'refunds',coalesce(t.refunds,0)::text,'supplier_payments',coalesce(t.supplier_payments,0)::text,'supplier_refunds',coalesce(t.supplier_refunds,0)::text,'expenses',coalesce(t.expenses,0)::text) order by c.currency),'[]'::jsonb) into r
 from tenant_private.sale_currencies c left join totals t on t.currency=c.currency where c.store_id=p_store;
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
 foreach t in array array['public.mt_products','public.mt_product_prices','public.mt_stock_events','public.mt_sales','public.mt_sale_lines','public.mt_cash_movements','public.mt_customers','public.mt_debts','public.mt_installments','public.mt_debt_payments','public.mt_returns','public.mt_suppliers','public.mt_purchases','public.mt_supplier_payments','public.mt_repairs','public.mt_repair_events','public.mt_repair_invoices','public.mt_online_orders','public.mt_accounting_adjustments','public.mt_indirect_tax_entries','tenant_private.branch_stock','tenant_private.branches','tenant_private.branch_transfers','tenant_private.branch_sales','tenant_private.branch_vouchers','tenant_private.staff_shifts','tenant_private.staff_terms','tenant_private.staff_payroll','tenant_private.bank_accounts','tenant_private.bank_transfers','tenant_private.receipt_snapshots','tenant_private.receipt_settings','tenant_private.tradein_settlements','tenant_private.guest_orders','tenant_private.buyer_price_terms','tenant_private.stock_counts','tenant_private.stock_count_lines','tenant_private.stock_count_cancellations','tenant_private.procurement_grants','tenant_private.procurement_requests','tenant_private.sale_invoice_details','tenant_private.sale_warranty_claims','tenant_private.sale_warranty_events','tenant_private.pos_loyalty_sales','tenant_private.customer_profile_edits','tenant_private.standalone_debts','tenant_private.standalone_installments','tenant_private.standalone_debt_payments','tenant_private.standalone_payment_allocations'] loop
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

CREATE OR REPLACE FUNCTION tenant_private.branch_cash_post()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m public.mt_cash_movements%rowtype;b uuid;sid uuid;pid uuid;rid uuid;delta bigint;begin
 select * into strict m from public.mt_cash_movements where store_id=new.store_id and id=new.cash_id;
 perform 1 from public.saas_stores where id=m.store_id for update;
 if exists(select 1 from tenant_private.branch_cash_attribution where store_id=m.store_id and cash_id=m.id and posted) then return new;end if;
 sid:=coalesce(m.sale_id,m.mixed_sale_id);
 if m.debt_payment_id is not null then select d.sale_id into sid from public.mt_debt_payments p join public.mt_debts d on d.store_id=p.store_id and d.id=p.debt_id where p.store_id=m.store_id and p.id=m.debt_payment_id;end if;
 if m.return_id is not null then select sale_id into sid from public.mt_returns where store_id=m.store_id and id=m.return_id;end if;
 if m.supplier_payment_id is not null then select purchase_id into pid from public.mt_supplier_payments where store_id=m.store_id and id=m.supplier_payment_id;end if;
 if m.supplier_return_id is not null then select purchase_id into pid from public.mt_supplier_returns where store_id=m.store_id and id=m.supplier_return_id;end if;
 if m.repair_invoice_id is not null then select repair_id into rid from public.mt_repair_invoices where store_id=m.store_id and id=m.repair_invoice_id;end if;
 if m.repair_refund_id is not null then select i.repair_id into rid from public.mt_repair_refunds r join public.mt_repair_invoices i on i.store_id=r.store_id and i.id=r.invoice_id where r.store_id=m.store_id and r.id=m.repair_refund_id;end if;
 if sid is not null then select branch_id into b from tenant_private.branch_sales where store_id=m.store_id and sale_id=sid;
 elsif pid is not null then select branch_id into b from tenant_private.branch_purchases where store_id=m.store_id and purchase_id=pid;
 elsif rid is not null then select branch_id into b from tenant_private.branch_repairs where store_id=m.store_id and repair_id=rid;
 elsif exists(select 1 from tenant_private.bank_transfers where store_id=m.store_id and cash_id=m.id) then select a.branch_id into b from tenant_private.bank_transfers t join tenant_private.bank_accounts a on a.store_id=t.store_id and a.id=t.account_id where t.store_id=m.store_id and t.cash_id=m.id;
 elsif exists(select 1 from tenant_private.standalone_debt_payments where store_id=m.store_id and cash_id=m.id) then select d.branch_id into b from tenant_private.standalone_debt_payments p join tenant_private.standalone_debts d on d.store_id=p.store_id and d.id=p.debt_id where p.store_id=m.store_id and p.cash_id=m.id;
 else select branch_id into b from tenant_private.branch_vouchers where store_id=m.store_id and cash_id=m.id;end if;
 delta:=case when m.kind in ('sale','funding','debt_payment','repair_receipt','mixed_receipt','supplier_refund') then m.amount_minor when m.kind in ('expense','exchange','return','return_refund','supplier_payment','repair_refund') then -m.amount_minor else null end;
 -- Fail closed on new cash types; known sale returns may be called refund.
 if m.kind='refund' then delta:=-m.amount_minor;end if;
 if delta is null then raise exception 'Unknown cash type for branch treasury';end if;
 perform tenant_private.branch_cash_apply(m.store_id,b,m.currency,delta);
 if m.kind='exchange' then perform tenant_private.branch_cash_apply(m.store_id,b,m.target_currency,m.target_amount_minor);end if;
 update tenant_private.branch_cash_attribution set branch_id=b,posted=true where store_id=m.store_id and cash_id=m.id;return new;
end $function$;

create function tenant_private.guard_standalone_classification() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from tenant_private.standalone_debt_payments where store_id=new.store_id and id=new.source_request) then raise exception 'Standalone settlement is already classified' using errcode='22023';end if;
 return new;
end $$;
revoke all on function tenant_private.guard_standalone_classification() from public,anon,authenticated,service_role;
create trigger standalone_classification_guard before insert on public.mt_accounting_adjustments for each row execute function tenant_private.guard_standalone_classification();

create function public.mt_standalone_open(p_store uuid,p_request uuid,p_customer uuid,p_branch uuid,p_direction text,p_party text,p_phone text,p_currency text,p_amount bigint,p_count integer,p_due date,p_notes text)
returns uuid language sql set search_path='' as $$select tenant_private.standalone_open(p_store,p_request,p_customer,p_branch,p_direction,p_party,p_phone,p_currency,p_amount,p_count,p_due,p_notes)$$;
create function public.mt_standalone_pay(p_store uuid,p_request uuid,p_debt uuid,p_amount bigint,p_memo text)
returns uuid language sql set search_path='' as $$select tenant_private.standalone_pay(p_store,p_request,p_debt,p_amount,p_memo)$$;
create function public.mt_standalone_list(p_store uuid,p_query text,p_customer uuid,p_direction text,p_offset integer)
returns jsonb language sql stable set search_path='' as $$select tenant_private.standalone_list(p_store,p_query,p_customer,p_direction,p_offset)$$;
create function public.mt_standalone_details(p_store uuid,p_debt uuid,p_offset integer)
returns jsonb language sql stable set search_path='' as $$select tenant_private.standalone_details(p_store,p_debt,p_offset)$$;
revoke all on function public.mt_standalone_open(uuid,uuid,uuid,uuid,text,text,text,text,bigint,integer,date,text),public.mt_standalone_pay(uuid,uuid,uuid,bigint,text),public.mt_standalone_list(uuid,text,uuid,text,integer),public.mt_standalone_details(uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.standalone_open(uuid,uuid,uuid,uuid,text,text,text,text,bigint,integer,date,text),tenant_private.standalone_pay(uuid,uuid,uuid,bigint,text),tenant_private.standalone_list(uuid,text,uuid,text,integer),tenant_private.standalone_details(uuid,uuid,integer),public.mt_standalone_open(uuid,uuid,uuid,uuid,text,text,text,text,bigint,integer,date,text),public.mt_standalone_pay(uuid,uuid,uuid,bigint,text),public.mt_standalone_list(uuid,text,uuid,text,integer),public.mt_standalone_details(uuid,uuid,integer) to authenticated;
