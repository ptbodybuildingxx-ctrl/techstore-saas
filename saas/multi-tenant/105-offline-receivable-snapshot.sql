-- Consistent, permission-scoped, bounded offline customer ledger. No mutation or new service.
create function tenant_private.offline_receivable_snapshot(p_store uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare role_now text:=tenant_private.member_role(p_store);u uuid:=auth.uid();scope uuid;grants jsonb;result jsonb;
begin
 if u is null or not tenant_private.receivable_allowed(p_store,'read') then raise exception 'Receivable read denied' using errcode='42501';end if;
 scope:=tenant_private.current_branch_scope(p_store);
 grants:=tenant_private.receivable_grant_read(p_store,null);
 with customers as materialized (
  select c.id,c.name,c.phone from public.mt_customers c where c.store_id=p_store order by c.id limit 2001
 ), branches as materialized (
  select b.id,b.name from tenant_private.branches b where b.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,b.id) order by b.id limit 201
 ), invoice_debts as materialized (
  select 'invoice'::text kind,d.id,d.customer_id,c.name party,c.phone,bs.branch_id,coalesce(b.name,'') branch_name,'receivable'::text direction,d.currency,d.principal_minor,d.deposit_minor,d.remaining_minor,d.installment_count,d.first_due,d.created_at,s.number::text invoice_number,''::text notes
  from public.mt_debts d join public.mt_customers c on c.store_id=d.store_id and c.id=d.customer_id
  join public.mt_sales s on s.store_id=d.store_id and s.id=d.sale_id
  left join tenant_private.branch_sales bs on bs.store_id=d.store_id and bs.sale_id=d.sale_id
  left join tenant_private.branches b on b.store_id=bs.store_id and b.id=bs.branch_id
  where d.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,bs.branch_id) order by d.id limit 2001
 ), standalone as materialized (
  select 'standalone'::text kind,d.id,d.customer_id,d.party,d.phone,d.branch_id,coalesce(b.name,'') branch_name,d.direction,d.currency,d.principal_minor,0::bigint deposit_minor,d.remaining_minor,d.installment_count,d.first_due,d.created_at,null::text invoice_number,d.notes
  from tenant_private.standalone_debts d left join tenant_private.branches b on b.store_id=d.store_id and b.id=d.branch_id
  where d.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,d.branch_id) and (d.direction='receivable' or tenant_private.receivable_allowed(p_store,'payable_manage'))
  order by d.id limit 2001
 ), debts as materialized (
  select * from invoice_debts union all select * from standalone
 ), schedule as materialized (
  select * from (
   select d.kind,i.debt_id,i.number,i.due_date,i.amount_minor,i.paid_minor,i.waived_minor from invoice_debts d join public.mt_installments i on i.store_id=p_store and i.debt_id=d.id
   union all
   select d.kind,i.debt_id,i.number,i.due_date,i.amount_minor,i.paid_minor,0::bigint waived_minor from standalone d join tenant_private.standalone_installments i on i.store_id=p_store and i.debt_id=d.id
  ) t order by kind,debt_id,number limit 12001
 ), payments as materialized (
  select * from (
   select d.kind,p.debt_id,p.id,p.amount_minor,p.created_at,p.settlement_method method,p.is_deposit,''::text memo from invoice_debts d join public.mt_debt_payments p on p.store_id=p_store and p.debt_id=d.id
   union all
   select d.kind,p.debt_id,p.id,p.amount_minor,p.created_at,'cash'::text method,false is_deposit,p.memo from standalone d join tenant_private.standalone_debt_payments p on p.store_id=p_store and p.debt_id=d.id
  ) t order by created_at desc,kind,id limit 6001
 )
 select case when (select count(*) from customers)>2000 or (select count(*) from branches)>200 or (select count(*) from debts)>2000 or (select count(*) from schedule)>12000 or (select count(*) from payments)>6000 then null else jsonb_build_object(
 'version',1,'store',p_store,'actor',u,'role',role_now,'branch',scope,'capturedAt',now(),'actions',grants->'effective',
 'customers',coalesce((select jsonb_agg(to_jsonb(c) order by c.id) from customers c),'[]'::jsonb),
 'branches',coalesce((select jsonb_agg(to_jsonb(b) order by b.id) from branches b),'[]'::jsonb),
 'debts',coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at desc,d.kind,d.id) from debts d),'[]'::jsonb),
 'schedule',coalesce((select jsonb_agg(to_jsonb(i) order by i.kind,i.debt_id,i.number) from schedule i),'[]'::jsonb),
 'payments',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc,p.kind,p.id) from payments p),'[]'::jsonb)
 ) end into result;
 if result is null or octet_length(result::text)>1400000 then raise exception 'Offline ledger capacity exceeded; no partial snapshot' using errcode='22023';end if;
 return result;
end $$;
create function public.mt_offline_receivable_snapshot(p_store uuid) returns jsonb language sql stable set search_path='' as $$select tenant_private.offline_receivable_snapshot(p_store)$$;
revoke all on function tenant_private.offline_receivable_snapshot(uuid),public.mt_offline_receivable_snapshot(uuid) from public,anon,authenticated,service_role;
grant execute on function tenant_private.offline_receivable_snapshot(uuid),public.mt_offline_receivable_snapshot(uuid) to authenticated;
