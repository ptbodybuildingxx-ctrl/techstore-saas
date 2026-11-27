-- 146: page-based offline receivables and local pricing, preserving live permissions.
-- Existing aggregate RPCs remain intact for older clients. No records are altered.
begin;
create function tenant_private.offline_receivable_page(p_store uuid,d uuid,secret uuid,section_name text,after_key jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare role_now text;u uuid:=auth.uid();scope uuid;grants jsonb;result jsonb;
begin
 perform tenant_private.offline_device_require(p_store,d,secret);
 role_now:=tenant_private.member_role(p_store);
 if u is null or role_now not in ('owner','cashier') or role_now is null
 or not coalesce(tenant_private.receivable_allowed(p_store,'read'),false)
 or not coalesce(tenant_private.staff_action_allowed(p_store,'customer_read'),false)
 or not coalesce(tenant_private.staff_action_allowed(p_store,'debt_read'),false)
 or not coalesce(tenant_private.staff_action_allowed(p_store,'installment_read'),false)
 or not coalesce(tenant_private.central_read_permitted(p_store,'all_customer_read'),false)
 or not coalesce(tenant_private.central_read_permitted(p_store,'all_debt_read'),false)
 then raise exception 'Receivable read denied' using errcode='42501';end if;
 if section_name is null or section_name not in ('customers','branches','debts','schedule','payments') or after_key is not null and (jsonb_typeof(after_key) is distinct from 'array' or octet_length(after_key::text)>1000) then raise exception 'Invalid ledger cursor' using errcode='22023';end if;
 scope:=tenant_private.current_branch_scope(p_store);grants:=tenant_private.receivable_grant_read(p_store,null);
 with customers as (
  select c.id,c.name,c.phone from public.mt_customers c where c.store_id=p_store order by c.id
 ), branches as (
  select b.id,b.name from tenant_private.branches b where b.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,b.id) order by b.id
 ), invoice_debts as (
  select 'invoice'::text kind,d.id,d.customer_id,c.name party,c.phone,bs.branch_id,coalesce(b.name,'') branch_name,'receivable'::text direction,d.currency,d.principal_minor,d.deposit_minor,d.remaining_minor,d.installment_count,d.first_due,d.created_at,s.number::text invoice_number,''::text notes
  from public.mt_debts d join public.mt_customers c on c.store_id=d.store_id and c.id=d.customer_id
  join public.mt_sales s on s.store_id=d.store_id and s.id=d.sale_id
  left join tenant_private.branch_sales bs on bs.store_id=d.store_id and bs.sale_id=d.sale_id
  left join tenant_private.branches b on b.store_id=bs.store_id and b.id=bs.branch_id
  where d.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,bs.branch_id) order by d.id
 ), standalone as (
  select 'standalone'::text kind,d.id,d.customer_id,d.party,d.phone,d.branch_id,coalesce(b.name,'') branch_name,d.direction,d.currency,d.principal_minor,0::bigint deposit_minor,d.remaining_minor,d.installment_count,d.first_due,d.created_at,null::text invoice_number,d.notes
  from tenant_private.standalone_debts d left join tenant_private.branches b on b.store_id=d.store_id and b.id=d.branch_id
  where d.store_id=p_store and tenant_private.receivable_branch_allowed(p_store,d.branch_id) and (d.direction='receivable' or tenant_private.receivable_allowed(p_store,'payable_manage'))
  order by d.id
 ), debts as (
  select * from invoice_debts union all select * from standalone
 ), schedule as (
  select * from (
   select d.kind,i.debt_id,i.number,i.due_date,i.amount_minor,i.paid_minor,i.waived_minor from invoice_debts d join public.mt_installments i on i.store_id=p_store and i.debt_id=d.id
   union all
   select d.kind,i.debt_id,i.number,i.due_date,i.amount_minor,i.paid_minor,0::bigint waived_minor from standalone d join tenant_private.standalone_installments i on i.store_id=p_store and i.debt_id=d.id
  ) t order by kind,debt_id,number
 ), payments as (
  select * from (
   select d.kind,p.debt_id,p.id,p.amount_minor,p.created_at,p.settlement_method method,p.is_deposit,''::text memo from invoice_debts d join public.mt_debt_payments p on p.store_id=p_store and p.debt_id=d.id
   union all
   select d.kind,p.debt_id,p.id,p.amount_minor,p.created_at,'cash'::text method,false is_deposit,p.memo from standalone d join tenant_private.standalone_debt_payments p on p.store_id=p_store and p.debt_id=d.id
  ) t order by created_at desc,kind,id
 ), records as (
 select to_jsonb(t) row_data,jsonb_build_array(t.id) row_key from customers t where section_name='customers'
 union all
 select to_jsonb(t) row_data,jsonb_build_array(t.id) row_key from branches t where section_name='branches'
 union all
 select to_jsonb(t) row_data,jsonb_build_array(t.kind,t.id) row_key from debts t where section_name='debts'
 union all
 select to_jsonb(t) row_data,jsonb_build_array(t.kind,t.debt_id,t.number) row_key from schedule t where section_name='schedule'
 union all
 select to_jsonb(t) row_data,jsonb_build_array(t.kind,t.id) row_key from payments t where section_name='payments'
 ), page as (select row_data,row_key from records where after_key is null or row_key>after_key order by row_key limit 100)
 select jsonb_build_object('version',1,'store',p_store,'actor',u,'role',role_now,'branch',scope,'actions',grants->'effective','capturedAt',now(),'section',section_name,'rows',coalesce(jsonb_agg(row_data order by row_key),'[]'::jsonb),'cursor',(select row_key from page order by row_key desc limit 1),'done',count(*)<100) into result from page;
 return result;
