-- Manual bank/cash transfers. No external bank integration and no artificial revenue.
begin;
create table tenant_private.bank_accounts(store_id uuid not null references tenant_private.workspaces(store_id),id uuid not null,name text not null check(length(btrim(name)) between 1 and 120),currency text not null,balance_minor bigint not null default 0 check(balance_minor between 0 and 100000000000000),primary key(store_id,id),unique(store_id,name,currency),foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency));
create table tenant_private.bank_transfers(store_id uuid not null,request_id uuid not null,account_id uuid not null,cash_id uuid not null,direction text not null check(direction in ('deposit','withdrawal')),amount_minor bigint not null check(amount_minor>0),reference text not null check(length(btrim(reference)) between 1 and 160),actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,request_id),unique(store_id,cash_id),foreign key(store_id,account_id) references tenant_private.bank_accounts(store_id,id),foreign key(store_id,cash_id) references public.mt_cash_movements(store_id,id));
alter table tenant_private.bank_accounts enable row level security;alter table tenant_private.bank_transfers enable row level security;revoke all on tenant_private.bank_accounts,tenant_private.bank_transfers from public,anon,authenticated,service_role;
create trigger mt_guard_closed_period before insert on tenant_private.bank_transfers for each row execute function tenant_private.guard_closed_period();
create function tenant_private.bank_create(p_store uuid,p_id uuid,p_name text,p_currency text) returns uuid language plpgsql security definer set search_path='' as $$
declare a tenant_private.bank_accounts%rowtype;begin
 perform tenant_private.owner_write(p_store);
 if p_id is null or p_name is null or length(btrim(p_name)) not between 1 and 120 then raise exception 'Invalid bank account' using errcode='22023';end if;
 select * into a from tenant_private.bank_accounts where store_id=p_store and id=p_id;
 if found then if a.name<>btrim(p_name) or a.currency<>p_currency then raise exception 'Conflicting account' using errcode='22023';end if;return p_id;end if;
 if (select count(*) from tenant_private.bank_accounts where store_id=p_store)>=50 then raise exception 'Account limit' using errcode='22023';end if;
 insert into tenant_private.bank_accounts(store_id,id,name,currency) values(p_store,p_id,btrim(p_name),p_currency);return p_id;
end $$;
create function tenant_private.bank_transfer(p_store uuid,p_request uuid,p_account uuid,p_direction text,p_amount bigint,p_reference text,p_confirm boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare a tenant_private.bank_accounts%rowtype;v tenant_private.bank_transfers%rowtype;c uuid;
begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_direction is null or p_direction not in ('deposit','withdrawal') or p_amount is null or p_amount not between 1 and 100000000000000 or p_reference is null or length(btrim(p_reference)) not between 1 and 160 or p_confirm is distinct from true then raise exception 'Confirm actual transfer' using errcode='22023';end if;
 select * into v from tenant_private.bank_transfers where store_id=p_store and request_id=p_request;
 if found then if v.actor<>auth.uid() or v.account_id<>p_account or v.direction<>p_direction or v.amount_minor<>p_amount or v.reference<>btrim(p_reference) then raise exception 'Conflicting bank request' using errcode='22023';end if;return v.cash_id;end if;
 select * into a from tenant_private.bank_accounts where store_id=p_store and id=p_account for update;
 if not found or (p_direction='withdrawal' and a.balance_minor<p_amount) then raise exception 'Account unavailable or insufficient balance' using errcode='22023';end if;
 if exists(select 1 from public.mt_cash_movements where store_id=p_store and request_id=p_request) then raise exception 'Request already used' using errcode='22023';end if;
 c:=tenant_private.cash_record(p_store,p_request,case when p_direction='deposit' then 'expense' else 'funding' end,a.currency,p_amount,left('Bank transfer: '||btrim(p_reference),300),null,null);
 update tenant_private.bank_accounts set balance_minor=balance_minor+case when p_direction='deposit' then p_amount else -p_amount end where store_id=p_store and id=p_account;
 insert into tenant_private.bank_transfers(store_id,request_id,account_id,cash_id,direction,amount_minor,reference,actor) values(p_store,p_request,p_account,c,p_direction,p_amount,btrim(p_reference),auth.uid());return c;
end $$;
create function tenant_private.bank_overview(p_store uuid,p_before timestamptz,p_before_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if (p_before is null)<>(p_before_id is null) then raise exception 'Invalid cursor' using errcode='22023';end if;
 return jsonb_build_object('accounts',coalesce((select jsonb_agg(to_jsonb(x) order by name,currency) from (select id,name,currency,balance_minor from tenant_private.bank_accounts where store_id=p_store)x),'[]'::jsonb),'transfers',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc,request_id desc) from (select t.request_id,a.name,a.currency,t.direction,t.amount_minor,t.reference,t.created_at from tenant_private.bank_transfers t join tenant_private.bank_accounts a on a.store_id=t.store_id and a.id=t.account_id where t.store_id=p_store and (p_before is null or (t.created_at,t.request_id)<(p_before,p_before_id)) order by t.created_at desc,t.request_id desc limit 50)x),'[]'::jsonb));
