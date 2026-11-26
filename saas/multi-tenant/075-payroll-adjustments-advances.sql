-- Actual advances are receivables. Adjustments and offsets preserve the original statement.
begin;
alter table tenant_private.staff_payroll add column zero_payment_request uuid,add unique(store_id,zero_payment_request);
do $$declare c text;n int;begin
 select count(*),min(conname) into n,c from pg_constraint where conrelid='tenant_private.staff_payroll'::regclass and contype='c' and pg_get_constraintdef(oid) like '%paid_at%' and pg_get_constraintdef(oid) like '%payment_request%';
 if n<>1 then raise exception 'Expected payroll payment constraint';end if;
 execute format('alter table tenant_private.staff_payroll drop constraint %I',c);
end$$;
alter table tenant_private.staff_payroll add constraint mt_payroll_settlement_state check((paid_at is null and payment_request is null and zero_payment_request is null) or (paid_at is not null and ((payment_request is null)<>(zero_payment_request is null))));
create table tenant_private.staff_payroll_adjustments(store_id uuid not null,id uuid not null,payroll_id uuid not null,kind text not null check(kind in ('bonus','deduction')),amount_minor bigint not null check(amount_minor between 1 and 100000000000000),reason text not null check(length(btrim(reason)) between 1 and 160),actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),foreign key(store_id,payroll_id) references tenant_private.staff_payroll(store_id,id));
create table tenant_private.staff_advances(store_id uuid not null,id uuid not null,user_id uuid not null,branch_id uuid,currency text not null,amount_minor bigint not null check(amount_minor between 1 and 100000000000000),reference text not null check(length(btrim(reference)) between 1 and 160),actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),foreign key(store_id,id) references tenant_private.branch_vouchers(store_id,request_id),foreign key(store_id,user_id) references tenant_private.members(store_id,user_id),foreign key(store_id,branch_id) references tenant_private.branches(store_id,id),foreign key(store_id,currency) references tenant_private.sale_currencies(store_id,currency));
create table tenant_private.staff_advance_offsets(store_id uuid not null,id uuid not null,advance_id uuid not null,payroll_id uuid not null,amount_minor bigint not null check(amount_minor between 1 and 100000000000000),actor uuid not null,created_at timestamptz not null default now(),primary key(store_id,id),foreign key(store_id,advance_id) references tenant_private.staff_advances(store_id,id),foreign key(store_id,payroll_id) references tenant_private.staff_payroll(store_id,id));
do $$declare t text;begin foreach t in array array['staff_payroll_adjustments','staff_advances','staff_advance_offsets'] loop execute format('alter table tenant_private.%I enable row level security',t);execute format('revoke all on tenant_private.%I from public,anon,authenticated,service_role',t);execute format('create trigger mt_guard_closed_period before insert on tenant_private.%I for each row execute function tenant_private.guard_closed_period()',t);end loop;end$$;
create function tenant_private.payroll_due(p_store uuid,p_id uuid) returns bigint language sql stable security definer set search_path='' as $$
 select (p.total_minor+coalesce((select sum(case when a.kind='bonus' then a.amount_minor else -a.amount_minor end) from tenant_private.staff_payroll_adjustments a where a.store_id=p_store and a.payroll_id=p_id),0)-coalesce((select sum(o.amount_minor) from tenant_private.staff_advance_offsets o where o.store_id=p_store and o.payroll_id=p_id),0))::bigint from tenant_private.staff_payroll p where p.store_id=p_store and p.id=p_id
$$;
create function tenant_private.advance_remaining(p_store uuid,p_id uuid) returns bigint language sql stable security definer set search_path='' as $$
 select (a.amount_minor-coalesce((select sum(o.amount_minor) from tenant_private.staff_advance_offsets o where o.store_id=p_store and o.advance_id=p_id),0))::bigint from tenant_private.staff_advances a where a.store_id=p_store and a.id=p_id
