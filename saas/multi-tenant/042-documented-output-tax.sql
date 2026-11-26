begin;
-- Documented, invoice-wide, tax-inclusive output tax; no jurisdiction or rate is assumed.
create table public.mt_indirect_tax_entries(
 store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null default gen_random_uuid(),request_id uuid not null,
 kind text not null check(kind in ('sale','repair','sale_return','repair_refund')),
 source_id uuid not null,invoice_id uuid not null,currency text not null,
 gross_minor bigint not null check(gross_minor between 0 and 100000000000000),
 rate_bps integer not null check(rate_bps between 0 and 10000),
 tax_minor bigint not null check(tax_minor between 0 and gross_minor),
 reference text not null check(length(btrim(reference)) between 1 and 160),note text not null check(length(btrim(note)) between 1 and 300),
 actor uuid not null,created_at timestamptz not null default now(),
 primary key(store_id,id),unique(store_id,request_id),unique(store_id,kind,source_id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency)
);
create index mt_indirect_tax_invoice_idx on public.mt_indirect_tax_entries(store_id,kind,invoice_id);
alter table public.mt_indirect_tax_entries enable row level security;
revoke all on public.mt_indirect_tax_entries from public,anon,authenticated,service_role;
grant select on public.mt_indirect_tax_entries to authenticated;
create policy owner_read on public.mt_indirect_tax_entries for select to authenticated using(tenant_private.member_role(store_id)='owner');
create trigger mt_guard_closed_period before insert on public.mt_indirect_tax_entries for each row execute function tenant_private.guard_closed_period();

create function tenant_private.tax_inclusive_minor(p_gross bigint,p_bps integer) returns bigint language plpgsql immutable set search_path='' as $$
begin
 if p_gross is null or p_gross not between 0 and 100000000000000 or p_bps is null or p_bps not between 0 and 10000 then raise exception 'Invalid tax basis' using errcode='22023';end if;
 return round(p_gross::numeric*p_bps/(10000+p_bps))::bigint;
end; $$;