end $$;
create function tenant_private.guard_bank_classification() returns trigger language plpgsql security definer set search_path='' as $$begin if exists(select 1 from tenant_private.bank_transfers where store_id=new.store_id and request_id=new.source_request) then raise exception 'Bank transfer already classified' using errcode='22023';end if;return new;end$$;
create trigger mt_guard_bank_classification before insert on public.mt_accounting_adjustments for each row execute function tenant_private.guard_bank_classification();
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
 coalesce(sum(closing) filter(where account='bank'),0) bank,
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
 vals as (select c.currency,coalesce(t.cash,0) cash,coalesce(t.bank,0) bank,coalesce(t.inventory,0) inventory,coalesce(t.receivable,0) receivable,coalesce(t.payable,0) payable,coalesce(t.capital,0) capital,coalesce(t.loan_payable,0) loan_payable,coalesce(t.tax_payable,0) tax_payable,coalesce(t.income_tax,0) income_tax,coalesce(t.cumulative_result,0) cumulative_result,coalesce(t.unresolved_balance,0) unresolved_balance,coalesce(t.revenue,0) revenue,coalesce(t.cost,0) cost,coalesce(t.expenses,0) expenses from tenant_private.sale_currencies c left join totals t on t.currency=c.currency where c.store_id=p_store)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'cash',cash::text,'bank',bank::text,'inventory',inventory::text,'receivable',receivable::text,'assets',(cash+bank+inventory+receivable)::text,'payable',payable::text,'capital',capital::text,'loan_payable',loan_payable::text,'tax_payable',tax_payable::text,'income_tax',income_tax::text,'result_after_recorded_tax',(revenue-cost-expenses-income_tax)::text,'cumulative_result',cumulative_result::text,'unresolved_balance',unresolved_balance::text,'revenue',revenue::text,'cost',cost::text,'expenses',expenses::text,'result_before_tax',(revenue-cost-expenses)::text) order by currency),'[]'::jsonb) into rows from vals;
 with used as (select x->>'currency' currency from jsonb_array_elements(rows) x where exists(select 1 from jsonb_each_text(x) y where y.key<>'currency' and y.value<>'0')),
 quotes as (select u.currency,q.id,q.created_at,case when u.currency=p_currency then 1 else q.numerator end numerator,case when u.currency=p_currency then 1 else q.denominator end denominator
 from used u left join lateral(select r.id,r.created_at,r.numerator,r.denominator from public.mt_fx_rates r where r.store_id=p_store and r.from_currency=u.currency and r.to_currency=p_currency and r.created_at<=cutoff and r.created_at>=cutoff-interval '24 hours' order by r.created_at desc,r.id desc limit 1) q on u.currency<>p_currency)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'rate_id',id,'quoted_at',created_at,'numerator',numerator,'denominator',denominator) order by currency),'[]'::jsonb),count(*) filter(where numerator is null) into rates,missing from quotes;
 if missing=0 and (tb->>'unknown_cost_events')::bigint=0 then
  with entries as (select y.key,sum(y.value::numeric*(r->>'numerator')::numeric/(r->>'denominator')::numeric) total from jsonb_array_elements(rows) x join lateral (select value r from jsonb_array_elements(rates) where value->>'currency'=x->>'currency') rr on true cross join lateral jsonb_each_text(x) y where y.key<>'currency' group by y.key)
  select jsonb_object_agg(k,coalesce(round(e.total),0)::text) into translated from unnest(array['cash','bank','inventory','receivable','assets','payable','capital','loan_payable','tax_payable','income_tax','result_after_recorded_tax','cumulative_result','unresolved_balance','revenue','cost','expenses','result_before_tax']) k left join entries e on e.key=k;
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
 union all select currency,'bank',balance_minor::numeric from tenant_private.bank_accounts where store_id=p_store
 union all select currency,'inventory',remaining_units::numeric*unit_cost_minor from tenant_private.stock_layers where store_id=p_store
 union all select currency,'accounts_receivable',remaining_minor::numeric from public.mt_debts where store_id=p_store
 union all select currency,'accounts_payable',-(total_minor::numeric-returned_units::numeric*unit_cost_minor-paid_minor+refunded_minor) from public.mt_purchases where store_id=p_store
 union all select currency,'income_tax_payable',case when kind='income_tax_accrual' then -amount_minor::numeric else amount_minor::numeric end from public.mt_accounting_adjustments where store_id=p_store and kind in ('income_tax_accrual','income_tax_reverse','expense_tax_payment')
 union all select currency,'indirect_tax_payable',case when kind in ('sale','repair') then -tax_minor::numeric else tax_minor::numeric end from public.mt_indirect_tax_entries where store_id=p_store
 union all select currency,'indirect_tax_payable',amount_minor::numeric from public.mt_accounting_adjustments where store_id=p_store and kind='expense_indirect_tax_payment'
 ), s as (select currency,account,sum(amount) balance from source group by currency,account),
 vals as (select c.currency,a.account,coalesce(j.balance,0) journal,coalesce(s.balance,0) recorded from tenant_private.sale_currencies c cross join unnest(array['cash','bank','inventory','accounts_receivable','accounts_payable','income_tax_payable','indirect_tax_payable']) a(account) left join j on j.currency=c.currency and j.account=a.account left join s on s.currency=c.currency and s.account=a.account where c.store_id=p_store)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'account',account,'journal',journal::text,'recorded',recorded::text,'difference',(recorded-journal)::text,'balanced',recorded=journal) order by currency,account),'[]'::jsonb) into rows from vals;
 select count(*) into stock_mismatches from public.mt_products p where p.store_id=p_store and p.quantity<>(select coalesce(sum(l.remaining_units),0) from tenant_private.stock_layers l where l.store_id=p.store_id and l.product_id=p.id);
 return jsonb_build_object('mode','current_subledger_reconciliation','rows',rows,'stock_quantity_mismatches',stock_mismatches,'balanced',stock_mismatches=0 and not exists(select 1 from jsonb_array_elements(rows) x where x->>'balanced'='false'));
