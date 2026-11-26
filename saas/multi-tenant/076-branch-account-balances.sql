-- Attribute outstanding receivables, payables and payroll to the document location.
-- Stock units are exact, but global FIFO layers cannot yet establish a branch's acquisition cost.
begin;
create function tenant_private.branch_account_balances(p_store uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 return (with locations as (
 select null::uuid branch_id,'المستودع الرئيسي'::text name union all select id,name from tenant_private.branches where store_id=p_store
 ), entries as (
 select b.branch_id,d.currency,'receivable'::text account,d.remaining_minor::numeric amount from public.mt_debts d left join tenant_private.branch_sales b on b.store_id=d.store_id and b.sale_id=d.sale_id where d.store_id=p_store
 union all select b.branch_id,p.currency,'payable',p.total_minor::numeric-p.returned_units::numeric*p.unit_cost_minor-p.paid_minor+p.refunded_minor from public.mt_purchases p left join tenant_private.branch_purchases b on b.store_id=p.store_id and b.purchase_id=p.id where p.store_id=p_store
 union all select branch_id,currency,'payroll',tenant_private.payroll_due(store_id,id)::numeric from tenant_private.staff_payroll where store_id=p_store and paid_at is null
 union all select branch_id,currency,'advance',tenant_private.advance_remaining(store_id,id)::numeric from tenant_private.staff_advances where store_id=p_store
 ), totals as (select branch_id,currency,sum(amount) filter(where account='receivable') receivable,sum(amount) filter(where account='payable') payable,sum(amount) filter(where account='payroll') payroll,sum(amount) filter(where account='advance') advances from entries group by branch_id,currency),
 units as (select branch_id,sum(units)::numeric units from tenant_private.branch_stock where store_id=p_store group by branch_id union all select null::uuid,coalesce(sum(p.quantity-tenant_private.branch_allocated(p.store_id,p.id)),0)::numeric from public.mt_products p where store_id=p_store),
 rows as (select l.branch_id,l.name,c.currency,case when exists(select 1 from tenant_private.branch_treasury_enabled where store_id=p_store) then coalesce(a.balance_minor,0)::text else null end cash,coalesce(t.receivable,0)::text receivable,coalesce(t.payable,0)::text payable,coalesce(t.payroll,0)::text payroll,coalesce(t.advances,0)::text advances,coalesce(u.units,0)::text stock_units from locations l cross join tenant_private.sale_currencies c left join totals t on t.branch_id is not distinct from l.branch_id and t.currency=c.currency left join tenant_private.branch_cash_accounts a on a.store_id=p_store and a.branch_id is not distinct from l.branch_id and a.currency=c.currency left join units u on u.branch_id is not distinct from l.branch_id where c.store_id=p_store)
 select jsonb_build_object('mode','attributed_subledgers','stock_valuation_available',false,'rows',coalesce(jsonb_agg(to_jsonb(r) order by r.name,r.currency),'[]'::jsonb)) from rows r);
end $$;
create function public.mt_branch_account_balances(p_store uuid) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.branch_account_balances(p_store)$$;
revoke all on function tenant_private.branch_account_balances(uuid),public.mt_branch_account_balances(uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.branch_account_balances(uuid),public.mt_branch_account_balances(uuid) to authenticated;
commit;