create function tenant_private.indirect_tax_quote(p_store uuid,p_kind text,p_source uuid,p_rate integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare gross bigint;c text;invoice uuid;original public.mt_indirect_tax_entries%rowtype;prev_gross numeric;prev_tax numeric;tax bigint;original_kind text;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_source is null or p_kind is null or p_kind not in ('sale','repair','sale_return','repair_refund') then raise exception 'Invalid tax source' using errcode='22023';end if;
 if exists(select 1 from public.mt_indirect_tax_entries where store_id=p_store and kind=p_kind and source_id=p_source) then raise exception 'Tax source already classified' using errcode='22023';end if;
 case p_kind
 when 'sale' then select total_minor,currency,id into gross,c,invoice from public.mt_sales where store_id=p_store and id=p_source;
 when 'repair' then select total_minor,currency,id into gross,c,invoice from public.mt_repair_invoices where store_id=p_store and id=p_source;
 when 'sale_return' then select total_minor,currency,sale_id into gross,c,invoice from public.mt_returns where store_id=p_store and id=p_source;
 when 'repair_refund' then select amount_minor,currency,invoice_id into gross,c,invoice from public.mt_repair_refunds where store_id=p_store and id=p_source;
 end case;
 if gross is null or c is null or invoice is null then raise exception 'Unknown tax source' using errcode='22023';end if;
 if p_kind in ('sale','repair') then
  tax:=tenant_private.tax_inclusive_minor(gross,p_rate);
 else
  if p_rate is not null then raise exception 'Return uses original tax rate' using errcode='22023';end if;
  original_kind:=case p_kind when 'sale_return' then 'sale' else 'repair' end;
  select * into original from public.mt_indirect_tax_entries where store_id=p_store and kind=original_kind and source_id=invoice;
  if not found or original.currency<>c then raise exception 'Classify original invoice first' using errcode='22023';end if;
  select coalesce(sum(gross_minor),0),coalesce(sum(tax_minor),0) into prev_gross,prev_tax from public.mt_indirect_tax_entries where store_id=p_store and kind=p_kind and invoice_id=invoice;
  if prev_gross+gross>original.gross_minor then raise exception 'Return exceeds original invoice' using errcode='22023';end if;
  p_rate:=original.rate_bps;
  tax:=tenant_private.tax_inclusive_minor((prev_gross+gross)::bigint,p_rate)-prev_tax;
  if tax<0 or tax>gross or prev_tax+tax>original.tax_minor then raise exception 'Tax reversal mismatch' using errcode='22023';end if;
 end if;
 return jsonb_build_object('kind',p_kind,'source_id',p_source,'invoice_id',invoice,'currency',c,'gross_minor',gross,'rate_bps',p_rate,'tax_minor',tax);
end; $$;

create function tenant_private.record_indirect_tax(p_store uuid,p_request uuid,p_kind text,p_source uuid,p_rate integer,p_expected bigint,p_reference text,p_note text) returns uuid language plpgsql security definer set search_path='' as $$
declare entry public.mt_indirect_tax_entries%rowtype;q jsonb;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_kind is null or p_source is null or p_expected is null or p_expected not between 0 and 100000000000000 or p_reference is null or length(btrim(p_reference)) not between 1 and 160 or p_note is null or length(btrim(p_note)) not between 1 and 300 or (p_kind in ('sale_return','repair_refund') and p_rate is not null) then raise exception 'Invalid tax confirmation' using errcode='22023';end if;
 select * into entry from public.mt_indirect_tax_entries where store_id=p_store and request_id=p_request;
 if found then
  if entry.actor<>auth.uid() or entry.kind<>p_kind or entry.source_id<>p_source or entry.tax_minor<>p_expected or (p_kind in ('sale','repair') and entry.rate_bps is distinct from p_rate) or entry.reference<>btrim(p_reference) or entry.note<>btrim(p_note) then raise exception 'Conflicting tax request' using errcode='22023';end if;
  return entry.id;
 end if;
 q:=tenant_private.indirect_tax_quote(p_store,p_kind,p_source,p_rate);
 if (q->>'tax_minor')::bigint<>p_expected then raise exception 'Tax quote changed' using errcode='22023';end if;
 insert into public.mt_indirect_tax_entries(store_id,request_id,kind,source_id,invoice_id,currency,gross_minor,rate_bps,tax_minor,reference,note,actor)
 values(p_store,p_request,p_kind,p_source,(q->>'invoice_id')::uuid,q->>'currency',(q->>'gross_minor')::bigint,(q->>'rate_bps')::integer,p_expected,btrim(p_reference),btrim(p_note),auth.uid()) returning * into entry;
 return entry.id;
end; $$;

create function public.mt_indirect_tax_quote(p_store uuid,p_kind text,p_source uuid,p_rate integer) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.indirect_tax_quote(p_store,p_kind,p_source,p_rate)$$;
create function public.mt_record_indirect_tax(p_store uuid,p_request uuid,p_kind text,p_source uuid,p_rate integer,p_expected bigint,p_reference text,p_note text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.record_indirect_tax(p_store,p_request,p_kind,p_source,p_rate,p_expected,p_reference,p_note)$$;
create function public.mt_list_indirect_tax_entries(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.mt_indirect_tax_entries language plpgsql stable security invoker set search_path='' as $$
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;
 return query select * from public.mt_indirect_tax_entries where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;
end; $$;
revoke all on function tenant_private.tax_inclusive_minor(bigint,integer),tenant_private.indirect_tax_quote(uuid,text,uuid,integer),tenant_private.record_indirect_tax(uuid,uuid,text,uuid,integer,bigint,text,text),public.mt_indirect_tax_quote(uuid,text,uuid,integer),public.mt_record_indirect_tax(uuid,uuid,text,uuid,integer,bigint,text,text),public.mt_list_indirect_tax_entries(uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.indirect_tax_quote(uuid,text,uuid,integer),tenant_private.record_indirect_tax(uuid,uuid,text,uuid,integer,bigint,text,text),public.mt_indirect_tax_quote(uuid,text,uuid,integer),public.mt_record_indirect_tax(uuid,uuid,text,uuid,integer,bigint,text,text),public.mt_list_indirect_tax_entries(uuid,uuid,integer) to authenticated;

alter table public.mt_accounting_adjustments drop constraint mt_accounting_adjustments_kind_check;
alter table public.mt_accounting_adjustments add constraint mt_accounting_adjustments_kind_check check(kind in ('funding_equity','funding_loan','stock_equity','expense_rent','expense_payroll','expense_utilities','expense_other','expense_tax_payment','expense_indirect_tax_payment','expense_loan_payment','expense_capital_withdrawal','income_tax_accrual','income_tax_reverse'));

create or replace function tenant_private.accounting_adjust(p_store uuid,p_request uuid,p_kind text,p_source uuid,p_currency text,p_amount bigint,p_reference text,p_note text) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.mt_accounting_adjustments%rowtype;d text;c text;source_amount bigint;source_currency text;available numeric;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_amount is null or p_amount not between 1 and 100000000000000 or p_reference is null or length(btrim(p_reference)) not between 1 and 160 or p_note is null or length(btrim(p_note)) not between 1 and 300 or p_kind is null or p_kind not in ('funding_equity','funding_loan','stock_equity','expense_rent','expense_payroll','expense_utilities','expense_other','expense_tax_payment','expense_indirect_tax_payment','expense_loan_payment','expense_capital_withdrawal','income_tax_accrual','income_tax_reverse') or ((p_kind in ('income_tax_accrual','income_tax_reverse'))<>(p_source is null)) then raise exception 'Invalid accounting entry' using errcode='22023';end if;
 select * into r from public.mt_accounting_adjustments where store_id=p_store and request_id=p_request;
 if found then
  if r.actor<>auth.uid() or r.kind<>p_kind or r.source_request is distinct from p_source or r.currency<>p_currency or r.amount_minor<>p_amount or r.reference<>btrim(p_reference) or r.note<>btrim(p_note) then raise exception 'Conflicting accounting request' using errcode='22023';end if;return r.id;
 end if;
 if p_source is not null then
  if p_kind='stock_equity' then
   select i.units*i.unit_cost_minor,i.currency into source_amount,source_currency from tenant_private.cost_intakes i where i.store_id=p_store and i.request_id=p_source and not exists(select 1 from public.mt_purchases p where p.store_id=i.store_id and p.intake_request=i.request_id);
  else
   select amount_minor,currency into source_amount,source_currency from public.mt_cash_movements where store_id=p_store and request_id=p_source and kind=case when p_kind in ('funding_equity','funding_loan') then 'funding' else 'expense' end;
  end if;
  if not found or source_currency<>p_currency or p_amount>source_amount-(select coalesce(sum(amount_minor),0) from public.mt_accounting_adjustments where store_id=p_store and source_request=p_source) then raise exception 'Source unavailable or already classified' using errcode='22023';end if;
 end if;
 case p_kind
 when 'funding_equity' then d:='funding_unclassified';c:='capital';
 when 'funding_loan' then d:='funding_unclassified';c:='loan_payable';
 when 'stock_equity' then d:='stock_intake_unclassified';c:='capital';
 when 'expense_rent' then d:='rent_expense';c:='expense_unclassified';
 when 'expense_payroll' then d:='payroll_expense';c:='expense_unclassified';
 when 'expense_utilities' then d:='utilities_expense';c:='expense_unclassified';
 when 'expense_other' then d:='other_operating_expense';c:='expense_unclassified';
 when 'expense_tax_payment' then d:='income_tax_payable';c:='expense_unclassified';
 when 'expense_indirect_tax_payment' then d:='indirect_tax_payable';c:='expense_unclassified';
 when 'expense_loan_payment' then d:='loan_payable';c:='expense_unclassified';
 when 'expense_capital_withdrawal' then d:='capital';c:='expense_unclassified';
 when 'income_tax_accrual' then d:='income_tax_expense';c:='income_tax_payable';
 when 'income_tax_reverse' then d:='income_tax_payable';c:='income_tax_expense';
 end case;
 if d in ('capital','loan_payable','income_tax_payable','indirect_tax_payable') then
 select coalesce(sum(case when credit_account=d then amount_minor else 0 end-case when debit_account=d then amount_minor else 0 end),0) into available from public.mt_accounting_adjustments where store_id=p_store and currency=p_currency and (debit_account=d or credit_account=d);
 if d='indirect_tax_payable' then
  available:=available+(select coalesce(sum(case when kind in ('sale','repair') then tax_minor else -tax_minor end),0) from public.mt_indirect_tax_entries where store_id=p_store and currency=p_currency);
 end if;
 if p_amount>available then raise exception 'Adjustment exceeds recorded liability or equity' using errcode='22023';end if;
 end if;
 insert into public.mt_accounting_adjustments(store_id,request_id,kind,source_request,currency,amount_minor,debit_account,credit_account,reference,note,actor) values(p_store,p_request,p_kind,p_source,p_currency,p_amount,d,c,btrim(p_reference),btrim(p_note),auth.uid()) returning * into r;return r.id;
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
 case c.kind when 'expense' then 'expense_unclassified' when 'supplier_payment' then 'accounts_payable' when 'exchange' then 'fx_clearing' else 'cash' end,
 case c.kind when 'sale' then 'sales_revenue' when 'funding' then 'funding_unclassified' when 'debt_payment' then 'accounts_receivable' when 'repair_receipt' then 'repair_revenue' when 'mixed_receipt' then 'fx_clearing' when 'supplier_refund' then 'accounts_payable' else 'cash' end,c.amount_minor::numeric
 from cash c where c.kind in ('sale','funding','expense','exchange','debt_payment','supplier_payment','repair_receipt','mixed_receipt','supplier_refund')
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
 union all select created_at,'accounting_adjustment',id,currency,debit_account,credit_account,amount_minor from public.mt_accounting_adjustments where store_id=p_store and created_at<p_until
 union all select created_at,'indirect_tax',id,currency,case kind when 'sale' then 'sales_revenue' when 'repair' then 'repair_revenue' else 'indirect_tax_payable' end,case when kind in ('sale','repair') then 'indirect_tax_payable' else 'sales_returns' end,tax_minor from public.mt_indirect_tax_entries where store_id=p_store and created_at<p_until
)
select * from pairs where pairs.amount>0;
$$;
create or replace function tenant_private.management_statements(p_store uuid,p_from date,p_to date,p_currency text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare tb jsonb;rows jsonb;rates jsonb;translated jsonb;cutoff timestamptz;missing integer;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_currency is null or p_currency not in ('USD','EUR','SYP') or p_to is null or p_to>(now() at time zone 'UTC')::date then raise exception 'Invalid reporting currency or date' using errcode='22023';end if;
 if not exists(select 1 from tenant_private.sale_currencies where store_id=p_store and currency=p_currency) then raise exception 'Reporting currency not enabled' using errcode='22023';end if;
 tb:=tenant_private.trial_balance(p_store,p_from,p_to);
 cutoff:=least(now(),(p_to+1)::timestamp at time zone 'UTC');
 with accounts as (select x->>'currency' currency,x->>'account' account,(x->>'closing')::numeric closing,(x->>'debit')::numeric-(x->>'credit')::numeric movement from jsonb_array_elements(tb->'rows') x),
 totals as (select currency,
 coalesce(sum(closing) filter(where account='cash'),0) cash,
 coalesce(sum(closing) filter(where account='inventory'),0) inventory,
 coalesce(sum(closing) filter(where account='accounts_receivable'),0) receivable,
 -coalesce(sum(closing) filter(where account='accounts_payable'),0) payable,
 -coalesce(sum(closing) filter(where account='capital'),0) capital,
 -coalesce(sum(closing) filter(where account='loan_payable'),0) loan_payable,
 -coalesce(sum(closing) filter(where account in ('income_tax_payable','indirect_tax_payable')),0) tax_payable,
 -coalesce(sum(closing) filter(where account in ('sales_revenue','repair_revenue','sales_returns','cost_of_goods_services','expense_unclassified','stock_adjustment_expense','rent_expense','payroll_expense','utilities_expense','other_operating_expense','income_tax_expense')),0) cumulative_result,
 -coalesce(sum(closing) filter(where account in ('funding_unclassified','stock_intake_unclassified','fx_clearing')),0) unresolved_balance,
 -coalesce(sum(movement) filter(where account in ('sales_revenue','repair_revenue','sales_returns')),0) revenue,
 coalesce(sum(movement) filter(where account='cost_of_goods_services'),0) cost,
 coalesce(sum(movement) filter(where account in ('expense_unclassified','stock_adjustment_expense','rent_expense','payroll_expense','utilities_expense','other_operating_expense')),0) expenses,
 coalesce(sum(movement) filter(where account='income_tax_expense'),0) income_tax
 from accounts group by currency),
 vals as (select c.currency,coalesce(t.cash,0) cash,coalesce(t.inventory,0) inventory,coalesce(t.receivable,0) receivable,coalesce(t.payable,0) payable,coalesce(t.capital,0) capital,coalesce(t.loan_payable,0) loan_payable,coalesce(t.tax_payable,0) tax_payable,coalesce(t.income_tax,0) income_tax,coalesce(t.cumulative_result,0) cumulative_result,coalesce(t.unresolved_balance,0) unresolved_balance,coalesce(t.revenue,0) revenue,coalesce(t.cost,0) cost,coalesce(t.expenses,0) expenses from tenant_private.sale_currencies c left join totals t on t.currency=c.currency where c.store_id=p_store)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'cash',cash::text,'inventory',inventory::text,'receivable',receivable::text,'assets',(cash+inventory+receivable)::text,'payable',payable::text,'capital',capital::text,'loan_payable',loan_payable::text,'tax_payable',tax_payable::text,'income_tax',income_tax::text,'result_after_recorded_tax',(revenue-cost-expenses-income_tax)::text,'cumulative_result',cumulative_result::text,'unresolved_balance',unresolved_balance::text,'revenue',revenue::text,'cost',cost::text,'expenses',expenses::text,'result_before_tax',(revenue-cost-expenses)::text) order by currency),'[]'::jsonb) into rows from vals;
 with used as (select x->>'currency' currency from jsonb_array_elements(rows) x where exists(select 1 from jsonb_each_text(x) y where y.key<>'currency' and y.value<>'0')),
 quotes as (select u.currency,q.id,q.created_at,case when u.currency=p_currency then 1 else q.numerator end numerator,case when u.currency=p_currency then 1 else q.denominator end denominator
 from used u left join lateral(select r.id,r.created_at,r.numerator,r.denominator from public.mt_fx_rates r where r.store_id=p_store and r.from_currency=u.currency and r.to_currency=p_currency and r.created_at<=cutoff and r.created_at>=cutoff-interval '24 hours' order by r.created_at desc,r.id desc limit 1) q on u.currency<>p_currency)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'rate_id',id,'quoted_at',created_at,'numerator',numerator,'denominator',denominator) order by currency),'[]'::jsonb),count(*) filter(where numerator is null) into rates,missing from quotes;
 if missing=0 and (tb->>'unknown_cost_events')::bigint=0 then
  with entries as (select y.key,sum(y.value::numeric*(r->>'numerator')::numeric/(r->>'denominator')::numeric) total from jsonb_array_elements(rows) x join lateral (select value r from jsonb_array_elements(rates) where value->>'currency'=x->>'currency') rr on true cross join lateral jsonb_each_text(x) y where y.key<>'currency' group by y.key)
  select jsonb_object_agg(k,coalesce(round(e.total),0)::text) into translated from unnest(array['cash','inventory','receivable','assets','payable','capital','loan_payable','tax_payable','income_tax','result_after_recorded_tax','cumulative_result','unresolved_balance','revenue','cost','expenses','result_before_tax']) k left join entries e on e.key=k;
 end if;
 return jsonb_build_object('mode','management_closing_rate','currency',p_currency,'rows',rows,'rates',rates,'missing_rates',missing,'unknown_cost_events',tb->'unknown_cost_events','translated',translated,'tax_status',case when exists(select 1 from public.mt_accounting_adjustments where store_id=p_store and kind in ('income_tax_accrual','income_tax_reverse','expense_tax_payment') and created_at<((p_to+1)::timestamp at time zone 'UTC')) then 'manual_recorded' else 'not_calculated' end,'final_profit',null);
