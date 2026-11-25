begin;
-- Bounded cash-flow report, not an accrual profit statement. Sum NUMERIC and return decimal strings to avoid JS precision loss.
create function tenant_private.cash_report(p_store uuid,p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 then raise exception 'Invalid date range' using errcode='22023';end if;
 with movements as (select * from public.mt_cash_movements where store_id=p_store and created_at>=p_from::timestamp at time zone 'UTC' and created_at<(p_to+1)::timestamp at time zone 'UTC'),
 flows as (select currency,kind,case when kind in ('sale','funding','debt_payment') then amount_minor else -amount_minor end as value from movements union all select target_currency,'exchange_in',target_amount_minor from movements where kind='exchange'),
 totals as (select currency,sum(value) filter(where value>0) as incoming,sum(-value) filter(where value<0) as outgoing,sum(value) as net,sum(value) filter(where kind in ('sale','debt_payment')) as collections,sum(-value) filter(where kind='return_refund') as refunds,sum(-value) filter(where kind='supplier_payment') as supplier_payments,sum(-value) filter(where kind='expense') as expenses from flows group by currency)
 select coalesce(jsonb_agg(jsonb_build_object('currency',c.currency,'incoming',coalesce(t.incoming,0)::text,'outgoing',coalesce(t.outgoing,0)::text,'net',coalesce(t.net,0)::text,'collections',coalesce(t.collections,0)::text,'refunds',coalesce(t.refunds,0)::text,'supplier_payments',coalesce(t.supplier_payments,0)::text,'expenses',coalesce(t.expenses,0)::text) order by c.currency),'[]'::jsonb) into r
 from tenant_private.sale_currencies c left join totals t on t.currency=c.currency where c.store_id=p_store;
 return r;
end $$;
create function public.mt_cash_report(p_store uuid,p_from date,p_to date) returns jsonb
language sql stable security invoker set search_path='' as $$select tenant_private.cash_report(p_store,p_from,p_to)$$;
revoke all on function tenant_private.cash_report(uuid,date,date),public.mt_cash_report(uuid,date,date) from public,anon,authenticated,service_role;
grant execute on function tenant_private.cash_report(uuid,date,date),public.mt_cash_report(uuid,date,date) to authenticated;
commit;