$$;
create function tenant_private.payroll_adjust(p_store uuid,p_id uuid,p_payroll uuid,p_kind text,p_amount bigint,p_reason text) returns uuid language plpgsql security definer set search_path='' as $$
declare p tenant_private.staff_payroll%rowtype;a tenant_private.staff_payroll_adjustments%rowtype;due bigint;begin
 perform tenant_private.owner_write(p_store);
 if p_id is null or p_kind is null or p_kind not in ('bonus','deduction') or p_amount is null or p_amount not between 1 and 100000000000000 or p_reason is null or length(btrim(p_reason)) not between 1 and 160 then raise exception 'Invalid adjustment' using errcode='22023';end if;
 select * into a from tenant_private.staff_payroll_adjustments where store_id=p_store and id=p_id;
 if found then if a.actor<>auth.uid() or a.payroll_id<>p_payroll or a.kind<>p_kind or a.amount_minor<>p_amount or a.reason<>btrim(p_reason) then raise exception 'Conflicting adjustment' using errcode='22023';end if;return p_id;end if;
 select * into p from tenant_private.staff_payroll where store_id=p_store and id=p_payroll for update;
 if not found or p.paid_at is not null then raise exception 'Unpaid statement required' using errcode='22023';end if;
 due:=tenant_private.payroll_due(p_store,p_payroll)+case when p_kind='bonus' then p_amount else -p_amount end;
 if due not between 0 and 100000000000000 then raise exception 'Adjustment exceeds payable limits' using errcode='22023';end if;
 insert into tenant_private.staff_payroll_adjustments(store_id,id,payroll_id,kind,amount_minor,reason,actor) values(p_store,p_id,p_payroll,p_kind,p_amount,btrim(p_reason),auth.uid());return p_id;
