begin;
-- Reconcile recorded balances to the complete immutable movement history. Not a statutory general ledger.
create function tenant_private.cash_reconciliation(p_store uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 with flows as (
 select currency,case when kind in ('sale','funding','debt_payment','repair_receipt','mixed_receipt') then amount_minor::numeric else -amount_minor::numeric end amount from public.mt_cash_movements where store_id=p_store
 union all select target_currency,target_amount_minor::numeric from public.mt_cash_movements where store_id=p_store and kind='exchange'
 ), sums as (select currency,sum(amount) as computed from flows group by currency),
 vals as (select c.currency,coalesce(b.balance_minor,0)::numeric recorded,coalesce(s.computed,0) computed from tenant_private.sale_currencies c left join tenant_private.cash_balances b on b.store_id=c.store_id and b.currency=c.currency left join sums s on s.currency=c.currency where c.store_id=p_store)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'recorded',recorded::text,'computed',computed::text,'difference',(recorded-computed)::text,'balanced',recorded=computed) order by currency),'[]'::jsonb) into r from vals;
 return r;
end $$;
create function public.mt_cash_reconciliation(p_store uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.cash_reconciliation(p_store)$$;
revoke all on function tenant_private.cash_reconciliation(uuid),public.mt_cash_reconciliation(uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.cash_reconciliation(uuid),public.mt_cash_reconciliation(uuid) to authenticated;
commit;