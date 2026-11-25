begin;
-- Derived, reproducible journal pairs from immutable operational sources.
-- Currency-specific ledgers; FX clearing and unclassified accounts are explicit.
-- No invented valuation, tax, equity classification or consolidated currency.
create function tenant_private.journal_pairs(p_store uuid,p_until timestamptz)
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
 union all select created_at,'purchase',id,currency,'inventory','accounts_payable',total_minor from public.mt_purchases where store_id=p_store and created_at<p_until
 union all select created_at,'supplier_return',id,currency,'accounts_payable','inventory',units::numeric*unit_cost_minor from public.mt_supplier_returns where store_id=p_store and created_at<p_until
 union all select e.created_at,'standalone_intake',e.request_id,i.currency,'inventory','stock_intake_unclassified',i.units::numeric*i.unit_cost_minor
 from tenant_private.cost_intakes i join public.mt_stock_events e on e.store_id=i.store_id and e.request_id=i.request_id
 where i.store_id=p_store and e.created_at<p_until and not exists(select 1 from public.mt_purchases p where p.store_id=i.store_id and p.intake_request=i.request_id)
 union all select e.created_at,'stock_adjustment',e.request_id,l.currency,'stock_adjustment_expense','inventory',a.units::numeric*l.unit_cost_minor
 from public.mt_stock_events e join tenant_private.stock_consumptions a on a.store_id=e.store_id and a.product_id=e.product_id and a.event_id=e.request_id
 join tenant_private.stock_layers l on l.store_id=a.store_id and l.product_id=a.product_id and l.id=a.layer_id
 where e.store_id=p_store and e.created_at<p_until and e.delta<0 and e.sale_id is null and e.supplier_return_id is null and not exists(select 1 from public.mt_repair_invoice_lines r where r.store_id=e.store_id and r.stock_request=e.request_id)
 union all select created_at,'cost_source',event_id,source_currency,
 case when source_currency<>invoice_currency and invoice_cost_minor is not null then 'fx_clearing' else 'cost_of_goods_services' end,'inventory',source_cost_minor from costs
 union all select created_at,'cost_conversion',event_id,invoice_currency,'cost_of_goods_services','fx_clearing',invoice_cost_minor from costs where source_currency<>invoice_currency and invoice_cost_minor is not null
 union all select created_at,'return_cost_source',return_id,source_currency,'inventory',
 case when source_currency<>invoice_currency and invoice_cost_minor is not null then 'fx_clearing' else 'cost_of_goods_services' end,source_cost from return_costs
 union all select created_at,'return_cost_conversion',return_id,invoice_currency,'fx_clearing','cost_of_goods_services',invoice_cost_minor from return_costs where source_currency<>invoice_currency and invoice_cost_minor is not null
)
select * from pairs where pairs.amount>0;
$$;
-- Use explicit CTE column names rather than engine-generated names.
create function tenant_private.trial_balance(p_store uuid,p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare lo timestamptz;hi timestamptz;r jsonb;unknown bigint;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 then raise exception 'Invalid date range' using errcode='22023';end if;
 lo:=p_from::timestamp at time zone 'UTC';hi:=(p_to+1)::timestamp at time zone 'UTC';
 with pairs as (select * from tenant_private.journal_pairs(p_store,hi)),
 entries as (select posted_at,currency,debit_account account,amount debit,0::numeric credit from pairs union all select posted_at,currency,credit_account,0,amount from pairs),
 totals as (select currency,account,coalesce(sum(debit-credit) filter(where posted_at<lo),0) opening,coalesce(sum(debit) filter(where posted_at>=lo),0) debit,coalesce(sum(credit) filter(where posted_at>=lo),0) credit,sum(debit-credit) closing from entries group by currency,account)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'account',account,'opening',opening::text,'debit',debit::text,'credit',credit::text,'closing',closing::text) order by currency,account),'[]'::jsonb) into r from totals;
 select count(*) into unknown from (
 select 1 from tenant_private.cost_postings where store_id=p_store and created_at<hi and invoice_cost_minor is null
 union all select 1 from tenant_private.return_cost_postings where store_id=p_store and created_at<hi and invoice_cost_minor is null
 union all select 1 from public.mt_stock_events e where e.store_id=p_store and e.created_at<hi and e.delta>0 and e.return_id is null and not exists(select 1 from tenant_private.cost_intakes i where i.store_id=e.store_id and i.request_id=e.request_id)
 ) missing;
 return jsonb_build_object('rows',r,'unknown_cost_events',unknown,'mode','operational_unclassified');
end $$;
create function public.mt_trial_balance(p_store uuid,p_from date,p_to date) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.trial_balance(p_store,p_from,p_to)$$;
revoke all on function tenant_private.journal_pairs(uuid,timestamptz),tenant_private.trial_balance(uuid,date,date),public.mt_trial_balance(uuid,date,date) from public,anon,authenticated,service_role;
grant execute on function tenant_private.trial_balance(uuid,date,date),public.mt_trial_balance(uuid,date,date) to authenticated;
commit;