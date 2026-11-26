-- Owner-only supplier ledger using canonical purchase, payment and return documents.
begin;
create function tenant_private.supplier_statement(p_store uuid,p_supplier uuid,p_currency text,p_all boolean,p_branch uuid,p_from date,p_to date,p_offset integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare lo timestamptz;hi timestamptz;result jsonb; supplier_name text;
begin
 if tenant_private.member_role(p_store) is distinct from 'owner' then raise exception 'Owner required' using errcode='42501';end if;
 if p_supplier is null or p_currency is null or p_currency not in ('SYP','USD','EUR') or p_all is null or (p_all and p_branch is not null) or p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 or p_to>(now() at time zone 'Asia/Damascus')::date or p_offset is null or p_offset not between 0 and 100000 then raise exception 'Invalid statement query' using errcode='22023';end if;
 if p_branch is not null and not exists(select 1 from tenant_private.branches where store_id=p_store and id=p_branch) then raise exception 'Unknown branch' using errcode='22023';end if;
 select name into supplier_name from public.mt_suppliers where store_id=p_store and id=p_supplier;
 if not found then raise exception 'Unknown supplier' using errcode='22023';end if;
 lo:=p_from::timestamp at time zone 'Asia/Damascus';hi:=(p_to+1)::timestamp at time zone 'Asia/Damascus';
 with purchases as (
  select p.*,b.branch_id from public.mt_purchases p left join tenant_private.branch_purchases b on b.store_id=p.store_id and b.purchase_id=p.id
  where p.store_id=p_store and p.supplier_id=p_supplier and p.currency=p_currency and (p_all or b.branch_id is not distinct from p_branch)
 ), movements(at,kind,id,purchase,branch_id,amount,refund,note) as (
  select created_at,'purchase',id,id,branch_id,total_minor::numeric,0::numeric,note from purchases where created_at<hi
  union all select m.created_at,case when m.settlement_method='tradein_offset' then 'offset' else 'payment' end,m.id,p.id,p.branch_id,-m.amount_minor::numeric,0::numeric,'' from public.mt_supplier_payments m join purchases p on p.store_id=m.store_id and p.id=m.purchase_id where m.store_id=p_store and m.created_at<hi
  union all select r.created_at,'return',r.id,p.id,p.branch_id,-r.debt_reduction_minor::numeric,r.refund_minor::numeric,r.reason from public.mt_supplier_returns r join purchases p on p.store_id=r.store_id and p.id=r.purchase_id where r.store_id=p_store and r.created_at<hi
 ), balances as (
  select *,sum(amount) over(order by at,case kind when 'purchase' then 0 when 'return' then 2 else 1 end,id rows unbounded preceding) as balance from movements
 ), totals as (
  select coalesce(sum(amount) filter(where at<lo),0) opening,coalesce(sum(amount),0) closing,coalesce(sum(amount) filter(where at>=lo and kind='purchase'),0) purchases,coalesce(-sum(amount) filter(where at>=lo and kind in ('payment','offset')),0) paid,coalesce(-sum(amount) filter(where at>=lo and kind='return'),0) debt_reduced,coalesce(sum(refund) filter(where at>=lo),0) refunded,count(*) filter(where at>=lo) total_rows from movements
 ), page as (
  select at,kind,id,purchase,branch_id,amount::text,refund::text,note,balance::text from balances where at>=lo order by at,case kind when 'purchase' then 0 when 'return' then 2 else 1 end,id offset p_offset limit 50
 )
 select jsonb_build_object('supplier',p_supplier,'name',supplier_name,'currency',p_currency,'opening',opening::text,'closing',closing::text,'purchases',purchases::text,'paid',paid::text,'debt_reduced',debt_reduced::text,'refunded',refunded::text,'total_rows',total_rows,'rows',coalesce((select jsonb_agg(to_jsonb(page) order by at,case kind when 'purchase' then 0 when 'return' then 2 else 1 end,id) from page),'[]'::jsonb)) into result from totals;
 return result;
end $$;
create function public.mt_supplier_statement(p_store uuid,p_supplier uuid,p_currency text,p_all boolean,p_branch uuid,p_from date,p_to date,p_offset integer default 0) returns jsonb language sql stable security invoker set search_path='' as $$select tenant_private.supplier_statement(p_store,p_supplier,p_currency,p_all,p_branch,p_from,p_to,p_offset)$$;
revoke all on function tenant_private.supplier_statement(uuid,uuid,text,boolean,uuid,date,date,integer),public.mt_supplier_statement(uuid,uuid,text,boolean,uuid,date,date,integer) from public,anon,authenticated,service_role;
grant execute on function tenant_private.supplier_statement(uuid,uuid,text,boolean,uuid,date,date,integer),public.mt_supplier_statement(uuid,uuid,text,boolean,uuid,date,date,integer) to authenticated;
commit;