end $$;
create function tenant_private.payroll_advance(p_store uuid,p_id uuid,p_user uuid,p_branch uuid,p_currency text,p_amount bigint,p_reference text,p_confirm boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare a tenant_private.staff_advances%rowtype;begin
 perform tenant_private.owner_write(p_store);
 if p_id is null or p_confirm is distinct from true or p_amount is null or p_amount not between 1 and 100000000000000 or p_reference is null or length(btrim(p_reference)) not between 1 and 160 or not exists(select 1 from tenant_private.members where store_id=p_store and user_id=p_user and active and role<>'owner') then raise exception 'Confirm employee advance' using errcode='22023';end if;
 select * into a from tenant_private.staff_advances where store_id=p_store and id=p_id;
 if found then if a.actor<>auth.uid() or a.user_id<>p_user or a.branch_id is distinct from p_branch or a.currency<>p_currency or a.amount_minor<>p_amount or a.reference<>btrim(p_reference) then raise exception 'Conflicting advance' using errcode='22023';end if;return p_id;end if;
 if exists(select 1 from tenant_private.branch_vouchers where store_id=p_store and request_id=p_id) then raise exception 'Request used' using errcode='22023';end if;
 perform tenant_private.branch_voucher(p_store,p_id,p_branch,'salary',p_currency,p_amount,p_user::text,btrim(p_reference));
 insert into tenant_private.staff_advances(store_id,id,user_id,branch_id,currency,amount_minor,reference,actor) values(p_store,p_id,p_user,p_branch,p_currency,p_amount,btrim(p_reference),auth.uid());return p_id;
end $$;
create function tenant_private.payroll_offset(p_store uuid,p_id uuid,p_payroll uuid,p_advance uuid,p_amount bigint) returns uuid language plpgsql security definer set search_path='' as $$
declare o tenant_private.staff_advance_offsets%rowtype;p tenant_private.staff_payroll%rowtype;a tenant_private.staff_advances%rowtype;begin
 perform tenant_private.owner_write(p_store);
 if p_id is null or p_amount is null or p_amount not between 1 and 100000000000000 then raise exception 'Invalid offset' using errcode='22023';end if;
 select * into o from tenant_private.staff_advance_offsets where store_id=p_store and id=p_id;
 if found then if o.actor<>auth.uid() or o.payroll_id<>p_payroll or o.advance_id<>p_advance or o.amount_minor<>p_amount then raise exception 'Conflicting offset' using errcode='22023';end if;return p_id;end if;
 select * into p from tenant_private.staff_payroll where store_id=p_store and id=p_payroll for update;
 if not found or p.paid_at is not null then raise exception 'Unpaid statement required' using errcode='22023';end if;
 select * into a from tenant_private.staff_advances where store_id=p_store and id=p_advance for update;
 if not found or a.user_id<>p.user_id or a.currency<>p.currency or a.branch_id is distinct from p.branch_id or p_amount>tenant_private.advance_remaining(p_store,p_advance) or p_amount>tenant_private.payroll_due(p_store,p_payroll) then raise exception 'Incompatible or insufficient advance' using errcode='22023';end if;
 insert into tenant_private.staff_advance_offsets(store_id,id,advance_id,payroll_id,amount_minor,actor) values(p_store,p_id,p_advance,p_payroll,p_amount,auth.uid());return p_id;
end $$;
create or replace function tenant_private.staff_payroll_pay(p_store uuid,p_id uuid,p_request uuid,p_confirm boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare v tenant_private.staff_payroll%rowtype;due bigint;begin
 perform tenant_private.owner_write(p_store);
 if p_request is null or p_confirm is distinct from true then raise exception 'Confirm actual disbursement' using errcode='22023';end if;
 select * into v from tenant_private.staff_payroll where store_id=p_store and id=p_id for update;
 if not found then raise exception 'Unknown statement' using errcode='22023';end if;
 if v.paid_at is not null then if coalesce(v.payment_request,v.zero_payment_request) is distinct from p_request then raise exception 'Already paid' using errcode='22023';end if;return p_id;end if;
 if exists(select 1 from tenant_private.branch_vouchers where store_id=p_store and request_id=p_request) then raise exception 'Request used' using errcode='22023';end if;
 due:=tenant_private.payroll_due(p_store,p_id);
 if due<0 then raise exception 'Invalid payroll due';end if;
 if due>0 then
 perform tenant_private.branch_voucher(p_store,p_request,v.branch_id,'salary',v.currency,due,v.user_id::text,'Payroll '||v.period::text||' / '||v.id::text);
 update tenant_private.staff_payroll set paid_at=now(),payment_request=p_request where store_id=p_store and id=p_id;
 else
 update tenant_private.staff_payroll set paid_at=now(),zero_payment_request=p_request where store_id=p_store and id=p_id;
 end if;return p_id;
end
$$;
create function tenant_private.payroll_details(p_store uuid,p_user uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r text:=tenant_private.member_role(p_store);u uuid:=coalesce(p_user,auth.uid());begin
 if r is null or (r<>'owner' and u<>auth.uid()) then raise exception 'Access denied' using errcode='42501';end if;
 return jsonb_build_object('advances',coalesce((select jsonb_agg(to_jsonb(x) order by created_at desc) from (select id,currency,branch_id,amount_minor,tenant_private.advance_remaining(store_id,id) remaining_minor,reference,created_at from tenant_private.staff_advances where store_id=p_store and user_id=u order by created_at desc limit 100)x),'[]'),'statements',coalesce((select jsonb_agg(to_jsonb(x) order by period desc) from (select id,period,currency,total_minor,tenant_private.payroll_due(store_id,id) net_minor,paid_at,coalesce((select sum(amount_minor) from tenant_private.staff_payroll_adjustments a where a.store_id=p.store_id and a.payroll_id=p.id and a.kind='bonus'),0) bonus_minor,coalesce((select sum(amount_minor) from tenant_private.staff_payroll_adjustments a where a.store_id=p.store_id and a.payroll_id=p.id and a.kind='deduction'),0) deduction_minor,coalesce((select sum(amount_minor) from tenant_private.staff_advance_offsets o where o.store_id=p.store_id and o.payroll_id=p.id),0) advance_minor from tenant_private.staff_payroll p where store_id=p_store and user_id=u order by period desc limit 36)x),'[]'));
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
 union all select a.created_at,'accounting_adjustment',a.id,a.currency,case when adv.id is not null then 'employee_advances' when p.id is not null then 'payroll_payable' else a.debit_account end,a.credit_account,a.amount_minor from public.mt_accounting_adjustments a left join tenant_private.branch_vouchers v on v.store_id=a.store_id and v.adjustment_id=a.id left join tenant_private.staff_payroll p on p.store_id=v.store_id and p.payment_request=v.request_id left join tenant_private.staff_advances adv on adv.store_id=v.store_id and adv.id=v.request_id where a.store_id=p_store and a.created_at<p_until
 union all select a.created_at,'payroll_adjustment',a.id,p.currency,case when a.kind='bonus' then 'payroll_expense' else 'payroll_payable' end,case when a.kind='bonus' then 'payroll_payable' else 'payroll_expense' end,a.amount_minor from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id where a.store_id=p_store and a.created_at<p_until
 union all select o.created_at,'payroll_advance_offset',o.id,p.currency,'payroll_payable','employee_advances',o.amount_minor from tenant_private.staff_advance_offsets o join tenant_private.staff_payroll p on p.store_id=o.store_id and p.id=o.payroll_id where o.store_id=p_store and o.created_at<p_until
 union all select created_at,'payroll_accrual',id,currency,'payroll_expense','payroll_payable',total_minor from tenant_private.staff_payroll where store_id=p_store and created_at<p_until
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
 coalesce(sum(closing) filter(where account='employee_advances'),0) employee_advances,
 coalesce(sum(closing) filter(where account='bank'),0) bank,
 coalesce(sum(closing) filter(where account='inventory'),0) inventory,
 coalesce(sum(closing) filter(where account='accounts_receivable'),0) receivable,
 -coalesce(sum(closing) filter(where account='accounts_payable'),0) payable,
 -coalesce(sum(closing) filter(where account='capital'),0) capital,
 -coalesce(sum(closing) filter(where account='loan_payable'),0) loan_payable,
 -coalesce(sum(closing) filter(where account='payroll_payable'),0) payroll_payable,
 -coalesce(sum(closing) filter(where account in ('income_tax_payable','indirect_tax_payable')),0) tax_payable,
 -coalesce(sum(closing) filter(where account in ('sales_revenue','repair_revenue','sales_returns','cost_of_goods_services','expense_unclassified','stock_adjustment_expense','rent_expense','payroll_expense','utilities_expense','other_operating_expense','income_tax_expense')),0) cumulative_result,
 -coalesce(sum(closing) filter(where account in ('funding_unclassified','stock_intake_unclassified','fx_clearing')),0) unresolved_balance,
 -coalesce(sum(movement) filter(where account in ('sales_revenue','repair_revenue','sales_returns')),0) revenue,
 coalesce(sum(movement) filter(where account='cost_of_goods_services'),0) cost,
 coalesce(sum(movement) filter(where account in ('expense_unclassified','stock_adjustment_expense','rent_expense','payroll_expense','utilities_expense','other_operating_expense')),0) expenses,
 coalesce(sum(movement) filter(where account='income_tax_expense'),0) income_tax
 from accounts group by currency),
 vals as (select c.currency,coalesce(t.cash,0) cash,coalesce(t.employee_advances,0) employee_advances,coalesce(t.bank,0) bank,coalesce(t.inventory,0) inventory,coalesce(t.receivable,0) receivable,coalesce(t.payable,0) payable,coalesce(t.capital,0) capital,coalesce(t.loan_payable,0) loan_payable,coalesce(t.payroll_payable,0) payroll_payable,coalesce(t.tax_payable,0) tax_payable,coalesce(t.income_tax,0) income_tax,coalesce(t.cumulative_result,0) cumulative_result,coalesce(t.unresolved_balance,0) unresolved_balance,coalesce(t.revenue,0) revenue,coalesce(t.cost,0) cost,coalesce(t.expenses,0) expenses from tenant_private.sale_currencies c left join totals t on t.currency=c.currency where c.store_id=p_store)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'cash',cash::text,'employee_advances',employee_advances::text,'bank',bank::text,'inventory',inventory::text,'receivable',receivable::text,'assets',(cash+bank+inventory+receivable+employee_advances)::text,'payable',payable::text,'capital',capital::text,'loan_payable',loan_payable::text,'payroll_payable',payroll_payable::text,'tax_payable',tax_payable::text,'income_tax',income_tax::text,'result_after_recorded_tax',(revenue-cost-expenses-income_tax)::text,'cumulative_result',cumulative_result::text,'unresolved_balance',unresolved_balance::text,'revenue',revenue::text,'cost',cost::text,'expenses',expenses::text,'result_before_tax',(revenue-cost-expenses)::text) order by currency),'[]'::jsonb) into rows from vals;
 with used as (select x->>'currency' currency from jsonb_array_elements(rows) x where exists(select 1 from jsonb_each_text(x) y where y.key<>'currency' and y.value<>'0')),
 quotes as (select u.currency,q.id,q.created_at,case when u.currency=p_currency then 1 else q.numerator end numerator,case when u.currency=p_currency then 1 else q.denominator end denominator
 from used u left join lateral(select r.id,r.created_at,r.numerator,r.denominator from public.mt_fx_rates r where r.store_id=p_store and r.from_currency=u.currency and r.to_currency=p_currency and r.created_at<=cutoff and r.created_at>=cutoff-interval '24 hours' order by r.created_at desc,r.id desc limit 1) q on u.currency<>p_currency)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'rate_id',id,'quoted_at',created_at,'numerator',numerator,'denominator',denominator) order by currency),'[]'::jsonb),count(*) filter(where numerator is null) into rates,missing from quotes;
 if missing=0 and (tb->>'unknown_cost_events')::bigint=0 then
  with entries as (select y.key,sum(y.value::numeric*(r->>'numerator')::numeric/(r->>'denominator')::numeric) total from jsonb_array_elements(rows) x join lateral (select value r from jsonb_array_elements(rates) where value->>'currency'=x->>'currency') rr on true cross join lateral jsonb_each_text(x) y where y.key<>'currency' group by y.key)
  select jsonb_object_agg(k,coalesce(round(e.total),0)::text) into translated from unnest(array['cash','employee_advances','bank','inventory','receivable','assets','payable','capital','loan_payable','payroll_payable','tax_payable','income_tax','result_after_recorded_tax','cumulative_result','unresolved_balance','revenue','cost','expenses','result_before_tax']) k left join entries e on e.key=k;
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
 union all select currency,'payroll_payable',-tenant_private.payroll_due(store_id,id)::numeric from tenant_private.staff_payroll where store_id=p_store and paid_at is null
 union all select currency,'employee_advances',tenant_private.advance_remaining(store_id,id)::numeric from tenant_private.staff_advances where store_id=p_store
 union all select currency,'inventory',remaining_units::numeric*unit_cost_minor from tenant_private.stock_layers where store_id=p_store
 union all select currency,'accounts_receivable',remaining_minor::numeric from public.mt_debts where store_id=p_store
 union all select currency,'accounts_payable',-(total_minor::numeric-returned_units::numeric*unit_cost_minor-paid_minor+refunded_minor) from public.mt_purchases where store_id=p_store
 union all select currency,'income_tax_payable',case when kind='income_tax_accrual' then -amount_minor::numeric else amount_minor::numeric end from public.mt_accounting_adjustments where store_id=p_store and kind in ('income_tax_accrual','income_tax_reverse','expense_tax_payment')
 union all select currency,'indirect_tax_payable',case when kind in ('sale','repair') then -tax_minor::numeric else tax_minor::numeric end from public.mt_indirect_tax_entries where store_id=p_store
 union all select currency,'indirect_tax_payable',amount_minor::numeric from public.mt_accounting_adjustments where store_id=p_store and kind='expense_indirect_tax_payment'
 ), s as (select currency,account,sum(amount) balance from source group by currency,account),
 vals as (select c.currency,a.account,coalesce(j.balance,0) journal,coalesce(s.balance,0) recorded from tenant_private.sale_currencies c cross join unnest(array['cash','employee_advances','bank','inventory','accounts_receivable','accounts_payable','payroll_payable','income_tax_payable','indirect_tax_payable']) a(account) left join j on j.currency=c.currency and j.account=a.account left join s on s.currency=c.currency and s.account=a.account where c.store_id=p_store)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'account',account,'journal',journal::text,'recorded',recorded::text,'difference',(recorded-journal)::text,'balanced',recorded=journal) order by currency,account),'[]'::jsonb) into rows from vals;
 select count(*) into stock_mismatches from public.mt_products p where p.store_id=p_store and p.quantity<>(select coalesce(sum(l.remaining_units),0) from tenant_private.stock_layers l where l.store_id=p.store_id and l.product_id=p.id);
 return jsonb_build_object('mode','current_subledger_reconciliation','rows',rows,'stock_quantity_mismatches',stock_mismatches,'balanced',stock_mismatches=0 and not exists(select 1 from jsonb_array_elements(rows) x where x->>'balanced'='false'));