end $$;
create or replace function tenant_private.financial_reconciliation(p_store uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;stock_mismatches bigint;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 with j as (
 select currency,account,sum(amount) balance from (
 select currency,debit_account account,amount from tenant_private.journal_pairs(p_store,'infinity'::timestamptz)
 union all select currency,credit_account,-amount from tenant_private.journal_pairs(p_store,'infinity'::timestamptz)) q group by currency,account
 ), source as (
 select currency,'cash' account,balance_minor::numeric amount from tenant_private.cash_balances where store_id=p_store
 union all select currency,'inventory',remaining_units::numeric*unit_cost_minor from tenant_private.stock_layers where store_id=p_store
 union all select currency,'accounts_receivable',remaining_minor::numeric from public.mt_debts where store_id=p_store
 union all select currency,'accounts_payable',-(total_minor::numeric-returned_units::numeric*unit_cost_minor-paid_minor+refunded_minor) from public.mt_purchases where store_id=p_store
 union all select currency,'income_tax_payable',case when kind='income_tax_accrual' then -amount_minor::numeric else amount_minor::numeric end from public.mt_accounting_adjustments where store_id=p_store and kind in ('income_tax_accrual','income_tax_reverse','expense_tax_payment')
 union all select currency,'indirect_tax_payable',case when kind in ('sale','repair') then -tax_minor::numeric else tax_minor::numeric end from public.mt_indirect_tax_entries where store_id=p_store
 union all select currency,'indirect_tax_payable',amount_minor::numeric from public.mt_accounting_adjustments where store_id=p_store and kind='expense_indirect_tax_payment'
 ), s as (select currency,account,sum(amount) balance from source group by currency,account),
 vals as (select c.currency,a.account,coalesce(j.balance,0) journal,coalesce(s.balance,0) recorded from tenant_private.sale_currencies c cross join unnest(array['cash','inventory','accounts_receivable','accounts_payable','income_tax_payable','indirect_tax_payable']) a(account) left join j on j.currency=c.currency and j.account=a.account left join s on s.currency=c.currency and s.account=a.account where c.store_id=p_store)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'account',account,'journal',journal::text,'recorded',recorded::text,'difference',(recorded-journal)::text,'balanced',recorded=journal) order by currency,account),'[]'::jsonb) into rows from vals;
 select count(*) into stock_mismatches from public.mt_products p where p.store_id=p_store and p.quantity<>(select coalesce(sum(l.remaining_units),0) from tenant_private.stock_layers l where l.store_id=p.store_id and l.product_id=p.id);
 return jsonb_build_object('mode','current_subledger_reconciliation','rows',rows,'stock_quantity_mismatches',stock_mismatches,'balanced',stock_mismatches=0 and not exists(select 1 from jsonb_array_elements(rows) x where x->>'balanced'='false'));
end; $$;

commit;