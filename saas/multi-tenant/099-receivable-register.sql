begin;
-- Read-only owner register, preserving existing RLS and financial posting.
create function public.mt_receivable_register(p_store uuid,p_mode text,p_query text,p_customer uuid,p_currency text,p_status text,p_offset integer)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare rows jsonb; totals jsonb; today date:=(now() at time zone 'Asia/Damascus')::date;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_mode is null or p_mode not in ('debts','schedule','payments') or p_query is null or length(p_query)>160 or p_status is null or p_status not in ('all','open','overdue','settled') or p_offset is null or p_offset not between 0 and 100000 or (p_currency is not null and p_currency not in ('SYP','USD','EUR')) then raise exception 'Invalid filters' using errcode='22023';end if;
 with base as (
 select d.*,c.name,c.phone,s.number invoice_number from public.mt_debts d join public.mt_customers c on (c.store_id,c.id)=(d.store_id,d.customer_id) join public.mt_sales s on (s.store_id,s.id)=(d.store_id,d.sale_id)
 where d.store_id=p_store and (p_customer is null or c.id=p_customer) and (p_currency is null or d.currency=p_currency)
 and (p_query='' or strpos(lower(c.name),lower(p_query))>0 or strpos(c.phone,p_query)>0 or strpos(s.number::text,p_query)>0)
 ), balances as (
 select currency,sum(principal_minor)::text principal,sum(deposit_minor)::text deposit,sum(remaining_minor)::text remaining from base group by currency
 ), items as (
 select b.id debt_id,b.customer_id,b.name,b.phone,b.currency,b.invoice_number,b.id item_id,0 installment_number,b.created_at::text recorded_at,b.first_due due_date,b.principal_minor amount_minor,b.deposit_minor paid_minor,0::bigint waived_minor,b.remaining_minor,
 case when b.remaining_minor=0 then 'settled' when exists(select 1 from public.mt_installments i where i.store_id=p_store and i.debt_id=b.id and i.due_date<today and i.paid_minor+i.waived_minor<i.amount_minor) then 'overdue' else 'open' end status,null::text method,false is_deposit from base b where p_mode='debts'
 union all
 select b.id,b.customer_id,b.name,b.phone,b.currency,b.invoice_number,b.id,i.number,null,i.due_date,i.amount_minor,i.paid_minor,i.waived_minor,i.amount_minor-i.paid_minor-i.waived_minor,case when i.paid_minor+i.waived_minor=i.amount_minor then 'settled' when i.due_date<today then 'overdue' else 'open' end,null,false from base b join public.mt_installments i on (i.store_id,i.debt_id)=(b.store_id,b.id) where p_mode='schedule'
 union all
 select b.id,b.customer_id,b.name,b.phone,b.currency,b.invoice_number,p.id,0,p.created_at::text,null,p.amount_minor,0::bigint,0::bigint,0::bigint,'recorded',p.settlement_method,p.is_deposit from base b join public.mt_debt_payments p on (p.store_id,p.debt_id)=(b.store_id,b.id) where p_mode='payments'
 ), page as (
 select * from items where p_mode='payments' or p_status='all' or status=p_status or (p_status='open' and status='overdue')
 order by due_date asc nulls last,recorded_at desc nulls last,debt_id,installment_number,item_id offset p_offset limit 51
 )
 select (select coalesce(jsonb_agg(to_jsonb(b) order by b.currency),'[]'::jsonb) from balances b),
 (select coalesce(jsonb_agg(to_jsonb(x) order by x.due_date asc nulls last,x.recorded_at desc nulls last,x.debt_id,x.installment_number,x.item_id),'[]'::jsonb) from page x) into totals,rows;
 return jsonb_build_object('store_id',p_store,'mode',p_mode,'today',today,'totals',totals,'rows',rows);
end $$;
revoke all on function public.mt_receivable_register(uuid,text,text,uuid,text,text,integer) from public,anon,authenticated,service_role;
grant execute on function public.mt_receivable_register(uuid,text,text,uuid,text,text,integer) to authenticated;
commit;