end $$;

create function tenant_private.offline_local_price_page(s uuid,d uuid,secret uuid,b uuid,c text,section_name text,after_key jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform tenant_private.offline_device_require(s,d,secret);
 if not coalesce(tenant_private.local_membership_access(s,b),false) or c is null or c not in ('SYP','USD','EUR')
 or not coalesce(tenant_private.central_read_permitted(s,'all_customer_read'),false)
 or not coalesce(tenant_private.central_read_permitted(s,'all_catalog_read'),false)
 then raise exception 'Local pricing denied' using errcode='42501';end if;
 if b is not null then perform tenant_private.require_branch(s,b);end if;
 if section_name is null or section_name not in ('terms','tiers','prices') or after_key is not null and (jsonb_typeof(after_key) is distinct from 'array' or octet_length(after_key::text)>1000) then raise exception 'Invalid price cursor' using errcode='22023';end if;
 with terms as (
 select t.customer_id,t.tier,coalesce(case when t.use_default then r.basis_points else t.basis_points end,0) basis_points,coalesce(case when t.use_default then r.min_units else t.min_units end,1) min_units
 from tenant_private.local_membership_terms t left join tenant_private.membership_rates r on r.store_id=t.store_id and r.tier=t.tier where t.store_id=s and t.enabled order by t.customer_id
 ),tiers as (
 select p.product_id,p.tier,p.price_minor,p.min_units from tenant_private.product_tier_prices p where p.store_id=s and p.currency=c and exists(select 1 from terms t where t.tier=p.tier) order by p.product_id,p.tier
 ),prices as (
 select p.customer_id,p.product_id,p.price_minor,p.min_units from tenant_private.local_customer_prices p join terms t on t.customer_id=p.customer_id where p.store_id=s and p.currency=c order by p.customer_id,p.product_id
 ), records as (
 select to_jsonb(t) row_data,jsonb_build_array(t.customer_id) row_key from terms t where section_name='terms'
 union all
 select to_jsonb(t) row_data,jsonb_build_array(t.product_id,t.tier) row_key from tiers t where section_name='tiers'
 union all
 select to_jsonb(t) row_data,jsonb_build_array(t.customer_id,t.product_id) row_key from prices t where section_name='prices'
 ), page as (select row_data,row_key from records where after_key is null or row_key>after_key order by row_key limit 100)
 select jsonb_build_object('version',1,'store',s,'actor',auth.uid(),'branch',b,'currency',c,'capturedAt',now(),'section',section_name,'rows',coalesce(jsonb_agg(row_data order by row_key),'[]'::jsonb),'cursor',(select row_key from page order by row_key desc limit 1),'done',count(*)<100) into result from page;
 return result;
end $$;
create function public.mt_offline_receivable_page(p_store uuid,d uuid,secret uuid,section_name text,after_key jsonb) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.offline_receivable_page(p_store,d,secret,section_name,after_key)$$;
create function public.mt_offline_local_price_page(s uuid,d uuid,secret uuid,b uuid,c text,section_name text,after_key jsonb) returns jsonb language sql security invoker set search_path='' as $$select tenant_private.offline_local_price_page(s,d,secret,b,c,section_name,after_key)$$;
revoke all on function tenant_private.offline_receivable_page(uuid,uuid,uuid,text,jsonb),tenant_private.offline_local_price_page(uuid,uuid,uuid,uuid,text,text,jsonb),public.mt_offline_receivable_page(uuid,uuid,uuid,text,jsonb),public.mt_offline_local_price_page(uuid,uuid,uuid,uuid,text,text,jsonb) from public,anon,authenticated,service_role;
grant execute on function tenant_private.offline_receivable_page(uuid,uuid,uuid,text,jsonb),tenant_private.offline_local_price_page(uuid,uuid,uuid,uuid,text,text,jsonb),public.mt_offline_receivable_page(uuid,uuid,uuid,text,jsonb),public.mt_offline_local_price_page(uuid,uuid,uuid,uuid,text,text,jsonb) to authenticated;
commit;