end; $$;
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
 union all select v.branch_id,m.currency,0,0,m.amount_minor,0 from tenant_private.branch_vouchers v join public.mt_cash_movements m on m.store_id=v.store_id and m.id=v.cash_id where v.store_id=p_store and v.branch_id is not null and v.kind<>'receipt' and not exists(select 1 from tenant_private.staff_advances a where a.store_id=v.store_id and a.id=v.request_id) and not exists(select 1 from tenant_private.staff_payroll p where p.store_id=v.store_id and p.payment_request=v.request_id) and m.created_at>=lo and m.created_at<hi
 union all select branch_id,currency,0,0,total_minor,0 from tenant_private.staff_payroll where store_id=p_store and branch_id is not null and created_at>=lo and created_at<hi
 union all select p.branch_id,p.currency,0,0,case when a.kind='bonus' then a.amount_minor else -a.amount_minor end,0 from tenant_private.staff_payroll_adjustments a join tenant_private.staff_payroll p on p.store_id=a.store_id and p.id=a.payroll_id where a.store_id=p_store and p.branch_id is not null and a.created_at>=lo and a.created_at<hi
 ), grouped as (select branch_id,currency,sum(revenue) as revenue,sum(cost) as cost,sum(expense) as expense,sum(unknown)::bigint as unknown from events group by branch_id,currency)
 select coalesce(jsonb_agg(jsonb_build_object('branch',g.branch_id,'name',b.name,'currency',g.currency,'revenue',trunc(g.revenue)::text,'cost',case when g.unknown=0 then trunc(g.cost)::text end,'expenses',trunc(g.expense)::text,'result',case when g.unknown=0 then trunc(g.revenue-g.cost-g.expense)::text end,'unknown',g.unknown) order by b.name,g.currency),'[]') into r from grouped g join tenant_private.branches b on b.store_id=p_store and b.id=g.branch_id;
 return r;