end; $$;


create or replace function tenant_private.cash_report(p_store uuid,p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 then raise exception 'Invalid date range' using errcode='22023';end if;
 with movements as (select m.*,b.direction from public.mt_cash_movements m left join tenant_private.bank_transfers b on b.store_id=m.store_id and b.cash_id=m.id where m.store_id=p_store and m.created_at>=p_from::timestamp at time zone 'UTC' and m.created_at<(p_to+1)::timestamp at time zone 'UTC'),
 flows as (select currency,case when direction='deposit' then 'bank_deposit' when direction='withdrawal' then 'bank_withdrawal' else kind end as kind,case when kind in ('sale','funding','debt_payment','repair_receipt','mixed_receipt','supplier_refund') then amount_minor else -amount_minor end as value from movements union all select target_currency,'exchange_in',target_amount_minor from movements where kind='exchange'),
 totals as (select currency,sum(value) filter(where value>0) as incoming,sum(-value) filter(where value<0) as outgoing,sum(value) as net,sum(value) filter(where kind in ('sale','debt_payment','repair_receipt','mixed_receipt')) as collections,sum(-value) filter(where kind in ('return_refund','repair_refund')) as refunds,sum(-value) filter(where kind='supplier_payment') as supplier_payments,sum(value) filter(where kind='supplier_refund') as supplier_refunds,sum(-value) filter(where kind='expense') as expenses from flows group by currency)
 select coalesce(jsonb_agg(jsonb_build_object('currency',c.currency,'incoming',coalesce(t.incoming,0)::text,'outgoing',coalesce(t.outgoing,0)::text,'net',coalesce(t.net,0)::text,'collections',coalesce(t.collections,0)::text,'refunds',coalesce(t.refunds,0)::text,'supplier_payments',coalesce(t.supplier_payments,0)::text,'supplier_refunds',coalesce(t.supplier_refunds,0)::text,'expenses',coalesce(t.expenses,0)::text) order by c.currency),'[]'::jsonb) into r
 from tenant_private.sale_currencies c left join totals t on t.currency=c.currency where c.store_id=p_store;
 return r;
end $$;

create function public.mt_bank_create(p_store uuid,p_id uuid,p_name text,p_currency text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.bank_create(p_store,p_id,p_name,p_currency)$$;
create function public.mt_bank_transfer(p_store uuid,p_request uuid,p_account uuid,p_direction text,p_amount bigint,p_reference text,p_confirm boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.bank_transfer(p_store,p_request,p_account,p_direction,p_amount,p_reference,p_confirm)$$;
create function public.mt_bank_overview(p_store uuid,p_before timestamptz default null,p_before_id uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.bank_overview(p_store,p_before,p_before_id)$$;
revoke all on function tenant_private.guard_bank_classification(),tenant_private.bank_create(uuid,uuid,text,text),tenant_private.bank_transfer(uuid,uuid,uuid,text,bigint,text,boolean),tenant_private.bank_overview(uuid,timestamptz,uuid),public.mt_bank_create(uuid,uuid,text,text),public.mt_bank_transfer(uuid,uuid,uuid,text,bigint,text,boolean),public.mt_bank_overview(uuid,timestamptz,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.bank_create(uuid,uuid,text,text),tenant_private.bank_transfer(uuid,uuid,uuid,text,bigint,text,boolean),tenant_private.bank_overview(uuid,timestamptz,uuid),public.mt_bank_create(uuid,uuid,text,text),public.mt_bank_transfer(uuid,uuid,uuid,text,bigint,text,boolean),public.mt_bank_overview(uuid,timestamptz,uuid) to authenticated;
commit;
