begin;
-- Append-only owner classifications: no arbitrary changes to cash, inventory, receivables or supplier subledgers.
create table public.mt_accounting_adjustments(
 store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null default gen_random_uuid(),request_id uuid not null,
 kind text not null check(kind in ('funding_equity','funding_loan','stock_equity','expense_rent','expense_payroll','expense_utilities','expense_other','expense_tax_payment','expense_loan_payment','expense_capital_withdrawal','income_tax_accrual','income_tax_reverse')),
 source_request uuid,currency text not null,amount_minor bigint not null check(amount_minor between 1 and 100000000000000),
 debit_account text not null,credit_account text not null,reference text not null check(length(btrim(reference)) between 1 and 160),note text not null check(length(btrim(note)) between 1 and 300),
 actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),unique(store_id,request_id),
 foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency),
 check((kind in ('income_tax_accrual','income_tax_reverse'))=(source_request is null)),check(debit_account<>credit_account)
);
create index mt_accounting_source_idx on public.mt_accounting_adjustments(store_id,source_request) where source_request is not null;
create unique index mt_accounting_tax_reference_idx on public.mt_accounting_adjustments(store_id,kind,currency,reference) where source_request is null;
alter table public.mt_accounting_adjustments enable row level security;
revoke all on public.mt_accounting_adjustments from public,anon,authenticated,service_role;
grant select on public.mt_accounting_adjustments to authenticated;
create policy owner_read on public.mt_accounting_adjustments for select to authenticated using(tenant_private.member_role(store_id)='owner');
create trigger mt_guard_closed_period before insert on public.mt_accounting_adjustments for each row execute function tenant_private.guard_closed_period();
create function tenant_private.accounting_adjust(p_store uuid,p_request uuid,p_kind text,p_source uuid,p_currency text,p_amount bigint,p_reference text,p_note text) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.mt_accounting_adjustments%rowtype;d text;c text;source_amount bigint;source_currency text;available numeric;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_amount is null or p_amount not between 1 and 100000000000000 or p_reference is null or length(btrim(p_reference)) not between 1 and 160 or p_note is null or length(btrim(p_note)) not between 1 and 300 or p_kind is null or p_kind not in ('funding_equity','funding_loan','stock_equity','expense_rent','expense_payroll','expense_utilities','expense_other','expense_tax_payment','expense_loan_payment','expense_capital_withdrawal','income_tax_accrual','income_tax_reverse') or ((p_kind in ('income_tax_accrual','income_tax_reverse'))<>(p_source is null)) then raise exception 'Invalid accounting entry' using errcode='22023';end if;
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
 when 'expense_loan_payment' then d:='loan_payable';c:='expense_unclassified';
 when 'expense_capital_withdrawal' then d:='capital';c:='expense_unclassified';
 when 'income_tax_accrual' then d:='income_tax_expense';c:='income_tax_payable';
 when 'income_tax_reverse' then d:='income_tax_payable';c:='income_tax_expense';
 end case;
 if d in ('capital','loan_payable','income_tax_payable') then
 select coalesce(sum(case when credit_account=d then amount_minor else 0 end-case when debit_account=d then amount_minor else 0 end),0) into available from public.mt_accounting_adjustments where store_id=p_store and currency=p_currency and (debit_account=d or credit_account=d);
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
 -coalesce(sum(closing) filter(where account='income_tax_payable'),0) tax_payable,
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
create function public.mt_accounting_adjust(p_store uuid,p_request uuid,p_kind text,p_source uuid,p_currency text,p_amount bigint,p_reference text,p_note text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.accounting_adjust(p_store,p_request,p_kind,p_source,p_currency,p_amount,p_reference,p_note)$$;
create function public.mt_list_accounting_adjustments(p_store uuid,p_after uuid default null,p_limit integer default 50) returns setof public.mt_accounting_adjustments language plpgsql stable security invoker set search_path='' as $$
begin if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page' using errcode='22023';end if;return query select * from public.mt_accounting_adjustments where store_id=p_store and (p_after is null or id>p_after) order by id limit p_limit;end $$;
revoke all on function tenant_private.accounting_adjust(uuid,uuid,text,uuid,text,bigint,text,text),public.mt_accounting_adjust(uuid,uuid,text,uuid,text,bigint,text,text),public.mt_list_accounting_adjustments(uuid,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.accounting_adjust(uuid,uuid,text,uuid,text,bigint,text,text),public.mt_accounting_adjust(uuid,uuid,text,uuid,text,bigint,text,text),public.mt_list_accounting_adjustments(uuid,uuid,integer) to authenticated;
commit;