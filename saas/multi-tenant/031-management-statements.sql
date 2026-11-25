begin;
-- Management statements: fixed closing-rate translation, not statutory accounts.
create function tenant_private.management_statements(p_store uuid,p_from date,p_to date,p_currency text) returns jsonb
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
 -coalesce(sum(closing) filter(where account in ('sales_revenue','repair_revenue','sales_returns','cost_of_goods_services','expense_unclassified','stock_adjustment_expense')),0) cumulative_result,
 -coalesce(sum(closing) filter(where account in ('funding_unclassified','stock_intake_unclassified','fx_clearing')),0) unresolved_balance,
 -coalesce(sum(movement) filter(where account in ('sales_revenue','repair_revenue','sales_returns')),0) revenue,
 coalesce(sum(movement) filter(where account='cost_of_goods_services'),0) cost,
 coalesce(sum(movement) filter(where account in ('expense_unclassified','stock_adjustment_expense')),0) expenses
 from accounts group by currency),
 vals as (select c.currency,coalesce(t.cash,0) cash,coalesce(t.inventory,0) inventory,coalesce(t.receivable,0) receivable,coalesce(t.payable,0) payable,coalesce(t.cumulative_result,0) cumulative_result,coalesce(t.unresolved_balance,0) unresolved_balance,coalesce(t.revenue,0) revenue,coalesce(t.cost,0) cost,coalesce(t.expenses,0) expenses from tenant_private.sale_currencies c left join totals t on t.currency=c.currency where c.store_id=p_store)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'cash',cash::text,'inventory',inventory::text,'receivable',receivable::text,'assets',(cash+inventory+receivable)::text,'payable',payable::text,'cumulative_result',cumulative_result::text,'unresolved_balance',unresolved_balance::text,'revenue',revenue::text,'cost',cost::text,'expenses',expenses::text,'result_before_tax',(revenue-cost-expenses)::text) order by currency),'[]'::jsonb) into rows from vals;
 with used as (select x->>'currency' currency from jsonb_array_elements(rows) x where exists(select 1 from jsonb_each_text(x) y where y.key<>'currency' and y.value<>'0')),
 quotes as (select u.currency,q.id,q.created_at,case when u.currency=p_currency then 1 else q.numerator end numerator,case when u.currency=p_currency then 1 else q.denominator end denominator
 from used u left join lateral(select r.id,r.created_at,r.numerator,r.denominator from public.mt_fx_rates r where r.store_id=p_store and r.from_currency=u.currency and r.to_currency=p_currency and r.created_at<=cutoff and r.created_at>=cutoff-interval '24 hours' order by r.created_at desc,r.id desc limit 1) q on u.currency<>p_currency)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'rate_id',id,'quoted_at',created_at,'numerator',numerator,'denominator',denominator) order by currency),'[]'::jsonb),count(*) filter(where numerator is null) into rates,missing from quotes;
 if missing=0 and (tb->>'unknown_cost_events')::bigint=0 then
  with entries as (select y.key,sum(y.value::numeric*(r->>'numerator')::numeric/(r->>'denominator')::numeric) total from jsonb_array_elements(rows) x join lateral (select value r from jsonb_array_elements(rates) where value->>'currency'=x->>'currency') rr on true cross join lateral jsonb_each_text(x) y where y.key<>'currency' group by y.key)
  select jsonb_object_agg(k,coalesce(round(e.total),0)::text) into translated from unnest(array['cash','inventory','receivable','assets','payable','cumulative_result','unresolved_balance','revenue','cost','expenses','result_before_tax']) k left join entries e on e.key=k;
 end if;
 return jsonb_build_object('mode','management_closing_rate','currency',p_currency,'rows',rows,'rates',rates,'missing_rates',missing,'unknown_cost_events',tb->'unknown_cost_events','translated',translated,'tax_status','not_calculated','final_profit',null);
end $$;
create function public.mt_management_statements(p_store uuid,p_from date,p_to date,p_currency text) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.management_statements(p_store,p_from,p_to,p_currency)$$;
revoke all on function tenant_private.management_statements(uuid,date,date,text),public.mt_management_statements(uuid,date,date,text) from public,anon,authenticated,service_role;
grant execute on function tenant_private.management_statements(uuid,date,date,text),public.mt_management_statements(uuid,date,date,text) to authenticated;
commit;