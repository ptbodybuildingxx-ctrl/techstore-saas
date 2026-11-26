begin;
-- Current journal-to-subledger reconciliation; never infer statutory tax from cash.
create function tenant_private.financial_reconciliation(p_store uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
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
 ), s as (select currency,account,sum(amount) balance from source group by currency,account),
 vals as (select c.currency,a.account,coalesce(j.balance,0) journal,coalesce(s.balance,0) recorded from tenant_private.sale_currencies c cross join unnest(array['cash','inventory','accounts_receivable','accounts_payable','income_tax_payable']) a(account) left join j on j.currency=c.currency and j.account=a.account left join s on s.currency=c.currency and s.account=a.account where c.store_id=p_store)
 select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'account',account,'journal',journal::text,'recorded',recorded::text,'difference',(recorded-journal)::text,'balanced',recorded=journal) order by currency,account),'[]'::jsonb) into rows from vals;
 select count(*) into stock_mismatches from public.mt_products p where p.store_id=p_store and p.quantity<>(select coalesce(sum(l.remaining_units),0) from tenant_private.stock_layers l where l.store_id=p.store_id and l.product_id=p.id);
 return jsonb_build_object('mode','current_subledger_reconciliation','rows',rows,'stock_quantity_mismatches',stock_mismatches,'balanced',stock_mismatches=0 and not exists(select 1 from jsonb_array_elements(rows) x where x->>'balanced'='false'));
end; $$;
create function public.mt_financial_reconciliation(p_store uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.financial_reconciliation(p_store)$$;
revoke all on function tenant_private.financial_reconciliation(uuid),public.mt_financial_reconciliation(uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.financial_reconciliation(uuid),public.mt_financial_reconciliation(uuid) to authenticated;
commit;