end $$;
create function public.mt_payroll_adjust(p_store uuid,p_id uuid,p_payroll uuid,p_kind text,p_amount bigint,p_reason text) returns uuid language sql security invoker set search_path='' as $$select tenant_private.payroll_adjust(p_store,p_id,p_payroll,p_kind,p_amount,p_reason)$$;
create function public.mt_payroll_advance(p_store uuid,p_id uuid,p_user uuid,p_branch uuid,p_currency text,p_amount bigint,p_reference text,p_confirm boolean) returns uuid language sql security invoker set search_path='' as $$select tenant_private.payroll_advance(p_store,p_id,p_user,p_branch,p_currency,p_amount,p_reference,p_confirm)$$;
create function public.mt_payroll_offset(p_store uuid,p_id uuid,p_payroll uuid,p_advance uuid,p_amount bigint) returns uuid language sql security invoker set search_path='' as $$select tenant_private.payroll_offset(p_store,p_id,p_payroll,p_advance,p_amount)$$;
create function public.mt_payroll_details(p_store uuid,p_user uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.payroll_details(p_store,p_user)$$;
revoke all on function tenant_private.payroll_due(uuid,uuid),tenant_private.advance_remaining(uuid,uuid),tenant_private.payroll_adjust(uuid,uuid,uuid,text,bigint,text),tenant_private.payroll_advance(uuid,uuid,uuid,uuid,text,bigint,text,boolean),tenant_private.payroll_offset(uuid,uuid,uuid,uuid,bigint),tenant_private.payroll_details(uuid,uuid),public.mt_payroll_adjust(uuid,uuid,uuid,text,bigint,text),public.mt_payroll_advance(uuid,uuid,uuid,uuid,text,bigint,text,boolean),public.mt_payroll_offset(uuid,uuid,uuid,uuid,bigint),public.mt_payroll_details(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.payroll_adjust(uuid,uuid,uuid,text,bigint,text),tenant_private.payroll_advance(uuid,uuid,uuid,uuid,text,bigint,text,boolean),tenant_private.payroll_offset(uuid,uuid,uuid,uuid,bigint),tenant_private.payroll_details(uuid,uuid),public.mt_payroll_adjust(uuid,uuid,uuid,text,bigint,text),public.mt_payroll_advance(uuid,uuid,uuid,uuid,text,bigint,text,boolean),public.mt_payroll_offset(uuid,uuid,uuid,uuid,bigint),public.mt_payroll_details(uuid,uuid) to authenticated;
commit;
